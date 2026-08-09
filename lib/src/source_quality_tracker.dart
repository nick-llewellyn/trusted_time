import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// How many recent observations are retained per source.
const int _kHistoryDepth = 10;

/// Number of sync cycles a source may go unqueried before it is force-included
/// to prevent starvation. Sources that haven't been queried within
/// [_kStarvationCycles] cycles are promoted to forced-query regardless of
/// score.
const int _kStarvationCycles = 5;

/// EWMA smoothing factor for the durable per-source stats (RTT, jitter,
/// success rate). 0.3 favours recent observations while still damping
/// single-sample network noise.
const double _kEwmaAlpha = 0.3;

/// Maximum number of per-source stat entries emitted by [snapshot], keeping
/// the persisted payload bounded regardless of how many distinct sources
/// (e.g. rotating pool hostnames) a long-lived install observes. The
/// most-recently-probed sources win.
const int _kMaxPersistedSources = 32;

/// Persisted stats older than this are discarded on [restore]: a stat last
/// refreshed a month ago says nothing about today's network vantage, and
/// seeding the ranking with it would be worse than starting neutral.
const int _kStatsStalenessMs = 30 * 24 * 60 * 60 * 1000;

/// How much of a vantage-stale source's score survives the marking.
///
/// The score is pulled toward the 0.5 neutral by this factor. Old
/// metrics are evidence about the wrong network, so the attenuation is
/// a discount on confidence, not a penalty: it shrinks the distance
/// from neutral in both directions, leaving a stale source's optimism
/// and its pessimism equally unearned.
///
/// Two consequences follow, and only the first is a guarantee. Ordering
/// among stale sources is preserved, since the map is monotonic — that
/// is the "breaks ties until fresh measurements arrive" behaviour a
/// vantage change asks for, and the reason the marking attenuates
/// rather than deletes. Ordering against unmarked sources is not
/// preserved: a stale source above neutral loses to a fresh one of
/// equal quality, while one below neutral beats it. Both follow from
/// the same discount, and neither is worth correcting — a source scored
/// from the wrong vantage is one the walk is about to re-probe anyway.
const double _kStaleScoreWeight = 0.25;

/// Durable quality statistics for one time source.
///
/// The persistable subset of [SourceQualityTracker]'s state: smoothed
/// network metrics that stay meaningful across process restarts, unlike
/// the in-memory observation history whose cycle indices are
/// process-local. Serialized as JSON via [AnchorStorage] so background
/// sync cycles can refine server selection over time instead of
/// starting blind.
@immutable
final class SourceQualityStats {
  /// Creates a stats record; see the field docs for each metric.
  const SourceQualityStats({
    required this.successRate,
    required this.lastProbedUtcMs,
    this.ewmaRttMs,
    this.ewmaJitterMs,
    this.stratum,
    this.vantageStale = false,
    this.succeededOnce = false,
  });

  /// EWMA of the measured network delay (`TimeSample.delayMs`, a whole
  /// round trip) in milliseconds, or null when the source has never
  /// reported a measured delay.
  final double? ewmaRttMs;

  /// EWMA of the in-cycle burst jitter (`TimeSample.jitterMs`) in
  /// milliseconds, or null when the source has never reported one.
  final double? ewmaJitterMs;

  /// EWMA success rate in [0, 1]. Successes pull it toward 1.0,
  /// failures decay it toward 0 — a probe timeout on a lossy link
  /// penalizes and defers a source but can never permanently drop it.
  final double successRate;

  /// Wall-clock UTC milliseconds of the last probe (success or
  /// failure). Advisory only — used for snapshot pruning and restore
  /// staleness, never for trust decisions, so system-clock skew is
  /// harmless here.
  final int lastProbedUtcMs;

  /// Last observed NTP stratum (1–15), or null when unknown.
  final int? stratum;

  /// Whether these metrics were measured from a vantage the device has
  /// since left.
  ///
  /// Persisted because the mark outlives the process that set it: a
  /// restart between the vantage change and the re-sweep must not hand
  /// back full weight to readings taken somewhere else. The epoch that
  /// triggered the marking is itself persisted, so it will not fire
  /// again to re-mark them.
  ///
  /// Omitted from [toJson] when false, which is both the common case
  /// and what an older payload without the key means.
  final bool vantageStale;

  /// Whether this source has ever answered a probe successfully.
  ///
  /// Distinct from a positive [successRate], which starts at 1.0 and
  /// only decays — a source known solely from a failed probe still
  /// reports a rate above zero, so the rate cannot answer "has this
  /// host ever worked". The NTS promotion step needs that question
  /// answered exactly: a host that has never responded must not fill a
  /// query-target slot, or the target's failure headroom is nominal.
  ///
  /// Persisted so the answer survives a restart, since promotion runs
  /// on the first cycle after one. Omitted from [toJson] when false,
  /// which is also what an older payload without the key means — a
  /// pre-upgrade install re-earns the flag on its next successful
  /// probe.
  ///
  /// Durable only for the sources [SourceQualityTracker.snapshot]
  /// keeps: it prunes to the most-recently-probed entries, so a host
  /// that falls out of that window loses the flag along with the rest
  /// of its stats and is treated as never-tried on the next start.
  /// That is the intended reading — the flag is evidence, and evidence
  /// old enough to be evicted has stopped being current — but it means
  /// the guarantee is "survives a restart while the host is still
  /// among the recently probed", not unconditionally.
  final bool succeededOnce;

  /// Serializes to a JSON-compatible map. Null fields are omitted.
  Map<String, Object?> toJson() => {
    if (ewmaRttMs != null) 'ewmaRttMs': ewmaRttMs,
    if (ewmaJitterMs != null) 'ewmaJitterMs': ewmaJitterMs,
    'successRate': successRate,
    'lastProbedUtcMs': lastProbedUtcMs,
    if (stratum != null) 'stratum': stratum,
    if (vantageStale) 'vantageStale': true,
    if (succeededOnce) 'succeededOnce': true,
  };

  /// Deserializes one stats entry, returning null when [json] is not a
  /// well-formed entry so a single malformed record degrades to "no
  /// stats for that source" instead of discarding the whole payload.
  static SourceQualityStats? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final successRate = json['successRate'];
    final lastProbedUtcMs = json['lastProbedUtcMs'];
    if (successRate is! num || lastProbedUtcMs is! int) return null;
    final ewmaRttMs = json['ewmaRttMs'];
    final ewmaJitterMs = json['ewmaJitterMs'];
    final stratum = json['stratum'];
    return SourceQualityStats(
      ewmaRttMs: ewmaRttMs is num ? ewmaRttMs.toDouble() : null,
      ewmaJitterMs: ewmaJitterMs is num ? ewmaJitterMs.toDouble() : null,
      successRate: successRate.toDouble().clamp(0.0, 1.0),
      lastProbedUtcMs: lastProbedUtcMs,
      stratum: stratum is int && stratum >= 1 && stratum <= 15 ? stratum : null,
      vantageStale: json['vantageStale'] == true,
      succeededOnce: json['succeededOnce'] == true,
    );
  }
}

/// Mutable in-tracker accumulator behind [SourceQualityStats].
class _SourceStats {
  double? ewmaRttMs;
  double? ewmaJitterMs;
  double successRate = 1.0;
  int lastProbedUtcMs = 0;

  /// Whether these metrics were measured from a vantage the device has
  /// since left. Set by [SourceQualityTracker.markVantageStale] and
  /// cleared by the next probe of this source, success or failure —
  /// either outcome is a measurement from the current vantage.
  bool vantageStale = false;

  /// Whether a probe of this source has ever succeeded. Latches on the
  /// first success and is never cleared: a host that answered once is
  /// permanently distinguishable from one that never has, which is a
  /// different question from how well it is answering now.
  bool succeededOnce = false;
}

/// Per-source observation recorded after each successful `TimeSample`.
class _SourceObservation {
  const _SourceObservation({
    required this.uncertaintyMs,
    required this.participatedInConsensus,
    required this.cycleIndex,
  });

  final int uncertaintyMs;
  final bool participatedInConsensus;
  final int cycleIndex;
}

/// Tracks the rolling quality of individual time sources and produces a
/// priority-ordered list for the next sync cycle.
///
/// **Scoring**: Each source is scored on these dimensions:
/// 1. **RTT** — EWMA of the measured network delay when available
///    (`TimeSample.delayMs`); interval uncertainty as fallback. Lower →
///    higher score. RTT is the sole proximity signal: it stays honest
///    through VPNs, travel, and CGNAT where geography lies.
/// 2. **Consensus participation** — sources that regularly contribute to
///    a winning quorum are weighted higher.
/// 3. **Success rate** — EWMA over probe outcomes. A timeout decays the
///    score (deferring the source) but never permanently drops it: one
///    lost UDP packet on a lossy link must not blacklist a good server.
/// 4. **Burst jitter** — EWMA of the in-cycle delay spread
///    (`TimeSample.jitterMs`); a wide spread flags an unstable path.
/// 5. **NTP stratum** (optional, 1–15) — lower stratum (closer to
///    reference) → higher weight.
///
/// **Durability**: the smoothed metrics (RTT, jitter, success rate,
/// stratum, last-probed) survive process death via [snapshot] /
/// [restore], persisted through `AnchorStorage`. The observation history
/// and cycle counters are process-local and deliberately not persisted —
/// their cycle indices are meaningless across restarts.
///
/// **Vantage changes**: [markVantageStale] flags every source's metrics
/// as measured from a network the device has left. Marked sources report
/// a null [lastProbedUtcMs] so the explorer walk re-sweeps them, and
/// score toward neutral so retained data still breaks ties. Each mark
/// clears on that source's next probe.
///
/// **Starvation guard**: [isStarved] flags a source that has not been
/// queried within [_kStarvationCycles] cycles. The engine pairs this with
/// the ranking to force-include such a source (even one the cooldown filter
/// would exclude), keeping its quality estimate fresh and preventing the
/// engine from permanently ignoring a source stuck in cooldown.
final class SourceQualityTracker {
  /// Creates a tracker. [wallClock] is a test seam for the advisory
  /// last-probed timestamps; production uses the system UTC clock.
  SourceQualityTracker({int Function()? wallClock})
    : _wallClock =
          wallClock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final int Function() _wallClock;
  final _history = <String, Queue<_SourceObservation>>{};
  final _lastQueriedCycle = <String, int>{};
  final _stratumHints = <String, int>{};
  final _stats = <String, _SourceStats>{};

  int _cycleIndex = 0;

  /// Records a completed sync cycle observation for a source.
  ///
  /// [sourceId] uniquely identifies the source.
  /// [uncertaintyMs] is the half-width of the returned `TimeInterval`.
  /// [participatedInConsensus] is true if the source's sample was part of
  /// the Marzullo winning set.
  /// [delayMs] is the measured round trip (`TimeSample.delayMs`), when the
  /// source measured one; it feeds the durable EWMA RTT.
  /// [jitterMs] is the in-cycle burst delay spread (`TimeSample.jitterMs`),
  /// when the burst produced one; it feeds the durable EWMA jitter.
  void record({
    required String sourceId,
    required int uncertaintyMs,
    required bool participatedInConsensus,
    int? delayMs,
    int? jitterMs,
  }) {
    final q = _history.putIfAbsent(sourceId, Queue.new);
    q.addLast(
      _SourceObservation(
        uncertaintyMs: uncertaintyMs,
        participatedInConsensus: participatedInConsensus,
        cycleIndex: _cycleIndex,
      ),
    );
    while (q.length > _kHistoryDepth) {
      q.removeFirst();
    }
    recordProbe(sourceId: sourceId, delayMs: delayMs, jitterMs: jitterMs);
  }

  /// Records a successful query's durable signals without appending a
  /// consensus observation.
  ///
  /// This is the half of [record] that every successful query shares —
  /// RTT, jitter, success rate, and the starvation cursor — and [record]
  /// delegates here after appending its observation, so the durable
  /// path is written once.
  ///
  /// Called directly for explorer probes, which run outside the
  /// blocking query set and so have no participation outcome to report.
  /// Routing those through [record] with `participatedInConsensus:
  /// false` would state one anyway, and the participation dimension of
  /// [ranked] would then decay toward zero for exactly the sources the
  /// cycle deliberately kept out of consensus. Leaving the history
  /// untouched scores them neutral on participation rather than badly.
  void recordProbe({required String sourceId, int? delayMs, int? jitterMs}) {
    _lastQueriedCycle[sourceId] = _cycleIndex;
    final stats = _stats.putIfAbsent(sourceId, _SourceStats.new);
    if (delayMs != null) {
      stats.ewmaRttMs = _ewma(stats.ewmaRttMs, delayMs.toDouble());
    }
    if (jitterMs != null) {
      stats.ewmaJitterMs = _ewma(stats.ewmaJitterMs, jitterMs.toDouble());
    }
    stats.successRate = _ewma(stats.successRate, 1.0);
    stats.lastProbedUtcMs = _wallClock();
    stats.vantageStale = false;
    markSucceeded(sourceId);
  }

  /// Latches [SourceQualityStats.succeededOnce] for [sourceId] without
  /// touching any other metric.
  ///
  /// Separated from [recordProbe] because the two answer to different
  /// events. The metrics are cycle bookkeeping: a blocking query's are
  /// folded in at the end of the cycle, from the samples that arrived
  /// in time to matter. The latch is not bookkeeping but a fact about
  /// the host, and it is established the moment the host answers —
  /// whether or not the cycle still wants the answer.
  ///
  /// The distinction is load-bearing because a cycle can exit early on
  /// quorum, and samples landing after that are discarded before
  /// [record] ever sees them. A host that answered every cycle but
  /// always a little late would stay unpromotable forever, which
  /// inverts the admission rule: the promotion filter would exclude
  /// exactly the reachable hosts it exists to find.
  ///
  /// Stamps [SourceQualityStats.lastProbedUtcMs] alongside the latch,
  /// since that field is what [snapshot] prunes by and what [restore]
  /// ages out. An entry left at the epoch default would be discarded on
  /// the next start as a month stale, so the one path that can create
  /// an entry without any metric would also be the one path whose
  /// evidence never survives a restart. The stamp is advisory
  /// bookkeeping, not a measurement: no EWMA is touched.
  ///
  /// The stamp also advances [lastProbedUtcMs], and that is the
  /// intended reading: the host was contacted, whatever the cycle did
  /// with the answer, so re-offering it at the head of the explorer
  /// walk would spend exploration on a host already known to be up. A
  /// vantage mark is left as it stands — clearing it is the metric
  /// path's business, and until a metric arrives the source keeps
  /// reporting a null cursor and so keeps its place at the head of the
  /// re-sweep.
  ///
  /// The *starvation* cursor is untouched. That one counts queries the
  /// cycle chose to make, and moving it would let a latch defer the
  /// rescue for the host it is asserting is good.
  ///
  /// Idempotent, and safe to call alongside [recordProbe] — the latch
  /// is a set-to-true, so no EWMA is applied twice.
  void markSucceeded(String sourceId) {
    _stats.putIfAbsent(sourceId, _SourceStats.new)
      ..succeededOnce = true
      ..lastProbedUtcMs = _wallClock();
  }

  /// Records a failure for a source: the query cycle is noted so
  /// starvation detection still works, and the durable success rate
  /// decays — penalizing and deferring the source without ever
  /// permanently dropping it.
  void recordFailure(String sourceId) {
    _lastQueriedCycle[sourceId] = _cycleIndex;
    final stats = _stats.putIfAbsent(sourceId, _SourceStats.new);
    stats.successRate = _ewma(stats.successRate, 0.0);
    stats.lastProbedUtcMs = _wallClock();
    // A failure is still a measurement from the current vantage: the
    // host was reachable enough to try and did not answer. Leaving the
    // mark set would keep re-offering it at the head of the walk every
    // cycle, so an unreachable host would crowd out the rest of the
    // re-exploration the vantage change asked for.
    stats.vantageStale = false;
  }

  /// Marks every known source's durable stats as measured from a
  /// vantage the device has since left.
  ///
  /// Called on a vantage-epoch change. Nothing is deleted: the metrics
  /// stay available to break ties, but each marked source reports a
  /// null [lastProbedUtcMs], which puts the whole inventory back at the
  /// unprobed end of the explorer walk so it is re-swept from the new
  /// vantage. Scores are attenuated toward neutral by
  /// [_kStaleScoreWeight], which discounts old evidence without
  /// reordering the stale sources among themselves.
  ///
  /// Deleting instead would lose the tie-break data and, worse, make
  /// the two cases indistinguishable: a source that has never answered
  /// from anywhere would look exactly like one that simply hasn't been
  /// re-probed yet.
  ///
  /// The mark clears per source on its next probe, so recovery is
  /// incremental — sources come back to full weight as they are
  /// re-measured, rather than all at once on some later signal. It
  /// survives process death via [snapshot] / [restore], since a restart
  /// is not a return to the old vantage and the epoch that raised the
  /// mark persists alongside it.
  void markVantageStale() {
    for (final stats in _stats.values) {
      stats.vantageStale = true;
    }
  }

  /// Whether [sourceId]'s durable stats predate the current vantage.
  ///
  /// False for a source with no stats at all: absent is not stale.
  @visibleForTesting
  bool isVantageStale(String sourceId) =>
      _stats[sourceId]?.vantageStale ?? false;

  /// Optionally registers an NTP stratum hint for a source.
  ///
  /// Stratum 1 (directly attached to a reference clock) scores highest.
  /// Valid range: 1–15; values outside this range are ignored.
  void setStratum(String sourceId, int stratum) {
    if (stratum >= 1 && stratum <= 15) {
      _stratumHints[sourceId] = stratum;
    }
  }

  /// Returns the durable per-source stats for persistence, pruned to the
  /// [_kMaxPersistedSources] most recently probed sources.
  Map<String, SourceQualityStats> snapshot() {
    final ids = _stats.keys.toList()
      ..sort(
        (a, b) =>
            _stats[b]!.lastProbedUtcMs.compareTo(_stats[a]!.lastProbedUtcMs),
      );
    return {
      for (final id in ids.take(_kMaxPersistedSources))
        id: SourceQualityStats(
          ewmaRttMs: _stats[id]!.ewmaRttMs,
          ewmaJitterMs: _stats[id]!.ewmaJitterMs,
          successRate: _stats[id]!.successRate,
          lastProbedUtcMs: _stats[id]!.lastProbedUtcMs,
          stratum: _stratumHints[id],
          vantageStale: _stats[id]!.vantageStale,
          succeededOnce: _stats[id]!.succeededOnce,
        ),
    };
  }

  /// Seeds the durable stats from a persisted snapshot, discarding
  /// entries older than [_kStatsStalenessMs] — a month-old stat says
  /// nothing about today's network vantage.
  ///
  /// Restored entries replace any accumulated stats for the same source;
  /// call this on engine construction, before the first cycle. The
  /// process-local observation history and cycle counters are unaffected.
  ///
  /// A future-dated `lastProbedUtcMs` (recorded while the wall clock was
  /// ahead, then corrected) is clamped to now: left unclamped it would
  /// dominate the recency ordering in [snapshot] indefinitely and dodge
  /// the staleness cutoff forever. In-process recording always stamps
  /// from the current clock, so restore is the only entry point for
  /// future values.
  ///
  /// A vantage mark is restored with the entry. It records that the
  /// reading came from a network the device has left, which a restart
  /// does not undo, and the epoch that would have re-marked it persists
  /// too — so dropping the mark here would quietly restore full weight
  /// to readings taken somewhere else.
  void restore(Map<String, SourceQualityStats> stats) {
    final now = _wallClock();
    stats.forEach((id, s) {
      if (now - s.lastProbedUtcMs > _kStatsStalenessMs) return;
      _stats[id] = _SourceStats()
        ..ewmaRttMs = s.ewmaRttMs
        ..ewmaJitterMs = s.ewmaJitterMs
        ..successRate = s.successRate.clamp(0.0, 1.0)
        ..lastProbedUtcMs = s.lastProbedUtcMs > now ? now : s.lastProbedUtcMs
        ..vantageStale = s.vantageStale
        ..succeededOnce = s.succeededOnce;
      final stratum = s.stratum;
      if (stratum != null) setStratum(id, stratum);
    });
  }

  /// Advances the internal cycle counter. Call once per completed sync cycle.
  void advanceCycle() => _cycleIndex++;

  /// Returns the provided [sourceIds] sorted by quality score, highest
  /// first. Every distinct input id is returned exactly once; this method
  /// neither adds nor drops sources. Duplicate ids are collapsed to a
  /// single entry — a colliding id (e.g. two misconfigured sources sharing
  /// an `id`) must not be ranked, and therefore queried, twice in a cycle.
  ///
  /// Starvation handling is the caller's responsibility: the engine pairs
  /// this ranking with [isStarved] to force-include sources the cooldown
  /// filter would otherwise exclude.
  List<String> ranked(Iterable<String> sourceIds) {
    // toSet() preserves first-seen order (LinkedHashSet) while dropping
    // duplicates, so the sort below reorders a deduplicated id set.
    final ids = sourceIds.toSet().toList();
    final scores = {for (final id in ids) id: _score(id)};
    ids.sort((a, b) => scores[b]!.compareTo(scores[a]!));
    return ids;
  }

  /// When [sourceId] was last probed, in UTC milliseconds, or `null` if
  /// no probe of it counts from here — either it has never been probed,
  /// or it was probed from a vantage the device has since left.
  ///
  /// Survives process death via [snapshot] / [restore], which is what
  /// lets the explorer walk resume where it left off without persisting
  /// a separate cursor. Advisory: the value is stamped from the wall
  /// clock, so it moves if the clock is corrected.
  ///
  /// A vantage-stale source reports `null`, the same as one never
  /// probed. This is the whole mechanism by which a vantage change
  /// restarts the explorer walk: `partitionInventory` orders candidates
  /// by this cursor and sorts null first, so marking the inventory
  /// stale returns all of it to the head of the walk without the
  /// partition needing to know that vantages exist. The underlying
  /// timestamp is unchanged and still governs snapshot pruning and
  /// restore staleness, which are about age rather than vantage.
  int? lastProbedUtcMs(String sourceId) {
    final stats = _stats[sourceId];
    if (stats == null || stats.vantageStale) return null;
    return stats.lastProbedUtcMs;
  }

  /// Whether [sourceId] has ever been probed at all, successfully or
  /// not.
  ///
  /// Weaker than [hasSucceeded], not its complement: a host that
  /// answered returns true from both. Read together they split a source
  /// three ways — never tried (neither), tried and failed (this one
  /// alone), tried and answered (both). The NTS cold-start fill needs
  /// the first of those on its own, since a host it knows nothing about
  /// is a reasonable gamble where one it has already watched fail is
  /// not.
  ///
  /// Unaffected by a vantage change, like [hasSucceeded] and unlike
  /// [lastProbedUtcMs]: the question is whether a measurement exists,
  /// not whether it is current.
  bool hasBeenProbed(String sourceId) => _stats.containsKey(sourceId);

  /// Whether [sourceId] has ever answered a probe successfully.
  ///
  /// The NTS promotion step's admission test: a host may only be
  /// promoted into the query target on recorded evidence that it works.
  /// Mere presence in the tracker is not enough, since a failed probe
  /// creates an entry too, and [ranked] scores an unmeasured source
  /// neutrally rather than badly — so without this a host known only
  /// from a timeout could outrank one never tried and fill a slot the
  /// target's failure headroom depends on.
  ///
  /// Unlike [lastProbedUtcMs], a vantage change does not reset this. The
  /// flag records that the host answered *somewhere*, which is evidence
  /// the host exists and speaks the protocol; whether it is reachable
  /// from here is what the re-sweep establishes, and the attenuated
  /// score already discounts the stale measurement.
  bool hasSucceeded(String sourceId) =>
      _stats[sourceId]?.succeededOnce ?? false;

  /// Returns `true` if [sourceId] should be force-included this cycle to
  /// prevent starvation, regardless of its quality rank.
  bool isStarved(String sourceId) {
    final last = _lastQueriedCycle[sourceId];
    if (last == null) return true; // Never queried.
    return (_cycleIndex - last) >= _kStarvationCycles;
  }

  /// Fraction of retained observations for [sourceId] that participated in
  /// the consensus winning set, or `null` when the source has no history.
  ///
  /// Exposed for tests asserting that the engine records non-participant
  /// samples, so the participation dimension is not pinned at 1.0.
  @visibleForTesting
  double? participationRate(String sourceId) {
    final q = _history[sourceId];
    if (q == null || q.isEmpty) return null;
    return q.where((o) => o.participatedInConsensus).length / q.length;
  }

  double _score(String sourceId) {
    final q = _history[sourceId];
    final stats = _stats[sourceId];

    // No signal at all: treat as neutral (will be queried; starvation
    // guard handles it).
    if ((q == null || q.isEmpty) && stats == null) return 0.5;

    // RTT score: prefer the durable EWMA of measured round trips (the
    // proximity signal proper, and the only dimension available right
    // after a restore); fall back to in-memory interval uncertainty for
    // sources that never reported a delay. Map to (0, 1]: asymptotic
    // curve so very fast sources score near 1.0.
    final double rttScore;
    final ewmaRtt = stats?.ewmaRttMs;
    if (ewmaRtt != null) {
      // delayMs is a whole round trip; halve it so the curve stays on
      // the same scale as the half-width uncertainty fallback.
      rttScore = 1.0 / (1.0 + log(1 + (ewmaRtt / 2) / 50));
    } else if (q != null && q.isNotEmpty) {
      final uncertainties = q.map((o) => o.uncertaintyMs).toList();
      final avgUncertainty =
          uncertainties.fold(0, (a, b) => a + b) / uncertainties.length;
      rttScore = 1.0 / (1.0 + log(1 + avgUncertainty / 50));
    } else {
      rttScore = 0.5;
    }

    // Consensus participation rate (process-local; neutral after restore).
    final participationRate = q == null || q.isEmpty
        ? 0.5
        : q.where((o) => o.participatedInConsensus).length / q.length;

    // Durable success rate: failures decay it, deferring the source.
    final successRate = stats?.successRate ?? 1.0;

    // Jitter score: same asymptotic shape; a stable path scores near 1.0.
    final ewmaJitter = stats?.ewmaJitterMs;
    final jitterScore = ewmaJitter != null
        ? 1.0 / (1.0 + log(1 + ewmaJitter / 50))
        : 0.5;

    // Stratum score: 1→1.0, 15→0.0, absent→0.5.
    final stratum = _stratumHints[sourceId];
    final stratumScore = stratum != null ? (15 - stratum) / 14.0 : 0.5;

    // Weighted combination.
    final score =
        (rttScore * 0.3) +
        (participationRate * 0.25) +
        (successRate * 0.25) +
        (jitterScore * 0.1) +
        (stratumScore * 0.1);

    // Vantage-stale metrics describe a network the device has left, so
    // they are evidence about the wrong place. Pulling the score toward
    // the 0.5 neutral rather than discarding it keeps the ordering
    // among stale sources — the only ordering available until fresh
    // measurements land. The pull is symmetric, so it moves a stale
    // source across an unmarked one in either direction; see
    // [_kStaleScoreWeight].
    if (stats != null && stats.vantageStale) {
      return 0.5 + (score - 0.5) * _kStaleScoreWeight;
    }
    return score;
  }

  static double _ewma(double? previous, double sample) => previous == null
      ? sample
      : previous * (1 - _kEwmaAlpha) + sample * _kEwmaAlpha;
}
