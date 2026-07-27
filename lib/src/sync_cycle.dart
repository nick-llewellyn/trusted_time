import 'anchor_store.dart';
import 'exceptions.dart';
import 'models.dart';
import 'sync_engine.dart';

/// Whether [error] is a transient sync failure that a retry can plausibly
/// recover from.
///
/// A [TrustedTimeSyncException] flagged [TrustedTimeSyncException.transient]
/// covers quorum-not-reached, sync-timeout, and all-sources-in-cooldown
/// conditions — weather that can clear between attempts. Anything else —
/// a [TrustedTimeSyncException] the engine flagged non-transient (empty
/// source configuration, consensus with no participants), an
/// [ArgumentError] from an invalid [TrustedTimeConfig], or a storage
/// failure while banking the anchor — would fail identically on every
/// attempt and must not be retried.
///
/// Shared by the foreground retry scheduler (`TrustedTimeImpl`) and the
/// background in-run retry loop (`runBackgroundSync`) so both paths apply
/// the same transient/non-transient verdict.
bool isTransientSyncError(Object error) =>
    error is TrustedTimeSyncException && error.transient;

/// Runs one query-and-bank sync cycle: [SyncEngine.sync] followed by a
/// [TrustedTimeConfig.persistState]-gated [AnchorStorage.save].
///
/// This is the canonical "fetch trusted time and persist the anchor" unit
/// shared by the foreground engine (`TrustedTimeImpl`) and the headless
/// background worker (`runBackgroundSync`). Any change to how an anchor is
/// produced or banked (e.g. stamping additional fields onto the persisted
/// payload) belongs here so the two paths cannot drift.
///
/// Errors from [SyncEngine.sync] and [AnchorStorage.save] propagate
/// unchanged; callers classify them with [isTransientSyncError]. A save
/// failure therefore surfaces *before* the anchor is applied to any
/// in-memory state, keeping "banked" an all-or-nothing outcome.
///
/// After a successfully banked anchor, the engine's per-source quality
/// stats are also persisted (same [TrustedTimeConfig.persistState] gate)
/// so the next process start ranks servers on accumulated RTT/success
/// history instead of starting blind. That write is best-effort: stats
/// are a ranking optimization, so a storage failure there costs one
/// snapshot, never a successfully banked cycle.
Future<TrustAnchor> performSyncCycle({
  required SyncEngine engine,
  required AnchorStorage store,
  required TrustedTimeConfig config,
}) async {
  final anchor = await engine.sync();
  if (config.persistState) {
    await store.save(anchor);
    try {
      await store.saveSourceStats(engine.sourceStatsSnapshot());
    } catch (_) {
      // Best-effort: the anchor is already banked; losing one stats
      // snapshot only delays ranking refinement by a cycle.
    }
  }
  return anchor;
}
