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
/// After a successfully banked anchor, the engine's exploration state is
/// also persisted (same [TrustedTimeConfig.persistState] gate): the
/// per-source quality stats, so the next process start ranks servers on
/// accumulated RTT/success history instead of starting blind; the
/// anycast RTT baseline, so a vantage change that happens while the
/// process is dead is still seen; and the remaining explorer front-load,
/// so it spans launches rather than restarting every process start.
///
/// All three writes are best-effort and each is independent of the
/// others: they are exploration and detection state, so a storage
/// failure costs one snapshot, never a successfully banked cycle. The
/// two counters are written only when they actually moved — an
/// unobservable cycle and a spent front-load both cost no write.
Future<TrustAnchor> performSyncCycle({
  required SyncEngine engine,
  required AnchorStorage store,
  required TrustedTimeConfig config,
}) async {
  final baselineBefore = engine.vantageBaseline;
  final boostBefore = engine.explorerBoostRemaining;
  final anchor = await engine.sync();
  if (config.persistState) {
    await store.save(anchor);
    try {
      await store.saveSourceStats(engine.sourceStatsSnapshot());
    } catch (_) {
      // Best-effort: the anchor is already banked; losing one stats
      // snapshot only delays ranking refinement by a cycle.
    }
    // Paired with the stats write above rather than left to the caller,
    // because a vantage change writes both: the epoch advancing is what
    // marked the stats stale. Persisting the marks without the epoch
    // that produced them would leave the next run to re-detect the same
    // shift against the old baseline and re-mark everything, on every
    // run, for as long as the device stayed put.
    if (engine.vantageBaseline != baselineBefore) {
      try {
        await store.saveVantageBaseline(engine.vantageBaseline);
      } catch (_) {}
    }
    // The other half of that recovery: a detected change arms the
    // front-load, so the accelerated sweep it queued must survive the
    // process too. Also carries the ordinary per-cycle decay.
    if (engine.explorerBoostRemaining != boostBefore) {
      try {
        await store.saveExplorerBoostRemaining(engine.explorerBoostRemaining);
      } catch (_) {}
    }
  }
  return anchor;
}
