import 'package:flutter/foundation.dart';
import 'anchor_store.dart';
import 'models.dart';
import 'monotonic_clock.dart';
import 'sync_engine.dart';

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

/// Sync failed (network, quorum, or timeout). The OS scheduler should
/// reschedule a retry per its own backoff policy.
final class BackgroundSyncFailure extends TrustedTimeBackgroundResult {
  /// Creates a failure result carrying the [reason] and run [elapsed].
  const BackgroundSyncFailure({required this.reason, required this.elapsed});

  /// Human-readable failure reason for diagnostics. Forwarded as a string
  /// because it must cross the method-channel boundary.
  final String reason;

  /// Wall-clock duration of the failed run.
  final Duration elapsed;

  @override
  bool get isSuccess => false;

  @override
  String toString() =>
      'BackgroundSyncFailure(reason: $reason, elapsed: $elapsed)';
}

/// Executes a single network sync against the configured time sources and,
/// by default, persists the resulting anchor.
///
/// This is the unit-of-work invoked by the host-app callback registered via
/// `TrustedTime.registerBackgroundCallback`. It deliberately bypasses
/// `TrustedTimeImpl.init`: there is no foreground engine instance to
/// participate in, no refresh timer to start, and no integrity-monitor to
/// attach. Instead it constructs a [SyncEngine] directly, runs one
/// [SyncEngine.sync], optionally writes the result to [AnchorStorage], and
/// returns.
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
/// pass `config` only; the [store] and [clock] defaults wire to the real
/// secure-storage and platform-channel implementations.
Future<TrustedTimeBackgroundResult> runBackgroundSync({
  TrustedTimeConfig config = const TrustedTimeConfig(),
  @visibleForTesting AnchorStorage? store,
  @visibleForTesting MonotonicClock? clock,
}) async {
  final stopwatch = Stopwatch()..start();
  final anchorStore = store ?? AnchorStore();
  final monotonicClock = clock ?? PlatformMonotonicClock();
  final engine = SyncEngine(config: config, clock: monotonicClock);

  try {
    final anchor = await engine.sync();
    if (config.persistState) {
      await anchorStore.save(anchor);
    }
    stopwatch.stop();
    return BackgroundSyncSuccess(anchor: anchor, elapsed: stopwatch.elapsed);
  } catch (e) {
    stopwatch.stop();
    if (kDebugMode) {
      debugPrint('[TrustedTime] Background sync failed: $e');
    }
    return BackgroundSyncFailure(
      reason: e.toString(),
      elapsed: stopwatch.elapsed,
    );
  } finally {
    // dispose() iterates the engine's lazily-built source list. If sync()
    // failed because that `late final` initializer threw (e.g. an invalid
    // TrustedTimeConfig raising ArgumentError from effectiveTrustMode),
    // reading it here re-runs the initializer and rethrows — which would
    // override the BackgroundSyncFailure return above. Swallow it: the
    // original error is already captured in the returned failure result,
    // and no sources were built, so there is nothing to release.
    try {
      engine.dispose();
    } catch (_) {}
  }
}
