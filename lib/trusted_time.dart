/// TrustedTime — The absolute source of truth for high-integrity time in Flutter.
///
/// This library provides cryptographically-aware, hardware-anchored UTC timestamps
/// that remain accurate even in adversarial environments where the system clock
/// is manipulated or network time is spoofed.
///
/// ## Core Concepts
///
/// * **Monotonic Anchoring**: We anchor network-verified time to the device's
///   hardware oscillator (monotonic uptime). This creates a virtual clock that
///   cannot be rolled back or forward by the user.
/// * **Consensus (Marzullo)**: We use multi-source quorum resolution to filter
///   out noisy or malicious time authorities.
/// * **Security Intent**: Explicit distinction between "Trusted" (consensus-valid)
///   and "Secure" (NTS-authenticated) time.
///
/// ## Usage Patterns
///
/// ```dart
/// // Unified retrieval: time, posture reason, and caveats in one call
/// final assessment = TrustedTime.getAssessment();
/// if (assessment.isTrusted) {
///   useTimestamp(assessment.time!);
/// }
///
/// // Security-critical gate (e.g. financial ledgering)
/// if (!assessment.isSecure) throw StateError('verified anchor required');
/// ```
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:nts/nts.dart' as nts;
// Unprefixed import for the type that appears in this library's
// public API surface, so the dartdoc-rendered signature of
// `TrustedTime.ntsTrustStatus` matches the unprefixed name
// consumers see via the `export 'package:nts/nts.dart' show ...`
// re-export below. Limited to the single re-exported type to keep
// the rest of the file's `nts.` prefix discipline intact.
import 'package:nts/nts.dart' show NtsTrustStatus;
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
// Two imports against the same library to keep the public API surface clean:
// - The unprefixed `show` makes the re-exported result types usable in
//   public signatures without leaking an internal `bg.` prefix into
//   dartdoc/IDE tooltips.
// - The prefixed `as bg show runBackgroundSync` keeps the internal
//   unit-of-work function reachable without shadowing the static
//   `TrustedTime.runBackgroundSync` defined below.
import 'src/background_sync.dart'
    show
        BackgroundSyncFailure,
        BackgroundSyncStopInfo,
        BackgroundSyncSuccess,
        TrustedTimeBackgroundResult;
import 'src/background_sync.dart' as bg show runBackgroundSync;
import 'src/drift_history.dart';
import 'src/exceptions.dart';
import 'src/models.dart';
import 'src/nts_bootstrap.dart';
import 'src/time_assessment.dart';
import 'src/trusted_time_impl.dart';
import 'src/trusted_time_mock.dart';
import 'src/infra/sync_observer.dart';
import 'src/infra/trusted_time_log.dart';

export 'src/background_sync.dart'
    show
        BackgroundSyncFailure,
        BackgroundSyncStopInfo,
        BackgroundSyncSuccess,
        TrustedTimeBackgroundResult;
export 'src/exceptions.dart';
export 'src/models.dart'
    show
        TrustedTimeConfig,
        TrustAnchor,
        TrustAnchorContributor,
        ConfidenceLevel,
        SyncMetrics;
// TrustMode, TrustBackend, and NtsTrustStatus are part of
// `package:nts`'s public surface and are exposed by this package's
// API:
//   - `TrustMode` is the value type of
//     `TrustedTimeConfig.effectiveTrustMode` (the trust policy the
//     engine derives from `usePlatformTrust` / `customRootCerts`).
//   - `TrustBackend` is the value type of `TimeSample.trustBackend`
//     (the per-handshake observability value).
//   - `NtsTrustStatus` is the return type of
//     `TrustedTime.ntsTrustStatus` (the process-global diagnostic
//     snapshot).
// Re-exported together so consumers can reference all three without
// needing to add `package:nts` to their own pubspec — it is already
// a transitive dependency of this package.
export 'package:nts/nts.dart' show TrustMode, TrustBackend, NtsTrustStatus;
export 'src/time_assessment.dart';
export 'src/drift_history.dart' show DriftBootRecord;
export 'src/trusted_time_mock.dart';
export 'src/infra/sync_observer.dart';
export 'src/infra/trusted_time_log.dart'
    show TrustedTimeLogLevel, TrustedTimeLogSink;
export 'src/sources/nts_auth_level.dart' show NtsAuthLevel;
export 'src/domain/time_sample.dart' show TimeSample;
export 'src/domain/marzullo_engine.dart' show ConsensusResult;
export 'src/domain/time_interval.dart' show TimeInterval;
// TimeSource is the contract consumers must implement to plug
// custom time-authority providers into the engine via the
// additionalSources field on TrustedTimeConfig. Warmable is its
// optional companion for sources whose one-time setup (NTS-KE
// handshake, cache priming, etc.) must complete outside the
// per-query latency budget. Exporting both closes the gap where
// additionalSources was part of the public surface but the types
// it required were only reachable via src/. Plain // comment
// rather than /// because this rationale is for source readers
// of trusted_time.dart, not for generated dartdoc consumers; the
// types' own /// docstrings carry the API documentation.
export 'src/domain/time_source.dart' show TimeSource, Warmable;

/// The primary gateway for high-integrity time synchronization and retrieval.
///
/// [TrustedTime] implements a self-healing operational state machine. It handles
/// initial synchronization, background maintenance, and proactive drift detection.
///
/// Retrieval is unified behind [getAssessment], which answers "what time
/// is it, why, and with what caveats" in a single synchronous call. Check
/// the assessment at meaningful boundaries — after [initialize], on
/// foreground resume, before a high-value operation — rather than caching
/// one result.
abstract final class TrustedTime {
  TrustedTime._();

  static bool _timezoneInitialized = false;

  /// Bootstraps the time integrity subsystem.
  ///
  /// This must be called at app launch. It performs several critical actions:
  /// 1. Initializes the embedded IANA timezone database.
  /// 2. Restores the last known trust anchor from secure storage.
  /// 3. Launches the initial network synchronization cycle **in the
  ///    background** — the returned future does not wait for it.
  ///
  /// The returned future resolves after local work only (storage
  /// restore, reboot check, timer arming); it never blocks on the
  /// network. On a warm start the engine is already trusted when it
  /// resolves; on a cold start the first sync cycle continues in the
  /// background, observable as `getAssessment().syncInProgress` and
  /// awaitable via [firstSyncSettled]:
  ///
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await TrustedTime.initialize(); // Fast: local work only.
  ///   runApp(MyApp()); // Render immediately; check getAssessment()
  ///   //                  (or await firstSyncSettled) for trust.
  /// }
  /// ```
  ///
  /// The error split is deliberate: configuration errors (an invalid
  /// [TrustedTimeConfig] such as `usePlatformTrust` combined with
  /// `customRootCerts`, or an unsatisfiable
  /// [TrustedTimeConfig.requireSleepAwareProjection]) still throw from
  /// this future — fail fast on programmer error. Network outcomes
  /// never do: a failed first sync surfaces as an assessment with
  /// [TrustStatusReason.syncFailed], not as an exception here.
  ///
  /// [onLog] installs a process-global [TrustedTimeLogSink] that
  /// receives every `[TrustedTime]` diagnostic line (per-source sample
  /// results, consensus attribution, degradation warnings) — in release
  /// and profile builds too — so the host can route them into its own
  /// logging pipeline. When omitted, any previously installed sink is
  /// left in place; without a sink, diagnostics fall back to
  /// `debugPrint` in debug builds and are dropped in release/profile
  /// builds. A parameter here rather than a [TrustedTimeConfig] field
  /// because the config documents value-based equality, which a closure
  /// field would silently break. Note that the OS-scheduled background
  /// isolate does not inherit this sink; pass `onLog` to
  /// [runBackgroundSync] separately for background diagnostics.
  static Future<void> initialize({
    TrustedTimeConfig? config,
    TrustedTimeLogSink? onLog,
  }) async {
    if (onLog != null) TrustedTimeLog.sink = onLog;
    if (!_timezoneInitialized) {
      tz.initializeTimeZones();
      _timezoneInitialized = true;
    }
    if (_override != null) return;

    config ??= const TrustedTimeConfig();

    // Initialize the flutter_rust_bridge runtime backing package:nts
    // before any NtsSource is constructed, degrading to an NTS-disabled
    // config if the FFI bootstrap genuinely fails. The gating,
    // already-initialised-as-success, and degrade semantics live in the
    // shared ensureNtsRuntime helper so the headless background isolate
    // (runBackgroundSync) performs the identical bootstrap — see
    // trusted_time-y81.
    config = await ensureNtsRuntime(config);

    await TrustedTimeImpl.init(config);
  }

  /// Completes when the first sync cycle has concluded — success or
  /// failure alike.
  ///
  /// [initialize] resolves after local work only; on a cold start the
  /// first network sync continues in the background. This future is
  /// the explicit rendezvous for callers who need a definitive first
  /// answer before proceeding (a launch gate, a compliance check):
  ///
  /// ```dart
  /// await TrustedTime.initialize();
  /// runApp(MyApp());
  /// // Elsewhere, when a definitive answer is required:
  /// await TrustedTime.firstSyncSettled;
  /// final assessment = TrustedTime.getAssessment();
  /// // reason is now a concluded posture: synchronized / degraded /
  /// // syncFailed — not an in-flight neverSynced.
  /// ```
  ///
  /// It reports *conclusion, not outcome*: after it completes, consult
  /// [getAssessment] for the verdict. On a warm start (persisted
  /// anchor restored) it is already complete when [initialize]
  /// resolves. It also completes if the engine is disposed before the
  /// first cycle concludes, so a waiter never hangs across teardown.
  /// Re-initializing creates a fresh engine with a fresh first-sync
  /// gate.
  ///
  /// Under a [TrustedTimeMock] override this returns an
  /// already-completed future (mock time needs no sync), whether or
  /// not [initialize] was ever called. When not overridden,
  /// [initialize] must have completed first.
  static Future<void> get firstSyncSettled {
    if (_override != null) return Future.value();
    return TrustedTimeImpl.instance.firstSyncSettled;
  }

  /// Synchronously evaluates the current time and its trust posture.
  ///
  /// Returns a [TimeAssessment] — one immutable snapshot answering
  /// "what time is it?" ([TimeAssessment.time]), "why is it reported
  /// this way?" ([TimeAssessment.reason]) and "what are the caveats?"
  /// ([TimeAssessment.authLevel], [TimeAssessment.confidence],
  /// [TimeAssessment.uncertainty], [TimeAssessment.anchorAge]).
  ///
  /// The call is cheap (arithmetic projection on the monotonic
  /// timeline, no platform-channel or network I/O) and never throws
  /// for posture reasons: when no trust anchor exists,
  /// [TimeAssessment.time] is `null` and [TimeAssessment.reason]
  /// explains why ([TrustStatusReason.neverSynced],
  /// [TrustStatusReason.rebootDetected], or
  /// [TrustStatusReason.syncFailed]).
  ///
  /// Typical pull-model usage — assess at meaningful boundaries rather
  /// than caching one result:
  ///
  /// ```dart
  /// Future<void> placeOrder(Order order) async {
  ///   final assessment = TrustedTime.getAssessment();
  ///   switch (assessment.reason) {
  ///     case TrustStatusReason.synchronized:
  ///       submitOrder(order, timestamp: assessment.time!);
  ///     case TrustStatusReason.degraded:
  ///       // Time is usable, cryptographic guarantees are not.
  ///       submitOrder(order, timestamp: assessment.time!, flagged: true);
  ///     case TrustStatusReason.neverSynced:
  ///     case TrustStatusReason.rebootDetected:
  ///     case TrustStatusReason.syncFailed:
  ///       await TrustedTime.forceResync();
  ///   }
  /// }
  /// ```
  ///
  /// For strict enforcement, gate on the derived properties: require
  /// [TimeAssessment.isSecure] before trusting the timestamp for
  /// signature-grade operations, or combine [TimeAssessment.confidence]
  /// and [TimeAssessment.uncertainty] against application thresholds.
  static TimeAssessment getAssessment() {
    if (_override != null) return _override!.getAssessment();
    return TrustedTimeImpl.instance.getAssessment();
  }

  /// Returns the recorded per-boot oscillator drift history, oldest →
  /// newest.
  ///
  /// Pure diagnostics: each [DriftBootRecord] summarizes the drift of
  /// the device's uptime clock against network-consensus UTC over one
  /// boot session, collected passively from applied trust anchors and
  /// persisted across restarts (up to the 10 most recent boots). Only
  /// the **current** boot's observation ever influences
  /// [TimeAssessment.driftCorrectedTime]; prior boots are reported
  /// here for observability and field analysis only.
  ///
  /// Empty until at least one anchor with a boot identifier has been
  /// applied. Under a [TrustedTimeMock] override this returns an empty
  /// list (mock time has no oscillator to observe).
  static List<DriftBootRecord> getDriftHistory() {
    if (_override != null) return const [];
    return TrustedTimeImpl.instance.driftHistory;
  }

  /// Returns the [TrustedTimeConfig] the engine is currently running
  /// against.
  ///
  /// Useful for verifying the active server pool, quorum thresholds,
  /// and refresh interval at runtime — for example, to confirm in a
  /// benchmarking UI that the chip-grid selection matches the live
  /// engine configuration.
  ///
  /// The returned object is typically the same instance that was
  /// passed to [initialize], but [initialize] may normalise it before
  /// handing it to the engine — most notably by stripping
  /// [TrustedTimeConfig.ntsServers] when the underlying NTS runtime
  /// fails to load — so do not rely on
  /// `identical(TrustedTime.config, suppliedConfig)` holding.
  ///
  /// Reading list-typed fields is safe to do without defensive
  /// copying as long as the caller does not mutate the lists they
  /// passed to [initialize]; see [TrustedTimeConfig] for the
  /// immutability contract.
  ///
  /// Under a test override returns a default [TrustedTimeConfig] so
  /// callers do not need to special-case the mocked path.
  static TrustedTimeConfig get config {
    if (_override != null) return const TrustedTimeConfig();
    return TrustedTimeImpl.instance.config;
  }

  /// Returns a process-global snapshot of `package:nts`'s
  /// trust-anchor diagnostic state.
  ///
  /// Pass-through wrapper around `nts.ntsTrustStatus()` with no
  /// transformation: the underlying call is documented as seven
  /// atomic-Relaxed loads, cheap enough to call from a UI poll loop
  /// or a pre-flight "can I even validate against the platform
  /// store?" check. The returned [NtsTrustStatus] exposes:
  ///
  /// - `defaultClientBackend`: backend the *default singleton*
  ///   `NtsClient` (used by `package:nts`'s top-level convenience
  ///   functions) most recently resolved to. `null` until a
  ///   handshake has run against the singleton. Per-source
  ///   `NtsSource` handshakes use caller-minted clients (see
  ///   `trusted_time-51z`) and do not update this field; their
  ///   per-handshake backend identity is on
  ///   [TimeSample.trustBackend] instead.
  /// - `defaultBackendPlatformCount`,
  ///   `defaultBackendHybridCount`, `defaultBackendWebpkiCount`, and
  ///   `defaultBackendCustomCount`: cumulative counts of default-
  ///   singleton handshakes that resolved to each `TrustBackend`
  ///   (`platform`, `platformWithHybridFallback`, `webpkiRoots`,
  ///   `custom` respectively); together they partition the singleton's
  ///   resolution history. `defaultBackendHybridCount` is always zero
  ///   off Android, and the default singleton never selects `custom`,
  ///   so `defaultBackendCustomCount` stays zero unless a caller
  ///   drives the singleton with custom roots.
  /// - `androidPlatformInitSucceeded`: `true` iff the Android JNI
  ///   bootstrap reported success at least once. `false` on every
  ///   non-Android platform (no JNI bootstrap exists). This is a
  ///   process-global `package:nts` diagnostic about platform-store
  ///   *availability*, independent of any engine's
  ///   [TrustedTimeConfig.effectiveTrustMode]. A `false` value on
  ///   Android means the platform trust store could not be
  ///   initialised, so a handshake that *would consult it* — a
  ///   `platformOnly` client, or the platform leg of
  ///   `platformWithFallback` — cannot; `platformWithFallback`
  ///   resolves via its `webpki-roots` fallback instead. Trust modes
  ///   that never touch the platform store are unaffected:
  ///   `bundledOnly` validates against the static bundle by
  ///   definition, and `custom` validates against only the
  ///   caller-supplied roots — neither falls back as a consequence of
  ///   this flag.
  /// - `androidHybridFallbackCount`: cumulative count of TLS
  ///   chains the Android hybrid verifier has accepted via the
  ///   `webpki-roots` fallback path since process start. Always
  ///   zero on non-Android platforms. Non-zero on Android indicates
  ///   at least one chain arrived whose only platform-side failure
  ///   was a curated fallback-eligible shape.
  ///
  /// Per-counter monotonicity holds across consecutive snapshots;
  /// the snapshot is intended for human / dashboard consumption,
  /// not for cross-thread synchronisation.
  ///
  /// Throws `StateError` if `package:nts`'s `NtsRustLib.init()` has
  /// not completed (matches `nts.ntsTrustStatus()`'s contract).
  /// [TrustedTime.initialize] performs the FFI bootstrap when
  /// [TrustedTimeConfig.ntsServers] is non-empty; calling this
  /// method before [initialize], or after [initialize] when the
  /// active config has empty `ntsServers`, may surface that error.
  // The return type is the unprefixed `NtsTrustStatus` so the
  // public dartdoc matches what consumers see after this library's
  // re-export above; using `nts.NtsTrustStatus` here would leak
  // this file's import alias into every generated signature page
  // even though both names refer to the same class.
  static NtsTrustStatus ntsTrustStatus() => nts.ntsTrustStatus();

  /// Returns `true` if the system is configured to support Network Time
  /// Security (NTS).
  static bool get supportsSecureTime {
    if (_override != null) return false;
    return TrustedTimeImpl.instance.supportsSecureTime;
  }

  /// Whether the projection behind [TimeAssessment.time] rides a
  /// sleep-aware monotonic timeline.
  ///
  /// `true` when elapsed time since the last trust anchor is measured on
  /// the `package:nts` monotonic clock (`CLOCK_BOOTTIME` /
  /// `mach_continuous_time` / `QueryInterruptTimePrecise`), which keeps
  /// counting through device suspend. `false` when the engine is on the
  /// suspend-frozen `Stopwatch` fallback — NTP-only configs
  /// or a failed nts bridge bootstrap — where a device sleep between
  /// syncs leaves the projected time behind by the sleep duration until
  /// the next sync.
  ///
  /// Consumers for whom the frozen fallback is unacceptable should set
  /// [TrustedTimeConfig.requireSleepAwareProjection] instead of polling
  /// this getter; the config gate fails closed at [initialize] and
  /// assessment time. Under a [TrustedTimeMock] override this returns
  /// `true` (mock time is script-driven and does not drift during
  /// suspend).
  static bool get isProjectionSleepAware {
    if (_override != null) return true;
    return TrustedTimeImpl.instance.isProjectionSleepAware;
  }

  /// Hooks into the internal synchronization lifecycle.
  ///
  /// Register a [SyncObserver] to receive machine-readable [SyncMetrics],
  /// including latency, uncertainty, and consensus participant counts.
  /// Useful for enterprise-grade telemetry and observability.
  static void registerObserver(SyncObserver observer) {
    if (_override != null) return;
    TrustedTimeImpl.instance.registerObserver(observer);
  }

  /// Detaches a previously registered [SyncObserver].
  static void unregisterObserver(SyncObserver observer) {
    if (_override != null) return;
    TrustedTimeImpl.instance.unregisterObserver(observer);
  }

  /// Forces an immediate network synchronization cycle.
  ///
  /// This purges the current anchor and forces the engine into an active
  /// sampling phase. Useful for recovering from an integrity loss or
  /// manually refreshing an aged anchor.
  static Future<void> forceResync() {
    if (_override != null) return Future.value();
    return TrustedTimeImpl.instance.forceResync();
  }

  /// Schedules OS-level background tasks to keep the trust anchor fresh.
  ///
  /// Leverages platform-native schedulers (WorkManager on Android,
  /// BGTaskScheduler on iOS) to perform periodic maintenance while the
  /// app is backgrounded. On desktop (Linux/macOS/Windows), falls back
  /// to a Dart [Timer.periodic] inside the running isolate.
  ///
  /// **Prerequisites for real headless refresh** (Android/iOS): call
  /// [registerBackgroundCallback] first with a host-app
  /// `@pragma('vm:entry-point')` function. On iOS, additionally wire
  /// `TrustedTimePlugin.setPluginRegistrantCallback` in the AppDelegate
  /// so plugins can be registered onto the headless engine (Android
  /// auto-registers plugins on engine creation). If either is missing,
  /// background fires complete as no-ops — no anchor refresh and no
  /// network activity; the package only ever contacts the configured
  /// time sources — see ADR 0002.
  ///
  /// **Interval granularity**: [interval] is applied at minute resolution.
  /// On both Android and iOS the Dart layer rounds fractional minutes
  /// **up** to the next whole minute (never scheduling more frequently
  /// than requested — this is battery-sensitive OS work) and clamps the
  /// result to `[15 min, 1 week]` before it reaches the platform
  /// scheduler. The 15-minute floor mirrors Android [WorkManager]'s hard
  /// minimum on periodic work and is applied on iOS too, for
  /// cross-platform consistency (BGTaskScheduler treats the interval as
  /// a hint anyway).
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
  /// import 'dart:async';
  ///
  /// @pragma('vm:entry-point')
  /// void trustedTimeBackgroundCallback() {
  ///   // Host callback is `void Function()`, so awaiting is not possible;
  ///   // `unawaited(...)` makes the fire-and-forget intent explicit and
  ///   // keeps the `unawaited_futures` lint clean for hosts that adopt it.
  ///   unawaited(TrustedTime.runBackgroundSync());
  /// }
  ///
  /// void main() {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   unawaited(
  ///     TrustedTime.registerBackgroundCallback(trustedTimeBackgroundCallback),
  ///   );
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
  /// On Android and iOS, throws [ArgumentError] if
  /// [PluginUtilities.getCallbackHandle] cannot resolve a handle for
  /// [callback]. To be resolvable, the callback must:
  ///
  /// - be a top-level or static function (closures and instance methods
  ///   are not supported by the Dart VM's callback-handle mechanism), and
  /// - in release builds, be annotated with `@pragma('vm:entry-point')`
  ///   so it survives tree-shaking.
  ///
  /// Note: the `@pragma` annotation is enforced by the Dart compiler at
  /// build time, not at runtime; this method only observes whether the
  /// VM was able to produce a handle.
  ///
  /// Registration is a no-op on platforms that do not run an OS background
  /// scheduler — desktop (Linux/macOS/Windows). The platform check
  /// happens before [PluginUtilities.getCallbackHandle], so a host that
  /// passes a closure on those platforms will not see [ArgumentError]
  /// either; the dev-time validation only runs where the registered
  /// callback could actually be invoked. In unit tests that have not
  /// mocked the `trusted_time/background` method channel, the resulting
  /// [MissingPluginException] is also swallowed so hosts can call this
  /// unconditionally from shared startup code.
  static Future<void> registerBackgroundCallback(
    void Function() callback,
  ) async {
    if (_override != null) return;
    // Skip on platforms that do not run an OS background scheduler. The
    // OS-side WorkManager/BGTaskScheduler hooks only exist on Android and
    // iOS; on desktop the persisted handle would never be read, so
    // spending dev-time validation on the callback shape (closure vs
    // top-level) only adds friction to shared startup code.
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
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
        'Could not resolve a callback handle. The callback must be a '
            'top-level or static function; in release builds it must also '
            "be annotated with @pragma('vm:entry-point') to survive "
            'tree-shaking.',
      );
    }
    try {
      await _bgChannel.invokeMethod<void>('setBackgroundCallbackHandle', {
        'handle': handle.toRawHandle(),
      });
    } on MissingPluginException {
      // Channel is absent on platforms without a native trusted_time
      // implementation (desktop) and in unit tests that have not
      // mocked it. Treat registration as a no-op there so hosts can call
      // it unconditionally from shared startup code; on platforms that do
      // not run the OS scheduler, the handle would be unused anyway.
    }
  }

  /// Executes a single network sync against the configured time sources and,
  /// by default, persists the resulting anchor.
  ///
  /// Designed for use inside the host-app callback registered via
  /// [registerBackgroundCallback]. Bypasses the foreground engine's timer
  /// and integrity-monitor setup; the next foreground call to [initialize]
  /// warm-restores from the freshly persisted anchor. Tier classification
  /// and truth-box admission (Secure Time Contract / ADR 0007) run inside
  /// the sync engine, so the persisted anchor carries the same `authLevel`
  /// and `confidence` semantics as a foreground cycle.
  ///
  /// Persistence is governed by [TrustedTimeConfig.persistState] (default
  /// `true`). When `false`, a successful run still returns a
  /// [BackgroundSyncSuccess] but the anchor is *not* written to storage —
  /// the next foreground [initialize] will not see the freshly fetched
  /// value. This override exists primarily for tests and for hosts that
  /// want to drive their own persistence outside the bundled
  /// `flutter_secure_storage` path.
  ///
  /// Automatically notifies the native plugin of completion so the headless
  /// engine can be torn down inside the OS budget.
  ///
  /// **Post-sync work must go in [onResult], not after the returned
  /// future.** On Android the native worker destroys the headless
  /// [FlutterEngine] as soon as it receives the completion signal, which
  /// this method sends internally *before* returning. Any code the caller
  /// runs after `await runBackgroundSync(...)` therefore races engine
  /// teardown and is liable to be killed mid-execution — silently, for
  /// async work such as file or channel I/O. [onResult] is awaited
  /// *before* the completion signal is sent, so work done inside it (e.g.
  /// appending to an on-disk log) is guaranteed to finish while the
  /// engine is still alive. An error thrown from [onResult] is logged and
  /// swallowed: observer-side failures must not turn a completed sync
  /// into a failed background fire, nor delay the native completion
  /// signal beyond the OS budget.
  ///
  /// When a [TrustedTimeMock] is active via [overrideForTesting], this method
  /// short-circuits before any network I/O, secure-storage write, or
  /// platform-channel traffic, and returns a deterministic
  /// [BackgroundSyncSuccess] synthesized from the mock's current time. This
  /// keeps the override contract consistent with the rest of the static API
  /// (where every method delegates to the mock) and prevents tests that
  /// invoke the registered background callback from accidentally exercising
  /// the real sync engine.
  ///
  /// **In-run retry**: a transient sync failure ([TrustedTimeSyncException])
  /// is retried within the same run before the failure is reported, on a
  /// platform-sized schedule — twice on Android (after 10 s and 20 s
  /// waits, fitting the 9-minute worker budget), once on iOS (after a 2 s
  /// wait, fitting the ~30 s `BGAppRefreshTask` budget) — because the OS
  /// scheduler's own retry can be deferred for hours under doze while
  /// this run still has budget left. Non-transient errors (e.g. an
  /// invalid config) fail immediately. [retryDelays] overrides that
  /// schedule for tests only.
  ///
  /// [onLog] installs the process-global [TrustedTimeLogSink] for this
  /// background isolate before the sync runs. The headless isolate is
  /// freshly spawned by the OS scheduler and does not inherit the sink
  /// passed to [initialize] in the main isolate, so background
  /// diagnostics need their own installation here.
  ///
  /// Returns a [TrustedTimeBackgroundResult] describing the outcome.
  static Future<TrustedTimeBackgroundResult> runBackgroundSync({
    TrustedTimeConfig config = const TrustedTimeConfig(),
    Future<void> Function(TrustedTimeBackgroundResult result)? onResult,
    TrustedTimeLogSink? onLog,
    @visibleForTesting List<Duration>? retryDelays,
  }) async {
    if (onLog != null) TrustedTimeLog.sink = onLog;
    // Honor the test-mock override before any side-effecting work. Mirrors
    // the early-return pattern in initialize / now / enableBackgroundSync /
    // registerBackgroundCallback so the dartdoc claim on
    // overrideForTesting ("all static methods delegate to the mock") holds
    // for the headless entrypoint as well.
    final override = _override;
    if (override != null) {
      final nowMs = override.now.millisecondsSinceEpoch;
      final synthetic = BackgroundSyncSuccess(
        anchor: TrustAnchor(
          networkUtcMs: nowMs,
          // Mock has no uptime / wall / uncertainty surface; synthesize zero
          // values rather than reaching for PlatformMonotonicClock here.
          uptimeMs: 0,
          wallMs: nowMs,
          uncertaintyMs: 0,
        ),
        elapsed: Duration.zero,
      );
      // The hook contract ("onResult observes every outcome") holds under
      // the mock too, so host code exercised in tests behaves as it will
      // in production — including the binding guarantee: the production
      // path below initializes bindings before the hook runs, so a hook
      // that touches MethodChannels (background-fire logging/telemetry)
      // must see the same environment under the override.
      WidgetsFlutterBinding.ensureInitialized();
      await _invokeOnResult(onResult, synthetic);
      return synthetic;
    }
    WidgetsFlutterBinding.ensureInitialized();
    final result = await bg.runBackgroundSync(
      config: config,
      retryDelays: retryDelays,
    );
    // Awaited BEFORE the completion signal below: the native worker
    // destroys the headless engine as soon as it receives that signal, so
    // this is the last point where caller-side async work is guaranteed
    // to run to completion (see dartdoc).
    await _invokeOnResult(onResult, result);
    try {
      await _bgChannel.invokeMethod<void>('notifyBackgroundComplete', {
        'success': result.isSuccess,
        if (result is BackgroundSyncFailure) ...{
          'reason': result.reason,
          // Android maps retryable=false to Result.failure() (skip this
          // interval; the periodic chain continues) instead of
          // Result.retry() — re-running a non-transient failure such as
          // an invalid config would fail identically every time.
          'retryable': result.retryable,
        },
      });
    } on MissingPluginException {
      // Channel is absent on desktop and in unit tests that have not
      // mocked it. The sync itself has already run to completion — with the
      // anchor persisted only on success and when config.persistState is
      // set — so native cleanup is a best-effort signal only.
    } catch (e, s) {
      // Surfacing other failures (channel wired but handler errored, etc.)
      // matters operationally — without this signal the native worker
      // waits the full budget then retries unnecessarily.
      developer.log(
        'TrustedTime.runBackgroundSync: failed to notify native completion',
        name: 'trusted_time',
        level: 900,
        error: e,
        stackTrace: s,
      );
    }
    return result;
  }

  /// Queries the OS scheduler for the state of the background-sync work
  /// and the reason the *previous* run attempt was stopped.
  ///
  /// On Android, reads WorkManager's `WorkInfo` for the unique periodic
  /// work registered by [enableBackgroundSync] and surfaces
  /// `WorkInfo.getStopReason()` (populated with real values on API 31+;
  /// earlier releases report `NOT_STOPPED`). Intended as a diagnostic to be
  /// logged at the start of a background fire, answering "was the last
  /// attempt killed by timeout / quota / device state?" without shell
  /// access to `dumpsys jobscheduler`.
  ///
  /// On iOS, reports whether the *previous* headless BGTask attempt was
  /// terminated by the BGTaskScheduler expiration handler: `stopReason`
  /// is `3` ([BackgroundSyncStopInfo.stopReasonName] `TIMEOUT`, the
  /// nearest WorkManager analogue) and `state` carries the expiration
  /// instant as `EXPIRED(<ISO-8601>)` so the report can be paired with
  /// the fire it explains. The breadcrumb is consumed pessimistically:
  /// a normally completed attempt clears it, so it is reported after the
  /// expired fire only, never re-attributed to a later healthy one.
  ///
  /// Returns `null` when no answer is available: on desktop (no
  /// handler for this method, or the channel itself is absent), on iOS
  /// when the previous attempt did not expire, when no background work
  /// has been scheduled yet, and under a [TrustedTimeMock] override.
  /// Platform-side query failures are logged and also surface as `null`
  /// — this is a best-effort diagnostic and must never turn a healthy
  /// fire into a failed one.
  static Future<BackgroundSyncStopInfo?> getBackgroundStopReason() async {
    if (_override != null) return null;
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final raw = await _bgChannel.invokeMapMethod<String, Object?>(
        'getBackgroundStopReason',
      );
      if (raw == null) return null;
      final state = raw['state'];
      final stopReason = raw['stopReason'];
      if (state is! String || stopReason is! int) return null;
      return BackgroundSyncStopInfo(state: state, stopReason: stopReason);
    } on MissingPluginException {
      // Channel absent (desktop, unmocked unit tests) or the platform
      // answered notImplemented (iOS has no WorkManager analogue). Either
      // way: no scheduler-side stop reason to report.
      return null;
    } on PlatformException catch (e, s) {
      // Genuine Android-side query failures (the plugin's
      // STOP_REASON_UNAVAILABLE error). Non-fatal for a diagnostic
      // accessor.
      developer.log(
        'TrustedTime.getBackgroundStopReason: platform query failed',
        name: 'trusted_time',
        level: 900,
        error: e,
        stackTrace: s,
      );
      return null;
    } catch (e, s) {
      // Anything else — e.g. a TypeError from invokeMapMethod when the
      // platform returns an unexpected map shape. The dartdoc promises
      // best-effort null on failure, so no error may escape here.
      developer.log(
        'TrustedTime.getBackgroundStopReason: unexpected error',
        name: 'trusted_time',
        level: 900,
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  /// Runs the caller's [runBackgroundSync] `onResult` hook, logging and
  /// swallowing any error it throws.
  ///
  /// Observer-side failures must neither turn a completed sync into a
  /// failed background fire nor block the native completion signal.
  static Future<void> _invokeOnResult(
    Future<void> Function(TrustedTimeBackgroundResult result)? onResult,
    TrustedTimeBackgroundResult result,
  ) async {
    if (onResult == null) return;
    try {
      await onResult(result);
    } catch (e, s) {
      developer.log(
        'TrustedTime.runBackgroundSync: onResult hook threw',
        name: 'trusted_time',
        level: 900,
        error: e,
        stackTrace: s,
      );
    }
  }

  static const _bgChannel = MethodChannel('trusted_time/background');

  /// Whether automatic refresh is currently enabled.
  ///
  /// Reflects the library's intent — `false` when
  /// [pauseAutomaticRefresh] has been called or when
  /// [setRefreshInterval] was called with a non-positive duration —
  /// not whether a [Timer] object is armed at this exact moment.
  /// The library's *automatic* re-arming runs at the end of a
  /// successful sync cycle, so this getter can return `true` while
  /// no timer is yet pending (e.g. after a fresh [initialize] before
  /// the bootstrap sync has completed, or in the recovery window
  /// after a failed sync where only the retry timer is armed).
  /// Explicit calls to [resumeAutomaticRefresh] and
  /// [setRefreshInterval] also arm a fresh refresh timer from the
  /// time of the call independent of cycle completion.
  ///
  /// `false` guarantees the engine initiates no anchor-age-driven
  /// syncs: both the automatic refresh timer and the resume-time
  /// staleness check are suppressed. Sync cycles triggered by
  /// [forceResync], integrity events, the failed-sync retry timer,
  /// background platform schedulers, or an unanchored resume
  /// *establish* attempt still run while this is `false`.
  static bool get automaticRefreshActive {
    if (_override != null) return false;
    return TrustedTimeImpl.instance.automaticRefreshActive;
  }

  /// Pauses the engine's automatic refresh timer.
  ///
  /// Cancels any pending refresh and prevents subsequent successful
  /// syncs from re-arming it. Use this when an application-level
  /// scheduler wants to drive sync cadence directly via
  /// [forceResync] without contention from the library's internal
  /// timer (benchmarking harnesses, deterministic test harnesses,
  /// battery-sensitive consumers that schedule their own checks).
  ///
  /// Pause suppresses both anchor-age-driven sync mechanisms: the
  /// *automatic refresh* timer and the resume-time anchor staleness
  /// check (an anchored engine no longer resyncs on foreground
  /// resume, however stale the anchor). The following continue to
  /// operate while paused:
  ///  * the retry timer scheduled by a failed sync (recovery from a
  ///    failed bootstrap or a failed refresh still proceeds);
  ///  * sync cycles triggered by [forceResync];
  ///  * the unanchored resume *establish* attempt (a resume with no
  ///    trusted anchor is a bootstrap analogue, not a staleness
  ///    refresh);
  ///  * platform background sync if it was enabled.
  /// Consumers that want to fully suppress all engine-driven syncs
  /// should pause this timer *and* either avoid configuring
  /// background sync at init or call into the platform layer
  /// directly to disable it.
  ///
  /// Idempotent. Resume with [resumeAutomaticRefresh] or by calling
  /// [setRefreshInterval] with a positive duration.
  static void pauseAutomaticRefresh() {
    if (_override != null) return;
    TrustedTimeImpl.instance.pauseAutomaticRefresh();
  }

  /// Resumes the automatic refresh timer using the active interval
  /// (see [setRefreshInterval]; defaults to the
  /// [TrustedTimeConfig.refreshInterval] passed to [initialize]).
  ///
  /// Arms a refresh timer immediately, scheduled for one active
  /// interval from the time of this call. Any previously-pending
  /// refresh timer is cancelled and re-armed. Calling this while
  /// already enabled therefore pushes the next-refresh deadline
  /// out — safe to call repeatedly without raising, but the
  /// deadline is not invariant. Use [automaticRefreshActive] to
  /// gate calls when that matters.
  ///
  /// The "from the time of the call" deadline is itself only the
  /// *initial* arming. If a sync runs between this call and the
  /// timer firing — whether driven by [forceResync], an integrity
  /// event, or platform background sync — the engine cancels the
  /// pending refresh at the start of the cycle and (on success)
  /// re-arms a fresh refresh timer measured from that cycle's
  /// completion. The deadline is therefore best treated as
  /// "no later than `activeInterval` from the most recent of
  /// `[resumeAutomaticRefresh, setRefreshInterval(positive),
  /// successful sync completion]`".
  static void resumeAutomaticRefresh() {
    if (_override != null) return;
    TrustedTimeImpl.instance.resumeAutomaticRefresh();
  }

  /// Replaces the automatic refresh interval at runtime without
  /// requiring a full [initialize] call.
  ///
  /// Arms a refresh timer immediately, scheduled for [interval]
  /// from the time of this call (any pending refresh is cancelled
  /// and re-armed). As with [resumeAutomaticRefresh], any sync that
  /// runs before the timer fires (via [forceResync], an integrity
  /// event, or platform background sync) cancels the pending
  /// refresh and the success path re-arms from cycle completion
  /// using the new active interval — the deadline is therefore best
  /// treated as "no later than [interval] from the most recent of
  /// `[setRefreshInterval(interval), resumeAutomaticRefresh,
  /// successful sync completion]`".
  ///
  /// An [interval] of [Duration.zero] (or negative) is equivalent
  /// to [pauseAutomaticRefresh] — the timer is cancelled and not
  /// re-armed. The previously-set positive interval is preserved
  /// across this pause: a subsequent [resumeAutomaticRefresh]
  /// re-arms the timer using the most recent positive value
  /// (rather than treating [Duration.zero] as the new active
  /// interval). To replace the active interval with a different
  /// positive value, call this method again with that value.
  ///
  /// The original at-init value remains accessible via
  /// [TrustedTime.config].
  static void setRefreshInterval(Duration interval) {
    if (_override != null) return;
    TrustedTimeImpl.instance.setRefreshInterval(interval);
  }

  /// Returns trusted local time in the specified IANA timezone.
  ///
  /// Converts the trusted UTC time to the target timezone using the
  /// embedded IANA database. This ensures the result is immune to
  /// device-level timezone manipulation.
  ///
  /// Throws [TrustedTimeNotReadyException] when no live trust anchor
  /// exists (check [getAssessment] first to learn why), and
  /// [UnknownTimezoneException] if the [timezoneIdentifier] is not
  /// found in the database.
  static DateTime trustedLocalTimeIn(String timezoneIdentifier) {
    final assessment = getAssessment();
    final utcTime = assessment.time;
    if (utcTime == null) throw const TrustedTimeNotReadyException();
    tz.Location location;
    try {
      location = tz.getLocation(timezoneIdentifier);
    } catch (_) {
      throw UnknownTimezoneException(timezoneIdentifier);
    }
    return tz.TZDateTime.from(utcTime, location);
  }

  /// Injects a mock implementation for hermetic unit and widget testing.
  ///
  /// Under an override, all static methods of [TrustedTime] delegate to the
  /// mock, ensuring tests are deterministic and network-independent.
  static void overrideForTesting(TrustedTimeMock mock) {
    setTestOverride(mock);
  }

  /// Restores standard production behavior by removing any active mock override.
  static void resetOverride() {
    setTestOverride(null);
  }

  static TrustedTimeMock? get _override => testOverride;
}
