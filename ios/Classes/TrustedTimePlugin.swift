import Flutter
import UIKit
import BackgroundTasks

/// Closure that registers the host app's plugins onto a headless
/// [FlutterEngine] so the Dart background callback can use plugins like
/// `flutter_secure_storage` (required for anchor persistence).
public typealias TrustedTimePluginRegistrantCallback = (FlutterEngine) -> Void

/// Entry point and event coordinator for the TrustedTime iOS plugin.
///
/// **Host app requirements** to enable real headless background sync:
/// 1. Add the task identifier to the host app's `Info.plist`:
///    ```xml
///    <key>BGTaskSchedulerPermittedIdentifiers</key>
///    <array>
///      <string>com.trustedtime.backgroundsync</string>
///    </array>
///    ```
///    Without this entry, `BGTaskScheduler.shared.register(...)` will fail
///    silently and background syncs will not fire.
/// 2. Wire `GeneratedPluginRegistrant` into the headless engine path from
///    your `AppDelegate`:
///    ```swift
///    TrustedTimePlugin.setPluginRegistrantCallback { engine in
///      GeneratedPluginRegistrant.register(with: engine)
///    }
///    ```
///    Without this, the headless engine will run but other plugins
///    (notably `flutter_secure_storage`) will be unavailable and the
///    persisted anchor write will fail.
public class TrustedTimePlugin: NSObject, FlutterPlugin {

    private var integrityEventSink: FlutterEventSink?
    private var clockObservers: [NSObjectProtocol] = []
    private let bgTaskId = "com.trustedtime.backgroundsync"
    private var bgRegistered = false
    private var bgIntervalHours = 24
    private var headlessEngine: FlutterEngine?
    private var bgChannel: FlutterMethodChannel?
    private var pendingTask: BGTask?

    fileprivate static let kHandleKey = "com.trustedtime.bgCallbackHandle"
    fileprivate static var pluginRegistrantCallback: TrustedTimePluginRegistrantCallback?

    /// Registers a callback that wires the host app's
    /// `GeneratedPluginRegistrant` onto a headless [FlutterEngine]. Call
    /// this once from your `AppDelegate` before `runApp` (typically in
    /// `application(_:didFinishLaunchingWithOptions:)`).
    public static func setPluginRegistrantCallback(
        _ callback: @escaping TrustedTimePluginRegistrantCallback
    ) {
        pluginRegistrantCallback = callback
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = TrustedTimePlugin()

        FlutterMethodChannel(name: "trusted_time/monotonic", binaryMessenger: registrar.messenger())
            .setMethodCallHandler(instance.handle)

        FlutterMethodChannel(name: "trusted_time/background", binaryMessenger: registrar.messenger())
            .setMethodCallHandler(instance.handle)

        FlutterEventChannel(name: "trusted_time/integrity", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getUptimeMs":
            result(Int64(ProcessInfo.processInfo.systemUptime * 1000))
        case "enableBackgroundSync":
            let hours = (call.arguments as? [String: Any])?["intervalHours"] as? Int ?? 24
            bgIntervalHours = hours
            registerBgSync()
            result(nil)
        case "setBackgroundCallbackHandle":
            guard
                let args = call.arguments as? [String: Any],
                let handle = (args["handle"] as? NSNumber)?.int64Value
            else {
                result(FlutterError(code: "INVALID_ARGS", message: "handle is required", details: nil))
                return
            }
            UserDefaults.standard.set(handle, forKey: TrustedTimePlugin.kHandleKey)
            result(nil)
        case "notifyBackgroundComplete":
            let success = ((call.arguments as? [String: Any])?["success"] as? Bool) ?? false
            finishHeadlessSync(success: success)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Registers the BGAppRefreshTask once, then schedules the next execution.
    /// Subsequent calls reuse the existing registration; the interval is
    /// read from [bgIntervalHours] inside the handler closure.
    private func registerBgSync() {
        if !bgRegistered {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskId, using: nil) { [weak self] task in
                guard let self = self else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.performBackgroundSync(task: task)
            }
            bgRegistered = true
        }
        scheduleNextBgSync()
    }

    private func scheduleNextBgSync() {
        let req = BGAppRefreshTaskRequest(identifier: bgTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: Double(bgIntervalHours) * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Top-level handler for an OS-fired BGAppRefreshTask: spins up a
    /// headless engine and dispatches the registered Dart callback if a
    /// handle is present, falls back to a connectivity-only HTTPS HEAD
    /// probe otherwise.
    private func performBackgroundSync(task: BGTask) {
        let handle = UserDefaults.standard.object(forKey: TrustedTimePlugin.kHandleKey) as? Int64
        guard let handle = handle, handle != 0,
              let callbackInfo = FlutterCallbackCache.lookupCallbackInformation(handle) else {
            performConnectivityFallback(task: task)
            return
        }

        // BGAppRefreshTask grants ~30s; we wire the expirationHandler so a
        // hung Dart callback does not stall the OS scheduler.
        pendingTask = task
        task.expirationHandler = { [weak self] in
            self?.finishHeadlessSync(success: false, expired: true)
        }

        let engine = FlutterEngine(name: "TrustedTimeBackgroundEngine", project: nil, allowHeadlessExecution: true)
        headlessEngine = engine
        engine.run(withEntrypoint: callbackInfo.callbackName, libraryURI: callbackInfo.callbackLibraryPath)
        TrustedTimePlugin.pluginRegistrantCallback?(engine)

        bgChannel = FlutterMethodChannel(
            name: "trusted_time/background",
            binaryMessenger: engine.binaryMessenger
        )
        bgChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    /// Tears down the headless engine and signals OS task completion.
    /// Idempotent: a second call (e.g. from the expiration handler racing
    /// with notifyBackgroundComplete) is a no-op.
    private func finishHeadlessSync(success: Bool, expired: Bool = false) {
        guard let task = pendingTask else { return }
        pendingTask = nil
        bgChannel?.setMethodCallHandler(nil)
        bgChannel = nil
        headlessEngine?.destroyContext()
        headlessEngine = nil
        scheduleNextBgSync()
        task.setTaskCompleted(success: success && !expired)
    }

    /// Pre-2.x behaviour: validates connectivity without refreshing the
    /// anchor. Used when no Dart callback is registered.
    private func performConnectivityFallback(task: BGTask) {
        let url = URL(string: "https://www.google.com")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        let dataTask = URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            self?.scheduleNextBgSync()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            dataTask.cancel()
            self.scheduleNextBgSync()
            task.setTaskCompleted(success: false)
        }

        dataTask.resume()
    }
}

extension TrustedTimePlugin: FlutterStreamHandler {

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        integrityEventSink = events
        let nc = NotificationCenter.default
        
        clockObservers = [
            nc.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.emit(["type": "clockJumped"])
            },
            nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.emit(["type": "timezoneChanged"])
            },
        ]
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        clockObservers.forEach { NotificationCenter.default.removeObserver($0) }
        clockObservers.removeAll()
        integrityEventSink = nil
        return nil
    }

    private func emit(_ data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.integrityEventSink?(data) }
    }
}
