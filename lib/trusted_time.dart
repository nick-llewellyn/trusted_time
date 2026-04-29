/// TrustedTime — tamper-proof, offline-safe, multi-source trusted time for
/// Flutter.
///
/// Provides reliable UTC timestamps immune to system clock manipulation by
/// anchoring network-verified time to the device's hardware monotonic clock.
///
/// ## Quick Start
///
/// ```dart
/// // 1. Initialize once at app startup.
/// await TrustedTime.initialize();
///
/// // 2. Get trusted time anywhere (synchronous, <1µs).
/// final now = TrustedTime.now();
///
/// // 3. Check trust state.
/// if (TrustedTime.isTrusted) { /* safe to use */ }
///
/// // 4. Listen for integrity violations.
/// TrustedTime.onIntegrityLost.listen((event) {
///   print('Integrity lost: ${event.reason}');
/// });
/// ```
///
/// See the [README](https://pub.dev/packages/trusted_time) for full
/// documentation and advanced configuration.
library;

import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'src/background_sync.dart';
import 'src/background_sync.dart' as bg show runBackgroundSync;
import 'src/exceptions.dart';
import 'src/integrity_event.dart';
import 'src/models.dart';
import 'src/trusted_time_estimate.dart';
import 'src/trusted_time_impl.dart';
import 'src/trusted_time_mock.dart';

export 'src/background_sync.dart'
    show
        BackgroundSyncFailure,
        BackgroundSyncSuccess,
        TrustedTimeBackgroundResult;
export 'src/exceptions.dart';
export 'src/integrity_event.dart';
export 'src/models.dart'
    show
        LeapIndicator,
        TimeSample,
        TimeSourceKind,
        TimeSourceMetadata,
        TrustAnchor,
        TrustedTimeConfig,
        TrustedTimeSource;
export 'src/trusted_time_estimate.dart';
export 'src/trusted_time_mock.dart';

/// Central entry point for all high-integrity time operations.
///
/// [TrustedTime] is a static-only API — call [initialize] once at app
/// startup, then use [now], [nowUnixMs], or [nowIso] anywhere in your code
/// for synchronous, sub-microsecond trusted time access.
///
/// The engine synchronizes with multiple network time sources (NTP + HTTPS),
/// establishes a quorum-based consensus, and anchors the result to the
/// device's hardware monotonic clock. This ensures timestamps remain correct
/// even if users manipulate their device's system clock.
abstract final class TrustedTime {
  TrustedTime._();

  static bool _timezoneInitialized = false;

  /// Bootstraps the engine, loads persisted anchors, and starts the initial
  /// network sync.
  ///
  /// Must be called once before any other API. Typically placed in `main()`:
  ///
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await TrustedTime.initialize();
  ///   runApp(MyApp());
  /// }
  /// ```
  ///
  /// Pass a [config] to customize NTP servers, refresh intervals, quorum
  /// requirements, and other engine parameters.
  static Future<void> initialize({
    TrustedTimeConfig config = const TrustedTimeConfig(),
  }) async {
    if (!_timezoneInitialized) {
      tz.initializeTimeZones();
      _timezoneInitialized = true;
    }

    // Short-circuit when a test mock is active — avoids network I/O,
    // secure storage access, and platform channel calls during tests.
    // Timezone initialization still runs above so trustedLocalTimeIn works.
    if (_override != null) return;

    await TrustedTimeImpl.init(config);
  }

  /// Returns the current trusted UTC time.
  ///
  /// **Synchronous, <1µs** — no I/O or async operations. Uses the cached
  /// hardware-anchored delta from the last successful sync.
  ///
  /// Throws [TrustedTimeNotReadyException] if [initialize] has not been
  /// called or the initial sync failed.
  static DateTime now() {
    if (_override != null) return _override!.now;
    return TrustedTimeImpl.instance.now();
  }

  /// Returns the current trusted Unix timestamp in milliseconds since epoch.
  ///
  /// Equivalent to `TrustedTime.now().millisecondsSinceEpoch` but avoids
  /// creating an intermediate [DateTime] object.
  static int nowUnixMs() {
    if (_override != null) return _override!.nowUnixMs;
    return TrustedTimeImpl.instance.nowUnixMs();
  }

  /// Returns the current trusted time as an ISO-8601 string.
  ///
  /// Example: `'2024-01-01T12:00:00.000Z'`.
  static String nowIso() {
    if (_override != null) return _override!.nowIso;
    return TrustedTimeImpl.instance.nowIso();
  }

  /// Whether the engine currently holds a valid trust anchor.
  ///
  /// Returns `false` before [initialize] completes, if the initial sync
  /// fails, or after an integrity violation is detected.
  static bool get isTrusted {
    if (_override != null) return _override!.isTrusted;
    return TrustedTimeImpl.instance.isTrusted;
  }

  /// Reactive stream of integrity violation events.
  ///
  /// Emits [IntegrityEvent]s when the engine detects clock jumps, timezone
  /// changes, device reboots, or other temporal tampering.
  ///
  /// ```dart
  /// TrustedTime.onIntegrityLost.listen((event) {
  ///   if (event.reason == TamperReason.systemClockJumped) {
  ///     showWarning('Clock manipulation detected');
  ///   }
  /// });
  /// ```
  static Stream<IntegrityEvent> get onIntegrityLost {
    if (_override != null) return _override!.onIntegrityLost;
    return TrustedTimeImpl.instance.onIntegrityLost;
  }

  /// Best-effort estimated time for offline scenarios.
  ///
  /// Returns a [TrustedTimeEstimate] extrapolated from the last known
  /// anchor using the device's wall clock and estimated oscillator drift.
  ///
  /// **NOT tamper-proof** — check [TrustedTimeEstimate.confidence] to
  /// determine suitability for your use case. Returns `null` if no
  /// anchor data is available.
  static TrustedTimeEstimate? nowEstimated() {
    if (_override != null) return _override!.nowEstimated();
    return TrustedTimeImpl.instance.nowEstimated();
  }

  /// Forces an immediate re-sync against all configured time sources.
  ///
  /// Temporarily marks the engine as untrusted until the sync completes.
  /// Useful after detecting integrity loss or when the app returns to
  /// the foreground after a long background period.
  static Future<void> forceResync() {
    if (_override != null) return Future.value();
    return TrustedTimeImpl.instance.forceResync();
  }

  /// Registers OS-level background tasks for periodic anchor refreshing.
  ///
  /// On Android, uses WorkManager. On iOS, uses BGTaskScheduler.
  /// On desktop, falls back to a Dart [Timer.periodic].
  /// On web, this is a no-op (browsers suspend background tabs).
  ///
  /// **Prerequisite for real headless refresh** (Android/iOS): call
  /// [registerBackgroundCallback] first with a host-app `@pragma('vm:entry-point')`
  /// function. Without it, background fires fall back to a connectivity-only
  /// HTTPS HEAD probe that does not refresh the anchor — see ADR 0002.
  static Future<void> enableBackgroundSync({
    Duration interval = const Duration(hours: 24),
  }) {
    if (_override != null) return Future.value();
    return TrustedTimeImpl.instance.enableBackgroundSync(interval);
  }

  /// Registers the host-app callback that the OS scheduler will invoke
  /// from a headless [FlutterEngine] for each background fire.
  ///
  /// The callback **must** be a top-level or static function annotated with
  /// `@pragma('vm:entry-point')` to survive tree-shaking in release builds.
  /// In a typical integration the callback simply forwards to
  /// [runBackgroundSync]:
  ///
  /// ```dart
  /// @pragma('vm:entry-point')
  /// void trustedTimeBackgroundCallback() {
  ///   TrustedTime.runBackgroundSync();
  /// }
  ///
  /// void main() {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   TrustedTime.registerBackgroundCallback(trustedTimeBackgroundCallback);
  ///   runApp(MyApp());
  /// }
  /// ```
  ///
  /// Internally resolves the callback to an `int64` handle via
  /// [PluginUtilities.getCallbackHandle] and persists it through the native
  /// plugin (Android `SharedPreferences`, iOS `UserDefaults`). The handle is
  /// stable across app launches as long as the callback's library URI and
  /// function name do not change.
  ///
  /// Throws [ArgumentError] if [callback] is not annotated with
  /// `@pragma('vm:entry-point')` or is otherwise not a top-level/static
  /// function (in which case [PluginUtilities.getCallbackHandle] returns
  /// `null`).
  static Future<void> registerBackgroundCallback(
    void Function() callback,
  ) async {
    if (_override != null) return;
    // Defensive: host apps are expected to call this from `main()` after
    // `WidgetsFlutterBinding.ensureInitialized()`, but the method-channel
    // invoke below requires bindings regardless. Keep symmetric with
    // [runBackgroundSync] which initializes bindings unconditionally.
    WidgetsFlutterBinding.ensureInitialized();
    final handle = PluginUtilities.getCallbackHandle(callback);
    if (handle == null) {
      throw ArgumentError.value(
        callback,
        'callback',
        'Callback handle could not be resolved. The callback must be a '
            "top-level or static function annotated with @pragma('vm:entry-point').",
      );
    }
    await _bgChannel.invokeMethod<void>('setBackgroundCallbackHandle', {
      'handle': handle.toRawHandle(),
    });
  }

  /// Executes a single network sync against the configured time sources and
  /// persists the resulting anchor.
  ///
  /// Designed for use inside the host-app callback registered via
  /// [registerBackgroundCallback]. Bypasses the foreground engine's timer
  /// and integrity-monitor setup; the next foreground call to [initialize]
  /// warm-restores from the freshly persisted anchor.
  ///
  /// Automatically notifies the native plugin of completion so the headless
  /// engine can be torn down inside the OS budget.
  ///
  /// Returns a [TrustedTimeBackgroundResult] describing the outcome.
  static Future<TrustedTimeBackgroundResult> runBackgroundSync({
    TrustedTimeConfig config = const TrustedTimeConfig(),
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (!_timezoneInitialized) {
      tz.initializeTimeZones();
      _timezoneInitialized = true;
    }
    final result = await bg.runBackgroundSync(config: config);
    try {
      await _bgChannel.invokeMethod<void>('notifyBackgroundComplete', {
        'success': result.isSuccess,
        if (result is BackgroundSyncFailure) 'reason': result.reason,
      });
    } catch (_) {
      // Channel may be absent in tests / desktop / web; the result is still
      // valid and persisted, native cleanup is a best-effort signal only.
    }
    return result;
  }

  static const _bgChannel = MethodChannel('trusted_time/background');

  /// Returns trusted local time in a specific IANA timezone.
  ///
  /// Uses the trusted UTC clock and converts to the target timezone
  /// using the embedded IANA timezone database, ensuring the result
  /// is immune to device timezone manipulation.
  ///
  /// ```dart
  /// final tokyoTime = TrustedTime.trustedLocalTimeIn('Asia/Tokyo');
  /// ```
  ///
  /// Throws [TrustedTimeNotReadyException] if the engine is not trusted.
  /// Throws [UnknownTimezoneException] if [timezoneIdentifier] is invalid.
  static DateTime trustedLocalTimeIn(String timezoneIdentifier) {
    if (!isTrusted) throw const TrustedTimeNotReadyException();
    tz.Location location;
    try {
      location = tz.getLocation(timezoneIdentifier);
    } catch (_) {
      throw UnknownTimezoneException(timezoneIdentifier);
    }
    return tz.TZDateTime.from(now(), location);
  }

  /// Injects a [TrustedTimeMock] for hermetic widget or unit testing.
  ///
  /// When a mock is active, all [TrustedTime] static methods delegate to
  /// the mock instead of the real engine.
  ///
  /// Only available in debug/test builds.
  static void overrideForTesting(TrustedTimeMock mock) {
    setTestOverride(mock);
  }

  /// Removes any active mock override and restores production behavior.
  static void resetOverride() {
    setTestOverride(null);
  }

  static TrustedTimeMock? get _override => testOverride;
}
