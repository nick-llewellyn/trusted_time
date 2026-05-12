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
/// // Standard high-integrity retrieval
/// final now = TrustedTime.now();
///
/// // Security-critical query (e.g. financial ledgering)
/// final secureNow = TrustedTime.getTime(requireSecure: true);
/// ```
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
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
import 'src/exceptions.dart';
import 'src/integrity_event.dart';
import 'src/models.dart';
import 'src/trusted_time_estimate.dart';
import 'src/trusted_time_impl.dart';
import 'src/trusted_time_mock.dart';
import 'src/infra/sync_observer.dart';
import 'src/sources/nts_auth_level.dart';

export 'src/exceptions.dart';
export 'src/integrity_event.dart';
export 'src/models.dart'
    show TrustedTimeConfig, TrustAnchor, ConfidenceLevel, SyncMetrics;
// TrustMode, TrustBackend, and NtsTrustStatus are part of
// `package:nts`'s public surface and are exposed by this package's
// API:
//   - `TrustMode` is the value type of
//     `TrustedTimeConfig.ntsTrustMode` (the build-time policy knob).
//   - `TrustBackend` is the value type of `TimeSample.trustBackend`
//     (the per-handshake observability value).
//   - `NtsTrustStatus` is the return type of
//     `TrustedTime.ntsTrustStatus` (the process-global diagnostic
//     snapshot).
// Re-exported together so consumers can reference all three without
// needing to add `package:nts` to their own pubspec — it is already
// a transitive dependency of this package.
export 'package:nts/nts.dart' show TrustMode, TrustBackend, NtsTrustStatus;
export 'src/trusted_time_estimate.dart';
export 'src/trusted_time_mock.dart';
export 'src/infra/sync_observer.dart';
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
/// For most use cases, [now] is the preferred retrieval method. For high-security
/// applications, use [getTime] to enforce specific cryptographic or confidence
/// requirements.
abstract final class TrustedTime {
  TrustedTime._();

  static bool _timezoneInitialized = false;

  /// Bootstraps the time integrity subsystem.
  ///
  /// This must be called at app launch. It performs several critical actions:
  /// 1. Initializes the embedded IANA timezone database.
  /// 2. Restores the last known trust anchor from secure storage.
  /// 3. Launches the initial network synchronization cycle.
  ///
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await TrustedTime.initialize(); // Essential first step
  ///   runApp(MyApp());
  /// }
  /// ```
  static Future<void> initialize({TrustedTimeConfig? config}) async {
    if (!_timezoneInitialized) {
      tz.initializeTimeZones();
      _timezoneInitialized = true;
    }
    if (_override != null) return;

    // Use Web-compatible configuration on Web/WASM platforms
    if (config == null && kIsWeb) {
      config = TrustedTimeConfig.web();
    } else {
      config ??= const TrustedTimeConfig();
    }

    // Initialize the flutter_rust_bridge runtime backing package:nts
    // before any NtsSource is constructed.  Gated on
    // ntsServers.isNotEmpty to preserve the package's "zero overhead
    // when unused" guarantee.  RustLib uses a process-wide singleton:
    // a second init() call within the same process throws
    // `StateError: Should not initialize flutter_rust_bridge twice`.
    // That happens whenever the host app re-initialises TrustedTime
    // (benchmark UIs that cycle the engine through different source
    // pools, hot-restart in development, etc.). We treat the
    // "already initialised" StateError as success so re-init flows
    // do not silently strip ntsServers and leave the engine with
    // zero sources for the rest of the process lifetime. Other
    // exceptions (missing native asset, arch mismatch, etc.) are
    // still treated as real failures and disable NTS for this
    // configuration.
    if (config.ntsServers.isNotEmpty) {
      try {
        await nts.RustLib.init();
      } catch (e) {
        // Detect "already initialised" loosely: any StateError whose
        // message references flutter_rust_bridge. The exact phrase
        // "Should not initialize flutter_rust_bridge twice" is the
        // current upstream wording but is not part of any public API
        // contract; matching just the package name is robust to
        // wording / capitalisation drift across frb releases while
        // still narrow enough not to swallow unrelated StateErrors
        // from other code paths. The case-insensitive comparison
        // (lowercasing both sides) is the source of that
        // capitalisation robustness — without it we would only
        // accept the canonical lowercase package name as it appears
        // in upstream's current panic, defeating the safety margin
        // the loose match was added for. If frb starts throwing
        // StateError for genuinely new structural failures we will
        // need to revisit, but the failure mode of an unrecognised
        // double-init (silently disabling NTS) is significantly
        // worse than the failure mode of an unrecognised real error
        // (the engine will surface it at first NTS use).
        final message = e is StateError ? e.message.toLowerCase() : '';
        final alreadyInitialised =
            e is StateError && message.contains('flutter_rust_bridge');
        if (!alreadyInitialised) {
          if (kDebugMode) {
            debugPrint('[TrustedTime] NTS disabled — RustLib.init failed: $e');
          }
          config = config.copyWith(ntsServers: const []);
        }
      }
    }

    await TrustedTimeImpl.init(config);
  }

  /// Synchronously returns the current trusted UTC time.
  ///
  /// This operation is optimized for performance, typically completing in **<50µs**.
  /// It performs a simple arithmetic projection based on the active hardware anchor
  /// and does not involve any platform channel or I/O overhead.
  ///
  /// Throws [TrustedTimeNotReadyException] if called before the engine has established
  /// its initial trust anchor.
  static DateTime now() {
    if (_override != null) return _override!.now;
    return TrustedTimeImpl.instance.now();
  }

  /// Returns the current trusted Unix timestamp (milliseconds since epoch).
  ///
  /// High-performance variant of [now] that avoids the overhead of [DateTime]
  /// object instantiation. Recommended for high-frequency audit logging or
  /// real-time security signatures.
  static int nowUnixMs() {
    if (_override != null) return _override!.nowUnixMs;
    return TrustedTimeImpl.instance.nowUnixMs();
  }

  /// Returns the current trusted time in ISO-8601 format.
  ///
  /// Optimized for transmission over network protocols or persistent logging.
  /// Example: `2024-05-02T12:00:00.000Z`
  static String nowIso() {
    if (_override != null) return _override!.nowIso;
    return TrustedTimeImpl.instance.nowIso();
  }

  /// Returns `true` if the engine has successfully established a consensus-based
  /// trust anchor.
  ///
  /// When this is `false`, [now] will throw. This state occurs during initial
  /// synchronization or after a critical integrity failure (e.g. a device reboot).
  static bool get isTrusted {
    if (_override != null) return _override!.isTrusted;
    return TrustedTimeImpl.instance.isTrusted;
  }

  /// Returns the qualitative confidence grade of the current trust anchor.
  ///
  /// A [ConfidenceLevel.high] grade indicates a consensus reached with high
  /// source diversity and depth, whereas [ConfidenceLevel.low] may indicate
  /// a valid but geographically or provider-limited consensus.
  static ConfidenceLevel get confidence {
    if (_override != null) return ConfidenceLevel.high;
    return TrustedTimeImpl.instance.anchor?.confidence ?? ConfidenceLevel.low;
  }

  /// Returns a probabilistic "freshness" score (0.0 to 1.0).
  ///
  /// This score models the temporal uncertainty of the anchor. It decays
  /// exponentially as the anchor ages. High-value transactions should check
  /// this score and potentially trigger a [forceResync] if it falls below
  /// an application-defined threshold (e.g. 0.5).
  static double get confidenceScore {
    if (_override != null) return 1.0;
    return TrustedTimeImpl.instance.anchor?.confidenceScore ?? 0.0;
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
  /// transformation: the underlying call is documented as three
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
  /// - `androidPlatformInitSucceeded`: `true` iff the Android JNI
  ///   bootstrap reported success at least once. `false` on every
  ///   non-Android platform (no JNI bootstrap exists). A `false`
  ///   value on Android implies subsequent handshakes will run
  ///   against the `webpki-roots` static bundle regardless of
  ///   [TrustedTimeConfig.ntsTrustMode].
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
  /// Throws `StateError` if `package:nts`'s `RustLib.init()` has
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

  /// Advanced retrieval that enforces specific security and integrity constraints.
  ///
  /// Use this when your application logic requires higher guarantees than
  /// standard consensus.
  ///
  /// * Set [requireSecure] to `true` to force a fail-fast error if NTS
  ///   cryptographic authentication is unavailable.
  /// * Set [minConfidence] to enforce a minimum qualitative trust level.
  ///
  /// Throws [TrustedTimeSecurityException] if requirements are not met.
  static DateTime getTime({
    bool requireSecure = false,
    ConfidenceLevel minConfidence = ConfidenceLevel.low,
  }) {
    if (requireSecure && !isSecure) {
      throw const TrustedTimeSecurityException(
        'NTS-authenticated time is required but unavailable in the current session.',
      );
    }

    final currentConfidence = confidence;
    if (currentConfidence.index < minConfidence.index) {
      throw TrustedTimeSecurityException(
        'Confidence level ${currentConfidence.name} is below required ${minConfidence.name}.',
      );
    }

    return now();
  }

  /// Returns `true` if the system is configured to support Network Time
  /// Security (NTS).
  static bool get supportsSecureTime {
    if (_override != null) return false;
    return TrustedTimeImpl.instance.supportsSecureTime;
  }

  /// Emits events when the engine detects potential temporal tampering.
  ///
  /// The engine proactively monitors for Monotonic-to-Wall drift. If a
  /// system clock jump or device reboot is detected, this stream will
  /// emit an event, and the engine will automatically enter a recovery
  /// cycle (cache invalidation + immediate resync).
  static Stream<IntegrityEvent> get onIntegrityLost {
    if (_override != null) return _override!.onIntegrityLost;
    return TrustedTimeImpl.instance.onIntegrityLost;
  }

  /// Indicates if the current trust anchor is backed by cryptographic
  /// authentication (NTS/RFC 8915).
  static bool get isSecure {
    if (_override != null) return false;
    return TrustedTimeImpl.instance.isSecure;
  }

  /// Exposes the specific cryptographic authentication level achieved during sync.
  static NtsAuthLevel get authLevel {
    if (_override != null) return NtsAuthLevel.none;
    return TrustedTimeImpl.instance.authLevel;
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

  /// Best-effort time estimation for offline or unanchored scenarios.
  ///
  /// Returns a [TrustedTimeEstimate] extrapolated from the last known state.
  /// **WARNING**: This estimate is susceptible to wall-clock manipulation.
  /// Use only for non-critical UI hints when [isTrusted] is false.
  static TrustedTimeEstimate? nowEstimated() {
    if (_override != null) return _override!.nowEstimated();
    return TrustedTimeImpl.instance.nowEstimated();
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
  /// BGTaskScheduler on iOS/macOS) to perform periodic maintenance
  /// while the app is backgrounded.
  static Future<void> enableBackgroundSync({
    Duration interval = const Duration(hours: 24),
  }) {
    if (_override != null) return Future.value();
    return TrustedTimeImpl.instance.enableBackgroundSync(interval);
  }

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
  /// Sync cycles triggered by [forceResync], integrity events, or
  /// background platform schedulers still run while this is `false`.
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
  /// Pause only suppresses the *automatic refresh* timer. The
  /// following continue to operate while paused:
  ///  * the retry timer scheduled by a failed sync (recovery from a
  ///    failed bootstrap or a failed refresh still proceeds);
  ///  * sync cycles triggered by [forceResync];
  ///  * sync cycles triggered by integrity events (clock jumps,
  ///    detected reboots);
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
  /// Throws [UnknownTimezoneException] if the [timezoneIdentifier]
  /// is not found in the database.
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
