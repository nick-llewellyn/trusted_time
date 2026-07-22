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
import 'src/exceptions.dart';
import 'src/integrity_event.dart';
import 'src/models.dart';
import 'src/nts_bootstrap.dart';
import 'src/trusted_time_estimate.dart';
import 'src/trusted_time_impl.dart';
import 'src/trusted_time_mock.dart';
import 'src/infra/sync_observer.dart';
import 'src/infra/trusted_time_log.dart';
import 'src/sources/nts_auth_level.dart';

export 'src/background_sync.dart'
    show
        BackgroundSyncFailure,
        BackgroundSyncStopInfo,
        BackgroundSyncSuccess,
        TrustedTimeBackgroundResult;
export 'src/exceptions.dart';
export 'src/integrity_event.dart';
export 'src/models.dart'
    show
        TrustedTimeConfig,
        TrustAnchor,
        ConfidenceLevel,
        SyncMetrics,
        CadenceMode;
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
export 'src/trusted_time_estimate.dart';
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

  /// Advanced retrieval that enforces the Secure Time Contract's security
  /// and integrity constraints.
  ///
  /// Use this when your application logic requires higher guarantees than
  /// standard consensus.
  ///
  /// * Set [requireSecure] to `true` to fail closed unless the active anchor
  ///   is [NtsAuthLevel.verified] — established from a Tier 1 truth box of NTS
  ///   samples authenticated against a library-controlled trust store
  ///   (bundled webpki-roots or custom roots). Anchors established under
  ///   platform-mediated trust, or degraded to lower-tier (NTP/HTTPS)
  ///   consensus, are [NtsAuthLevel.none] and throw.
  /// * Set [minConfidence] to enforce a minimum qualitative trust level.
  ///
  /// [requireSecure] gates *authentication*, not freshness or accuracy:
  ///
  /// * A verified anchor satisfies the gate regardless of age — including
  ///   one warm-restored from the persisted cache within the same boot
  ///   session. Staleness is governed separately, by [confidenceScore],
  ///   [validateFreshness], and the refresh scheduler; combine the gate
  ///   with [minConfidence] or a [confidenceScore] check when age matters.
  /// * HTTPS-Date sources never satisfy the gate: authenticated transport
  ///   is not authenticated time (no application-layer signature over the
  ///   timestamp), so an anchor built from HTTPS/NTP consensus is
  ///   [NtsAuthLevel.none] even though best-effort calls keep working.
  /// * If every NTS server becomes unreachable after a verified anchor was
  ///   established, the anchor's verified label persists across *failed*
  ///   resync cycles; a *successful* degraded cycle (unauthenticated
  ///   survivors reach quorum) replaces the anchor and the gate fails
  ///   closed from then on. Verified status is never carried over onto a
  ///   degraded consensus.
  ///
  /// Throws [TrustedTimeSecurityException] when the authentication or
  /// confidence requirement is not met, and [TrustedTimeNotReadyException]
  /// when no usable anchor exists at all (e.g. a cold start with no cache
  /// and no network, or after trust was invalidated pending resync). The
  /// authentication gate is checked first, so a cold start with
  /// `requireSecure: true` surfaces the actionable security error rather
  /// than NotReady. See the Secure Time Contract
  /// (`doc/specification/secure-time-contract.md`) for the full
  /// `requireSecure` semantics and trust-tiering rules.
  static DateTime getTime({
    bool requireSecure = false,
    ConfidenceLevel minConfidence = ConfidenceLevel.low,
  }) {
    if (requireSecure && !isSecure) {
      throw const TrustedTimeSecurityException(
        'Time is required to be cryptographically authenticated against '
        'a library-controlled trust store (bundled webpki-roots or '
        'custom roots), but the active anchor is not verified. This '
        'happens when NTS was unavailable and the engine fell back to '
        'lower-tier (NTP/HTTPS) consensus, or when NTS was validated '
        'under platform-mediated trust rather than the library-controlled '
        'store. To satisfy requireSecure: true, configure reachable NTS '
        'servers (so a verified anchor can be established) and keep '
        'usePlatformTrust: false (the default, so NTS is validated against '
        'the library-controlled store). Otherwise reduce the requirement '
        'with requireSecure: false.',
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

  /// Whether the projection behind [now] rides a sleep-aware monotonic
  /// timeline.
  ///
  /// `true` when elapsed time since the last trust anchor is measured on
  /// the `package:nts` monotonic clock (`CLOCK_BOOTTIME` /
  /// `mach_continuous_time` / `QueryInterruptTimePrecise`), which keeps
  /// counting through device suspend. `false` when the engine is on the
  /// suspend-frozen `Stopwatch` fallback — HTTPS/NTP-only configs, web,
  /// or a failed nts bridge bootstrap — where a device sleep between
  /// syncs leaves [now] behind by the sleep duration until the next
  /// sync or integrity reconciliation.
  ///
  /// Consumers for whom the frozen fallback is unacceptable should set
  /// [TrustedTimeConfig.requireSleepAwareProjection] instead of polling
  /// this getter; the config gate fails closed at [initialize] and
  /// [now]. Under a [TrustedTimeMock] override this returns `true`
  /// (mock time is script-driven and does not drift during suspend).
  static bool get isProjectionSleepAware {
    if (_override != null) return true;
    return TrustedTimeImpl.instance.isProjectionSleepAware;
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

  /// Whether the active trust anchor is [NtsAuthLevel.verified] under the
  /// Secure Time Contract — backed by a Tier 1 NTS truth box authenticated
  /// against a library-controlled trust store (RFC 8915).
  ///
  /// Equivalent to `authLevel == NtsAuthLevel.verified`. Returns `false` for
  /// platform-mediated NTS and for lower-tier (NTP/HTTPS) or degraded
  /// consensus. This is the boundary [getTime] enforces under
  /// `requireSecure: true`.
  static bool get isSecure {
    if (_override != null) return false;
    return TrustedTimeImpl.instance.isSecure;
  }

  /// The cryptographic authentication level of the active trust anchor.
  ///
  /// Binary under the Secure Time Contract: [NtsAuthLevel.verified] only when
  /// the anchor was established from a Tier 1 NTS truth box (library-controlled
  /// trust store), otherwise [NtsAuthLevel.none]. Mirrors [isSecure]
  /// (`verified` ⟺ `isSecure == true`).
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

  /// Confirms the active trust anchor is still fresh with a short burst
  /// of lightweight, authenticated NTS queries — the validate tier of
  /// the tiered sync cadence (ADR 0006).
  ///
  /// This is far cheaper than [forceResync]: it bursts a few NTS queries
  /// against a single source (typically ~50–200 ms in total), keeps the
  /// lowest round-trip sample, and compares that against the existing
  /// anchor instead of tearing the anchor down and rebuilding consensus
  /// from every source. The wire-level burst happens inside the source
  /// itself (up to [TrustedTimeConfig.ntsBurstCount] queries per
  /// `getTime()` call); the probe makes exactly one such call. Use it
  /// on a frequent cadence (or when the app returns to the foreground)
  /// to catch drift between the infrequent full establish
  /// ([forceResync]) cycles.
  ///
  /// Returns:
  ///  * `true` — the probe agrees with the anchor within
  ///    [TrustedTimeConfig.maxAllowedUncertaintyMs];
  ///  * `false` — the probe ran but the anchor disagrees; consider
  ///    calling [forceResync]. The anchor is *not* invalidated by a
  ///    `false` result on its own.
  ///
  /// Throws [TrustedTimeFreshnessProbeException] when the probe cannot
  /// run at all — no anchor established yet, no NTS source configured
  /// (the validate tier requires NTS), all NTS sources in cooldown, or
  /// the probe's `getTime()` call failed (threw or timed out). This
  /// "freshness unknown" outcome is deliberately distinct from the
  /// `false` "anchor drifted" observation.
  ///
  /// Under a test override this returns the mock's [TrustedTimeMock.isTrusted]
  /// state without touching the engine, so a mock placed in an untrusted
  /// state (e.g. via [TrustedTimeMock.simulateTampering]) reports a failed
  /// freshness check consistently with [isTrusted].
  static Future<bool> validateFreshness() {
    if (_override != null) return Future.value(_override!.isTrusted);
    return TrustedTimeImpl.instance.validateFreshness();
  }

  /// Schedules OS-level background tasks to keep the trust anchor fresh.
  ///
  /// Leverages platform-native schedulers (WorkManager on Android,
  /// BGTaskScheduler on iOS) to perform periodic maintenance while the
  /// app is backgrounded. On desktop (Linux/macOS/Windows), falls back
  /// to a Dart [Timer.periodic] inside the running isolate. On web,
  /// this is a no-op (browsers suspend background tabs).
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
  /// scheduler — web and desktop (Linux/macOS/Windows). The platform check
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
    // iOS; on web and desktop the persisted handle would never be read,
    // so spending dev-time validation on the callback shape (closure vs
    // top-level) only adds friction to shared startup code.
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
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
      // implementation (web, desktop) and in unit tests that have not
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
      final nowMs = override.nowUnixMs;
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
      // Channel is absent on desktop/web and in unit tests that have not
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
  /// Returns `null` when no answer is available: on desktop and web (no
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
      // Channel absent (desktop/web, unmocked unit tests) or the platform
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
