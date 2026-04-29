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

/// Sync completed and a fresh [TrustAnchor] was persisted to [AnchorStorage].
final class BackgroundSyncSuccess extends TrustedTimeBackgroundResult {
  const BackgroundSyncSuccess({required this.anchor, required this.elapsed});

  /// The newly persisted anchor. Subsequent foreground calls to
  /// [TrustedTime.initialize] will warm-restore from this value.
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
  const BackgroundSyncFailure({required this.reason, required this.elapsed});

  /// Human-readable failure reason for diagnostics. Forwarded as a string
  /// because it must cross the FFI/method-channel boundary.
  final String reason;

  /// Wall-clock duration of the failed run.
  final Duration elapsed;

  @override
  bool get isSuccess => false;

  @override
  String toString() =>
      'BackgroundSyncFailure(reason: $reason, elapsed: $elapsed)';
}

/// Executes a single network sync against the configured time sources and
/// persists the resulting anchor.
///
/// This is the unit-of-work invoked by the host-app callback registered via
/// [TrustedTime.registerBackgroundCallback]. It deliberately bypasses
/// [TrustedTimeImpl.init]: there is no foreground engine instance to
/// participate in, no refresh timer to start, and no integrity-monitor to
/// attach. Instead it constructs a [SyncEngine] directly, runs one
/// [SyncEngine.sync], writes the result to [AnchorStorage], and returns.
///
/// The anchor is *only* persisted; the in-memory [SyncClock] is not updated,
/// because the next foreground [TrustedTime.initialize] will do that itself
/// from the persisted value via the standard warm-restore path.
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
    engine.dispose();
  }
}
