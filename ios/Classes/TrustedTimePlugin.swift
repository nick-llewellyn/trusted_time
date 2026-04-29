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
///    Without this entry, `BGTaskScheduler.shared.submit(...)` throws
///    `BGTaskSchedulerErrorCodeNotPermitted` on every scheduling attempt
///    and background syncs will not fire. The plugin logs the thrown
///    error via `NSLog` so the misconfiguration shows up in the device
///    console; a related diagnostic is also logged when
///    `BGTaskScheduler.shared.register(...)` returns `false`, although
///    that return value alone is not treated as fatal because it also
///    occurs benignly when the identifier was already registered by an
///    earlier `TrustedTimePlugin` instance in the same process.
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
    ///
    /// `BGTaskScheduler.register(...)` returns `false` for two distinct
    /// reasons that the API does not let us distinguish:
    ///   (a) the task identifier is missing from the host app's
    ///       `BGTaskSchedulerPermittedIdentifiers` Info.plist entry
    ///       (host-app misconfiguration), or
    ///   (b) the identifier has already been registered earlier in the
    ///       same process by another `TrustedTimePlugin` instance — for
    ///       example in an add-to-app or multi-`FlutterEngine` setup.
    /// We log the condition so case (a) is visible in device logs, and
    /// we always proceed to `scheduleNextBgSync()` regardless. Under
    /// case (b) the `submit(...)` call below succeeds because the
    /// identifier is registered globally for the process. Under case
    /// (a) the `submit(...)` call throws and is logged with the precise
    /// error, which is the signal the host integrator actually needs.
    private func registerBgSync() {
        if !bgRegistered {
            bgRegistered = true
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: bgTaskId,
                using: nil
            ) { [weak self] task in
                guard let self = self else {
                    // Plugin instance was deallocated between registration and
                    // the OS firing this task — no work was performed, so report
                    // failure rather than success. This lets BGTaskScheduler
                    // apply its normal back-off and retry semantics instead of
                    // recording a phantom successful refresh. Rescheduling the
                    // next request is not possible from here (the scheduler
                    // call lives on the instance); the next app launch will
                    // re-register and call `scheduleNextBgSync()` itself.
                    task.setTaskCompleted(success: false)
                    return
                }
                self.performBackgroundSync(task: task)
            }
            if !registered {
                NSLog(
                    "[TrustedTime] BGTaskScheduler.register returned false for "
                    + "identifier '\(bgTaskId)'. This is expected when another "
                    + "plugin instance has already registered the identifier "
                    + "in the same process; scheduleNextBgSync() will still "
                    + "succeed in that case. If background sync never fires, "
                    + "verify the identifier is listed in "
                    + "BGTaskSchedulerPermittedIdentifiers in the host app's "
                    + "Info.plist (the actual error code will be surfaced by "
                    + "BGTaskScheduler.submit below)."
                )
            }
        }
        scheduleNextBgSync()
    }

    private func scheduleNextBgSync() {
        let req = BGAppRefreshTaskRequest(identifier: bgTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: Double(bgIntervalHours) * 3600)
        // Use do/try/catch instead of try? so the precise BGTaskScheduler
        // error code (e.g. .notPermitted for a missing Info.plist entry,
        // .tooManyPendingTaskRequests, .unavailable) shows up in device
        // logs. Silent failure here was the original cause of "background
        // sync never fires and there's nothing in the console" reports.
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            NSLog(
                "[TrustedTime] BGTaskScheduler.submit failed for identifier "
                + "'\(bgTaskId)': \(error.localizedDescription)"
            )
        }
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

        // Without the host-app's pluginRegistrantCallback we cannot wire
        // GeneratedPluginRegistrant onto the headless engine, so plugin
        // calls (notably flutter_secure_storage for anchor persistence,
        // plus this plugin's own monotonic and background channels) would
        // throw MissingPluginException for every fire and exhaust the OS
        // budget on a no-op. Fall back to the connectivity probe so the
        // run still reports a sensible outcome to BGTaskScheduler instead
        // of repeatedly retrying a misconfigured engine.
        guard TrustedTimePlugin.pluginRegistrantCallback != nil else {
            performConnectivityFallback(task: task)
            return
        }

        // FlutterEngine creation, plugin registration, channel-handler
        // setup, and engine.run must all happen on the main thread;
        // BGTaskScheduler dispatches its launch handler on a background
        // queue. The expirationHandler is also installed on main, *after*
        // pendingTask is set, so it cannot fire and finalize the task
        // before main-thread state is established (which would let the
        // block below restart a headless engine after expiration and/or
        // produce a duplicate setTaskCompleted call). If the OS expires
        // the task before this block runs, no handler is installed yet
        // and the OS hard-terminates the task — acceptable because no
        // engine has been created.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.pendingTask = task
            self.pendingTaskCompleted = false

            // BGAppRefreshTask grants ~30s; the expirationHandler ensures
            // a hung Dart callback does not stall the OS scheduler. Hop
            // to main for teardown because FlutterEngine lifecycle is
            // main-thread-only.
            task.expirationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.finishHeadlessSync(success: false, expired: true, task: task)
                }
            }

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
    /// - Parameter task: Optional fallback. The expiration handler is
    ///   installed on main *after* `pendingTask` is assigned, so under
    ///   normal flow `pendingTask` is always non-nil here. The parameter
    ///   is kept as a defensive backstop for any future caller that
    ///   completes a task before main-thread state is established.
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
