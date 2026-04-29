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
    private var pendingTaskCompleted = false

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
        // UserDefaults stores the int64 handle as an NSNumber; reading it
        // back as `as? Int64` does not bridge through NSNumber and would
        // silently return nil, forcing every fire down the connectivity
        // fallback path even when a callback is registered.
        let raw = UserDefaults.standard.object(forKey: TrustedTimePlugin.kHandleKey) as? NSNumber
        guard let handle = raw?.int64Value, handle != 0,
              let callbackInfo = FlutterCallbackCache.lookupCallbackInformation(handle) else {
            performConnectivityFallback(task: task)
            return
        }

        // BGAppRefreshTask grants ~30s; the expirationHandler ensures a
        // hung Dart callback does not stall the OS scheduler. Hop to main
        // for teardown because FlutterEngine lifecycle is main-thread-only.
        // The task is captured here so finishHeadlessSync can complete it
        // even if expiration fires before the main-thread block below has
        // run `self.pendingTask = task` (otherwise the guard would return
        // early and the OS would never see setTaskCompleted).
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.finishHeadlessSync(success: false, expired: true, task: task)
            }
        }

        // FlutterEngine creation, plugin registration, channel-handler
        // setup, and engine.run must all happen on the main thread;
        // BGTaskScheduler dispatches its launch handler on a background
        // queue.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.pendingTask = task
            self.pendingTaskCompleted = false

            let engine = FlutterEngine(
                name: "TrustedTimeBackgroundEngine",
                project: nil,
                allowHeadlessExecution: true
            )
            self.headlessEngine = engine

            // Plugins (notably flutter_secure_storage, required for anchor
            // persistence) and the background method-channel handler must
            // be wired up BEFORE the Dart entrypoint runs. Otherwise the
            // entrypoint races against MissingPluginException on plugin
            // calls or on notifyBackgroundComplete.
            TrustedTimePlugin.pluginRegistrantCallback?(engine)

            let channel = FlutterMethodChannel(
                name: "trusted_time/background",
                binaryMessenger: engine.binaryMessenger
            )
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handle(call, result: result)
            }
            self.bgChannel = channel

            let started = engine.run(
                withEntrypoint: callbackInfo.callbackName,
                libraryURI: callbackInfo.callbackLibraryPath
            )
            if !started {
                self.finishHeadlessSync(success: false)
            }
        }
    }

    /// Tears down the headless engine and signals OS task completion.
    /// Idempotent: a second call (e.g. from the expiration handler racing
    /// with notifyBackgroundComplete) is a no-op. Always runs on main
    /// because FlutterEngine teardown is main-thread-only.
    ///
    /// - Parameter task: Optional fallback used by the expiration handler
    ///   when expiration fires before `pendingTask` has been assigned on
    ///   the main thread. Without it, an early expiration would return
    ///   from the guard below and never call `setTaskCompleted`, leaving
    ///   the OS scheduler hanging on the task until its hard timeout.
    private func finishHeadlessSync(
        success: Bool,
        expired: Bool = false,
        task: BGTask? = nil
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.finishHeadlessSync(success: success, expired: expired, task: task)
            }
            return
        }
        if pendingTaskCompleted { return }
        guard let resolved = pendingTask ?? task else { return }
        pendingTaskCompleted = true
        pendingTask = nil
        bgChannel?.setMethodCallHandler(nil)
        bgChannel = nil
        headlessEngine?.destroyContext()
        headlessEngine = nil
        scheduleNextBgSync()
        resolved.setTaskCompleted(success: success && !expired)
    }

    /// Pre-2.x behaviour: validates connectivity without refreshing the
    /// anchor. Used when no Dart callback is registered. Reports success
    /// only when the HEAD request returns a 2xx response so iOS can
    /// reschedule with backoff on transient connectivity failures
    /// (parity with the Android worker's `Result.retry()` semantics).
    private func performConnectivityFallback(task: BGTask) {
        let url = URL(string: "https://www.google.com")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        let dataTask = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            self?.scheduleNextBgSync()
            let ok: Bool
            if error != nil {
                ok = false
            } else if let http = response as? HTTPURLResponse {
                ok = (200...299).contains(http.statusCode)
            } else {
                ok = false
            }
            task.setTaskCompleted(success: ok)
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
