import 'package:flutter/foundation.dart';
import 'anchor_store.dart';
import 'exceptions.dart';
import 'models.dart';
import 'monotonic_clock.dart';
import 'nts_bootstrap.dart';
import 'sync_cycle.dart';
import 'sync_engine.dart';

/// Default delay schedule between in-run retry attempts on a transient
/// sync failure ([TrustedTimeSyncException]).
///
/// Sized for the Android doze maintenance-window failure mode: the OS
/// wakes the device, reports the network as CONNECTED and VALIDATED, and
/// fires the worker — but the just-woken Wi-Fi radio can serve degraded,
/// asymmetric latency for its first seconds, so the first quorum attempt
/// fails even though the very same window would succeed moments later.
/// Two retries at 10 s and 20 s let the radio settle within the *same*
/// worker execution (~35 s worst-case wait plus three bounded sync
/// attempts, well inside the Android worker's 9-minute budget) instead of
/// surrendering the whole maintenance window to the OS scheduler's
/// backoff, which under doze can defer the next opportunity by hours.
const _defaultRetryDelays = [Duration(seconds: 10), Duration(seconds: 20)];

/// Outcome of a single headless background-sync invocation.
///
/// Returned by [runBackgroundSync] and inspected by tests; in production the
/// caller is the OS scheduler, which only consumes the boolean
/// success/failure projection via the platform method channel.
sealed class TrustedTimeBackgroundResult {
  const TrustedTimeBackgroundResult();

  /// Whether the OS scheduler should treat this run as a success
  /// (`Result.success()` on Android, `setTaskCompleted(success: true)` on
  /// iOS).
  bool get isSuccess;
}

/// Sync completed and a fresh [TrustAnchor] was produced. The anchor is
/// written to [AnchorStorage] iff `config.persistState` is `true` (the
/// default); when `false` the success is still reported but no storage
/// write occurs.
final class BackgroundSyncSuccess extends TrustedTimeBackgroundResult {
  /// Creates a success result carrying the fresh [anchor] and run [elapsed].
  const BackgroundSyncSuccess({required this.anchor, required this.elapsed});

  /// The freshly fetched anchor. When `config.persistState` is `true` (the
  /// default), this value has been written to [AnchorStorage] and
  /// subsequent foreground initializations will warm-restore from it.
  final TrustAnchor anchor;

  /// Wall-clock duration of the headless run, useful for diagnostics.
  final Duration elapsed;

  @override
  bool get isSuccess => true;

  @override
  String toString() =>
      'BackgroundSyncSuccess(anchor: $anchor, elapsed: $elapsed)';
}

/// Diagnostic snapshot of the OS scheduler's view of the background-sync
/// work, as reported by `TrustedTime.getBackgroundStopReason`.
///
/// Android-only in practice: the values map 1:1 onto WorkManager's
/// `WorkInfo` — [state] is `WorkInfo.State.name` and [stopReason] is
/// `WorkInfo.getStopReason()`, the reason the OS stopped the *previous*
/// run attempt of the periodic work. The platform populates real stop
/// reasons on API 31+; earlier releases always report
/// `STOP_REASON_NOT_STOPPED`.
final class BackgroundSyncStopInfo {
  /// Creates a snapshot carrying the raw platform values.
  const BackgroundSyncStopInfo({required this.state, required this.stopReason});

  /// The work's current `WorkInfo.State` name (e.g. `ENQUEUED`, `RUNNING`).
  final String state;

  /// Raw `WorkInfo.getStopReason()` value for the previous run attempt.
  ///
  /// Matches Android's `JobParameters.STOP_REASON_*` constants, plus
  /// WorkManager's sentinels `-256` (not stopped) and `-512` (unknown).
  final int stopReason;

  /// Human-readable name for [stopReason], falling back to the raw value
  /// for constants introduced after this mapping was written.
  String get stopReasonName => switch (stopReason) {
    -256 => 'NOT_STOPPED',
    -512 => 'UNKNOWN',
    0 => 'UNDEFINED',
    1 => 'CANCELLED_BY_APP',
    2 => 'PREEMPT',
    3 => 'TIMEOUT',
    4 => 'DEVICE_STATE',
    5 => 'CONSTRAINT_BATTERY_NOT_LOW',
    6 => 'CONSTRAINT_CHARGING',
    7 => 'CONSTRAINT_CONNECTIVITY',
    8 => 'CONSTRAINT_DEVICE_IDLE',
    9 => 'CONSTRAINT_STORAGE_NOT_LOW',
    10 => 'QUOTA',
    11 => 'BACKGROUND_RESTRICTION',
    12 => 'APP_STANDBY',
    13 => 'USER',
    14 => 'SYSTEM_PROCESSING',
    15 => 'ESTIMATED_APP_LAUNCH_TIME_CHANGED',
    16 => 'TIMEOUT_ABANDONED',
    _ => 'STOP_REASON_$stopReason',
  };

  @override
  String toString() =>
      'BackgroundSyncStopInfo(state: $state, '
      'stopReason: $stopReasonName($stopReason))';
}

/// Sync failed (network, quorum, timeout, or configuration error).
///
/// [retryable] tells the OS scheduler whether re-running this work can
/// plausibly succeed. On Android the worker maps it to
/// `Result.retry()` (re-attempt this interval with backoff) versus
/// `Result.failure()` (give up on this interval; the next periodic fire
/// still runs normally). iOS has no equivalent knob — `setTaskCompleted`
/// only takes a boolean — so the flag is diagnostic-only there.
final class BackgroundSyncFailure extends TrustedTimeBackgroundResult {
  /// Creates a failure result carrying the [reason] and run [elapsed].
  const BackgroundSyncFailure({
    required this.reason,
    required this.elapsed,
    this.retryable = true,
  });

  /// Human-readable failure reason for diagnostics. Forwarded as a string
  /// because it must cross the method-channel boundary.
  final String reason;

  /// Wall-clock duration of the failed run.
  final Duration elapsed;

  /// Whether the OS scheduler should re-attempt this run.
  ///
  /// `true` for transient failures ([TrustedTimeSyncException]: quorum
  /// not reached, sync timeout) where network conditions may recover
  /// before the scheduler's backoff elapses. `false` for non-transient
  /// errors (e.g. an invalid [TrustedTimeConfig]) that would fail
  /// identically on every attempt — the same classification the in-run
  /// retry loop uses, extended across the platform boundary.
  final bool retryable;

  @override
  bool get isSuccess => false;

  @override
  String toString() =>
      'BackgroundSyncFailure(reason: $reason, elapsed: $elapsed, '
      'retryable: $retryable)';
}

/// Executes a network sync against the configured time sources and, by
/// default, persists the resulting anchor — retrying in-run on transient
/// failures.
///
/// This is the unit-of-work invoked by the host-app callback registered via
/// `TrustedTime.registerBackgroundCallback`. It deliberately bypasses
/// `TrustedTimeImpl.init`: there is no foreground engine instance to
/// participate in, no refresh timer to start, and no integrity-monitor to
/// attach. Instead it constructs a [SyncEngine] directly, runs
/// [SyncEngine.sync], optionally writes the result to [AnchorStorage], and
/// returns.
///
/// **In-run retry**: a [TrustedTimeSyncException] (quorum failure, sync
/// timeout — transient network conditions) is retried after each delay in
/// [retryDelays] before the run is reported as failed, because the OS
/// scheduler's own retry can be deferred for hours under doze while the
/// worker still has minutes of budget left. Each attempt uses a **fresh**
/// [SyncEngine]: a failed attempt arms per-source exponential cooldowns
/// inside the engine, which would otherwise make an immediate retry throw
/// "all sources in cooldown" without touching the network. Any other error
/// (e.g. an [ArgumentError] from an invalid [TrustedTimeConfig]) fails
/// immediately — it would fail identically on every attempt.
///
/// It does, however, run the shared NTS bootstrap ([ensureNtsRuntime])
/// before building the engine. The OS scheduler runs this callback in a
/// fresh Dart isolate that does not inherit the foreground isolate's
/// flutter_rust_bridge initialisation, so the background path must
/// initialise the NTS FFI itself — otherwise every NTS source throws
/// instantly and an NTS-only config can never reach quorum
/// (trusted_time-y81).
///
/// Because tier classification and truth-box admission (Secure Time
/// Contract / ADR 0007) live inside [SyncEngine.sync], a background cycle
/// produces a [TrustAnchor] with exactly the same `authLevel` and
/// `confidence` semantics as a foreground cycle run against the same
/// [TrustedTimeConfig]. Tier-degradation integrity events raised during a
/// headless run are not observable (there is no foreground monitor
/// attached); the degraded state is still fully reflected in the persisted
/// anchor's fields, which the next foreground warm-restore reads.
///
/// Persistence is gated on [TrustedTimeConfig.persistState] (default
/// `true`). When `false`, a successful run still returns a
/// [BackgroundSyncSuccess] but no storage write occurs — useful for tests
/// and for hosts that manage anchor persistence outside this package.
///
/// Even when persisted, the in-memory [SyncClock] is not updated here,
/// because the next foreground initialization will do that itself from the
/// persisted value via the standard warm-restore path.
///
/// All optional parameters exist for testability — production callers should
/// pass `config` only; the [store], [clock], and [ntsInit] defaults wire to
/// the real secure-storage, platform-channel, and NTS-runtime
/// implementations. [ntsInit] overrides the NTS bootstrap's initialiser so a
/// unit test can prove the bootstrap runs without touching the real FFI.
/// [retryDelays] overrides the in-run retry schedule (`attempts =
/// retryDelays.length + 1`) so tests can exercise the retry loop without
/// real sleeps, or disable it entirely with an empty list. Unlike the other
/// seams it is not `@visibleForTesting` here because the public wrapper
/// (`TrustedTime.runBackgroundSync`, which carries its own test-only
/// annotation on the parameter) forwards it in production code.
Future<TrustedTimeBackgroundResult> runBackgroundSync({
  TrustedTimeConfig config = const TrustedTimeConfig(),
  @visibleForTesting AnchorStorage? store,
  @visibleForTesting MonotonicClock? clock,
  @visibleForTesting NtsInitFn? ntsInit,
  List<Duration>? retryDelays,
}) async {
  final stopwatch = Stopwatch()..start();
  final anchorStore = store ?? AnchorStore();
  final monotonicClock = clock ?? PlatformMonotonicClock();
  final delays = retryDelays ?? _defaultRetryDelays;
  // Bootstrap the NTS Rust FFI for this (headless) isolate before the
  // engine builds any NtsSource. The OS scheduler runs this callback in a
  // fresh Dart isolate that does not inherit the foreground isolate's
  // flutter_rust_bridge initialisation, so without this every NTS source
  // would throw instantly and an NTS-only config could never reach quorum
  // (trusted_time-y81). Shared with TrustedTime.initialize via
  // ensureNtsRuntime, which also degrades to an NTS-disabled config if the
  // bootstrap genuinely fails. Runs once, outside the retry loop — the
  // bootstrap outcome cannot change between attempts.
  final effectiveConfig = ntsInit == null
      ? await ensureNtsRuntime(config)
      : await ensureNtsRuntime(config, init: ntsInit);

  final maxAttempts = delays.length + 1;
  Object? lastError;
  var lastErrorRetryable = true;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    // Fresh engine per attempt: a failed cycle arms per-source exponential
    // cooldowns (>= 2 min) inside the engine, so reusing it would make the
    // next attempt throw "all sources in cooldown" without any network I/O.
    final engine = SyncEngine(config: effectiveConfig, clock: monotonicClock);
    try {
      // Shared query-and-bank unit (sync + persistState-gated save) —
      // the same cycle the foreground engine runs, so a headless anchor
      // is produced and persisted identically to a foreground one.
      final anchor = await performSyncCycle(
        engine: engine,
        store: anchorStore,
        config: effectiveConfig,
      );
      stopwatch.stop();
      return BackgroundSyncSuccess(anchor: anchor, elapsed: stopwatch.elapsed);
    } catch (e) {
      lastError = e;
      // Shared transient/non-transient verdict (isTransientSyncError,
      // also used by the foreground retry scheduler). Transient failures
      // (quorum, timeout) consume the retry schedule; anything else
      // (invalid config, unexpected errors) would fail identically on
      // every attempt, so report immediately and flag the failure as
      // non-retryable so the OS scheduler gives up on this interval too
      // (Android maps this to Result.failure()).
      if (isTransientSyncError(e)) {
        if (kDebugMode) {
          debugPrint(
            '[TrustedTime] Background sync attempt $attempt/$maxAttempts '
            'failed: $e',
          );
        }
        if (attempt < maxAttempts) {
          await Future<void>.delayed(delays[attempt - 1]);
        }
      } else {
        lastErrorRetryable = false;
        if (kDebugMode) {
          debugPrint('[TrustedTime] Background sync failed: $e');
        }
        break;
      }
    } finally {
      // dispose() iterates the engine's lazily-built source list. If sync()
      // failed because that `late final` initializer threw (e.g. an invalid
      // TrustedTimeConfig raising ArgumentError from effectiveTrustMode),
      // reading it here re-runs the initializer and rethrows — which would
      // override the BackgroundSyncFailure return below. Swallow it: the
      // original error is already captured in [lastError], and no sources
      // were built, so there is nothing to release.
      try {
        engine.dispose();
      } catch (_) {}
    }
  }
  stopwatch.stop();
  return BackgroundSyncFailure(
    reason: lastError.toString(),
    elapsed: stopwatch.elapsed,
    retryable: lastErrorRetryable,
  );
}
