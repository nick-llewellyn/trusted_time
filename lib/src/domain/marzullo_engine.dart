import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../trusted_time.dart';

/// The resolved state of a consensus cycle.
///
/// Encapsulates the verified UTC time, the calculated precision (uncertainty),
/// and the metadata required to judge the integrity of the consensus.
@immutable
final class ConsensusResult {
  /// Creates a new [ConsensusResult] from the resolved consensus interval and metadata.
  const ConsensusResult({
    required this.utc,
    required this.uncertaintyMs,
    required this.participantCount,
    required this.quorumDepth,
    required this.groupCount,
    required this.participants,
    this.authLevel = NtsAuthLevel.none,
    this.confidence = ConfidenceLevel.low,
    this.interval,
    this.degradedTier = false,
    this.droppedOutsideTruthBox = const {},
  });

  /// The published UTC point estimate: the root-distance-weighted centre
  /// of the survivors, clamped into the consensus [interval]. Lower root
  /// distance and higher trust tier pull this toward those samples, so it
  /// can sit off the geometric centre of [interval] (the latter remains
  /// the structural anchor for [participantCount]).
  final DateTime utc;

  /// The precision of the consensus: the larger distance from [utc] to
  /// either edge of the consensus window, so the symmetric envelope
  /// `[utc - uncertaintyMs, utc + uncertaintyMs]` always covers the full
  /// overlap interval even when [utc] sits off the geometric centre.
  final int uncertaintyMs;

  /// Number of unique time authorities whose interval contains the
  /// geometric centre of the consensus window.
  ///
  /// For engine-produced results, containment is checked against the
  /// integer-truncated geometric centre of the window endpoints
  /// (`(interval!.startMs + interval!.endMs) ~/ 2`; `interval` is
  /// always non-null on engine-produced results but the type permits
  /// `null` for tests and mocks). This geometric centre is the engine's
  /// structural anchor and is *not* the same as [utc], which is the
  /// root-distance-weighted estimate and may sit off it. On odd-width
  /// windows the truncated centre sits one millisecond closer to
  /// `interval!.startMs` than the real centre would.
  ///
  /// This is a stricter measure than [quorumDepth]: a sample's interval
  /// can overlap the consensus window (`[interval!.startMs,
  /// interval!.endMs]` for engine-produced results) and so contribute
  /// to [groupCount] without containing the geometric centre, in which
  /// case it is excluded from this count. The two values diverge when
  /// the consensus window is wide and the sample distribution is
  /// asymmetric — for example, when one source's response latency is
  /// consistently bimodal and its late samples shift the window
  /// boundaries past where the other sources' midpoints sit.
  ///
  /// Use [quorumDepth] for quorum-floor reasoning and confidence-grading
  /// reasoning; use this field for "which authorities agreed at the
  /// consensus window centre" reasoning.
  final int participantCount;

  /// Number of unique sources active at the densest overlap point during
  /// Marzullo's sweep. This is the figure used by the engine's quorum
  /// check (`>= requiredQuorum`) and confidence grading.
  ///
  /// For values produced by [MarzulloEngine.resolve], always satisfies
  /// `quorumDepth >= participantCount`. This is an engine invariant,
  /// not a structural one — the type does not constrain the pairing,
  /// since [ConsensusResult] is publicly constructible for tests and
  /// mocks (and the underlying `int` field permits negative values too,
  /// even though engine-produced results are always non-negative).
  ///
  /// The two values diverge when the consensus window is wide and the
  /// sample distribution is asymmetric (see [participantCount] for
  /// details). Exposed so telemetry consumers can reason about quorum
  /// depth directly rather than inferring it from [participantCount],
  /// which is a stricter midpoint-containment measure.
  final int quorumDepth;

  /// Number of distinct administrative groups (e.g. ASNs) in the consensus.
  final int groupCount;

  /// The set of samples that participated in the consensus.
  /// A sample is a participant if its interval contains the geometric
  /// centre of the consensus window (see [participantCount]); this is the
  /// engine's structural anchor, not the weighted estimate [utc].
  final Set<TimeSample> participants;

  /// The highest common authentication level achieved across the consensus group.
  final NtsAuthLevel authLevel;

  /// Qualitative grade of the consensus established by the [MarzulloEngine].
  final ConfidenceLevel confidence;

  /// The raw [TimeInterval] representing the intersection of all quorum samples.
  final TimeInterval? interval;

  /// Whether this consensus was published without a Tier 1 (verified) truth
  /// box and therefore fell back to a legacy single-tier reduction.
  ///
  /// `true` implies [authLevel] is [NtsAuthLevel.none]; `SyncEngine` reads
  /// this flag to emit a [TamperReason.degradedTier] integrity event for the
  /// cycle. Tier-aware results that formed a truth box report `false`.
  final bool degradedTier;

  /// Lower-tier samples (platform-mediated NTS or plain NTP/HTTPS) that were
  /// excluded because their interval did not intersect the Tier 1 truth box.
  ///
  /// Always empty on degraded ([degradedTier] `true`) and legacy results.
  /// `SyncEngine` surfaces each entry via
  /// [SyncObserver.onSourceFailed] with the reason `tier2: outside truth box`.
  final Set<TimeSample> droppedOutsideTruthBox;

  /// Returns a copy of this result with the given fields replaced.
  ConsensusResult copyWith({
    DateTime? utc,
    int? uncertaintyMs,
    int? participantCount,
    int? quorumDepth,
    int? groupCount,
    Set<TimeSample>? participants,
    NtsAuthLevel? authLevel,
    ConfidenceLevel? confidence,
    TimeInterval? interval,
    bool? degradedTier,
    Set<TimeSample>? droppedOutsideTruthBox,
  }) {
    return ConsensusResult(
      utc: utc ?? this.utc,
      uncertaintyMs: uncertaintyMs ?? this.uncertaintyMs,
      participantCount: participantCount ?? this.participantCount,
      quorumDepth: quorumDepth ?? this.quorumDepth,
      groupCount: groupCount ?? this.groupCount,
      participants: participants ?? this.participants,
      authLevel: authLevel ?? this.authLevel,
      confidence: confidence ?? this.confidence,
      interval: interval ?? this.interval,
      degradedTier: degradedTier ?? this.degradedTier,
      droppedOutsideTruthBox:
          droppedOutsideTruthBox ?? this.droppedOutsideTruthBox,
    );
  }
}

/// A high-integrity implementation of Marzullo's algorithm for time consensus.
///
/// This engine resolves a single "truth" from multiple, potentially noisy or
/// malicious time authorities. It treats each time sample as an interval
/// `[T - error, T + error]` and searches for the intersection that contains
/// the most probable true time.
///
/// ## Key Refinements
///
/// * **Group-Aware Diversity**: Prevents "correlated failures" where a single
///   provider (e.g. a specific data center or ASN) dominates the consensus.
/// * **Closed-Interval Tie-breaking**: Strictly enforces that endpoint boundaries
///   are inclusive, ensuring stable overlap detection even with identical timestamps.
/// * **Graduated Trust**: Automatically grades the resulting consensus as
///   low, medium, or high confidence based on depth and diversity.
final class MarzulloEngine {
  /// Creates a new [MarzulloEngine] with the specified consensus parameters.
  const MarzulloEngine({
    this.minQuorumRatio = 0.6,
    this.maxAllowedUncertaintyMs = 10000,
    this.minGroupCount = 2,
  });

  /// The minimum percentage of responding sources that must participate in
  /// the consensus for it to be considered valid.
  final double minQuorumRatio;

  /// Hard exclusion threshold. Sources with uncertainty exceeding this
  /// are discarded to prevent "consensus bloating."
  final int maxAllowedUncertaintyMs;

  /// Minimum number of distinct administrative groups required to achieve
  /// high-confidence status.
  final int minGroupCount;

  /// Orchestrates tier-aware consensus resolution across a set of samples.
  ///
  /// Implements the tiered-trust admission model (design doc section 4):
  ///
  /// 1. **Truth-box pass.** Only `NtsAuthLevel.verified` samples (Tier 1)
  ///    may define the authoritative consensus interval. A Marzullo
  ///    reduction over the verified subset alone produces the *truth box*.
  /// 2. **Re-admission pass.** Every lower-tier sample (platform-mediated
  ///    NTS or plain NTP/HTTPS) whose interval intersects the truth box is
  ///    folded into a merged set; non-intersecting samples are dropped and
  ///    surfaced on [ConsensusResult.droppedOutsideTruthBox].
  /// 3. **Final reduction.** A Marzullo reduction over the merged set
  ///    refines the published result, but can never move the consensus
  ///    midpoint outside the truth box — a lower-tier cluster cannot
  ///    relocate the anchor (design doc section 4.3). The result reports
  ///    `authLevel == NtsAuthLevel.verified`.
  ///
  /// If the verified samples cannot form a truth box — too few are present,
  /// or those present are too divergent to reach a Marzullo quorum (i.e.
  /// `_resolveCore` over the verified subset returns `null`) — the cycle is
  /// *degraded*. The engine falls back to a legacy single-tier Marzullo over
  /// all [samples], forces
  /// `authLevel == NtsAuthLevel.none`, and sets
  /// [ConsensusResult.degradedTier] so `SyncEngine` can emit
  /// [TamperReason.degradedTier]. Returns `null` only when even the
  /// fallback reduction cannot reach a quorum.
  ConsensusResult? resolve(List<TimeSample> samples) {
    final verified = samples
        .where((s) => _tierOf(s) == _Tier.verified)
        .toList();

    final truthBox = _resolveCore(verified);
    if (truthBox == null || truthBox.interval == null) {
      // No Tier 1 truth box this cycle. Fall back to a legacy single-tier
      // reduction over every sample, flagged as degraded with the auth
      // level pinned to none regardless of any stray verified sample that
      // could otherwise lift the core's weakest-link computation.
      final legacy = _resolveCore(samples);
      if (legacy == null) return null;
      return legacy.copyWith(authLevel: NtsAuthLevel.none, degradedTier: true);
    }

    final box = truthBox.interval!;
    final dropped = <TimeSample>{};
    final merged = <TimeSample>[...verified];
    for (final s in samples) {
      if (_tierOf(s) == _Tier.verified) continue;
      if (_intervalsIntersect(s.interval, box)) {
        merged.add(s);
      } else {
        dropped.add(s);
      }
    }

    // Refine over the merged set, but keep the truth box authoritative: a
    // lower-tier reduction is accepted only when its midpoint still lands
    // inside the truth box. Otherwise (a coordinated lower-tier cluster
    // tried to relocate the anchor, or the widened quorum floor rejected
    // the reduction) we publish the verified truth box unchanged.
    final refined = _resolveCore(merged);
    final base =
        (refined != null &&
            refined.interval != null &&
            _withinBox(refined.utc.millisecondsSinceEpoch, box))
        ? refined
        : truthBox;

    return base.copyWith(
      authLevel: NtsAuthLevel.verified,
      degradedTier: false,
      droppedOutsideTruthBox: dropped,
    );
  }

  /// Single-tier Marzullo reduction over [samples].
  ///
  /// Returns a [ConsensusResult] if a quorum is achieved that satisfies the
  /// [minQuorumRatio] and [minGroupCount] constraints, or `null` if the
  /// samples are too divergent or the population is insufficient. The
  /// `authLevel` it computes here is the legacy weakest-link value; the
  /// tier-aware [resolve] wrapper overrides it per the truth-box policy.
  ConsensusResult? _resolveCore(List<TimeSample> samples) {
    // Filter out invalid samples (negative uncertainty indicates clock errors)
    // and noisy sources with excessive uncertainty.
    final validSamples = samples
        .where(
          (s) =>
              s.uncertaintyMs >= 0 &&
              s.uncertaintyMs <= maxAllowedUncertaintyMs,
        )
        .toList();

    final totalSources = validSamples.length;
    final requiredQuorum = (totalSources * minQuorumRatio).ceil();

    // Minimum 2 samples required for any consensus (avoids single-source trust)
    if (totalSources < 2 || requiredQuorum < 2) return null;

    final endpoints = <_Endpoint>[];
    for (final s in validSamples) {
      endpoints
        ..add(_Endpoint(s.interval.startMs, _EndpointType.lower, s))
        ..add(_Endpoint(s.interval.endMs, _EndpointType.upper, s));
    }

    // Sort endpoints to find the densest overlap.
    // In Marzullo's algorithm, for closed intervals, an 'upper' endpoint
    // at time T should be processed before a 'lower' endpoint at time T
    // to correctly count the depth at the point of overlap.
    //
    // Comparator contract: when both `timeMs` and `type` match the
    // endpoints are equal under this ordering and the comparator must
    // return 0. Returning a non-zero value for equal inputs violates
    // Dart's `Comparator` typedef and produces undefined ordering on
    // sort backends that depend on the contract (the current TimSort
    // tolerates it). The sweep result is invariant to the relative
    // order of same-type-same-time endpoints — both lowers increment
    // `activeSourceCounts` before any best-window snapshot and both
    // uppers decrement after — so this is a contract repair, not a
    // behavioural change.
    endpoints.sort((a, b) {
      final cmp = a.timeMs.compareTo(b.timeMs);
      if (cmp != 0) return cmp;
      if (a.type == b.type) return 0;
      return a.type == _EndpointType.upper ? -1 : 1;
    });

    var bestUniqueOverlap = 0;
    int? bestStart;
    int? bestEnd;

    // Multiset tracking: sourceId -> count of active intervals from that source
    // Multiple samples from same source count as one unique participant
    final activeSourceCounts = <String, int>{};
    final bestSamples = <TimeSample>{};

    // Track the best end point during the sweep
    // When we find the best start, the best end is the first upper endpoint
    // that causes the unique overlap to drop below bestUniqueOverlap
    for (final ep in endpoints) {
      if (ep.type == _EndpointType.lower) {
        // Increment count for this source
        activeSourceCounts[ep.sample.sourceId] =
            (activeSourceCounts[ep.sample.sourceId] ?? 0) + 1;

        final uniqueOverlap = activeSourceCounts.length;
        // Optimize on unique source count for better consensus quality
        if (uniqueOverlap > bestUniqueOverlap) {
          bestUniqueOverlap = uniqueOverlap;
          bestStart = ep.timeMs;
          bestEnd = null;
          // Rebuild bestSamples with all samples currently active
          bestSamples.clear();
          for (final s in validSamples) {
            if (s.interval.startMs <= bestStart &&
                bestStart <= s.interval.endMs) {
              bestSamples.add(s);
            }
          }
        }
      } else {
        // When processing an upper endpoint, check if this could be the best end
        // for the current best start
        if (bestStart != null && bestEnd == null && ep.timeMs >= bestStart) {
          final uniqueOverlap = activeSourceCounts.length;
          if (uniqueOverlap < bestUniqueOverlap) {
            // We've dropped below the best overlap, so the previous upper endpoint
            // was the best end point
            bestEnd = ep.timeMs;
          }
        }
        if (activeSourceCounts[ep.sample.sourceId] == 1) {
          activeSourceCounts.remove(ep.sample.sourceId);
        } else {
          activeSourceCounts[ep.sample.sourceId] =
              activeSourceCounts[ep.sample.sourceId]! - 1;
        }
      }
    }

    // If we never found a best end (e.g., the best overlap extends to the end),
    // use the last upper endpoint
    if (bestStart != null && bestEnd == null) {
      for (final ep in endpoints.reversed) {
        if (ep.type == _EndpointType.upper) {
          bestEnd = ep.timeMs;
          break;
        }
      }
    }

    // Rebuild bestSamples with all samples that overlap the consensus window [bestStart, bestEnd]
    if (bestStart != null && bestEnd != null) {
      bestSamples.clear();
      for (final s in validSamples) {
        // Check if sample interval overlaps the consensus window
        if (s.interval.startMs <= bestEnd && s.interval.endMs >= bestStart) {
          bestSamples.add(s);
        }
      }
    }

    // A consensus is only valid if it reaches the required population depth.
    if (bestUniqueOverlap < requiredQuorum ||
        bestStart == null ||
        bestEnd == null) {
      return null;
    }

    final uniqueGroups = bestSamples.map((s) => s.groupId).toSet();
    final groupCount = uniqueGroups.length;

    // We grade confidence based on both the depth of the quorum and the
    // diversity of its providers. A high-confidence result requires
    // exceeding the minimum quorum and meeting diversity requirements.
    var confidence = ConfidenceLevel.low;
    if (groupCount >= minGroupCount) {
      confidence = ConfidenceLevel.medium;
      if (bestUniqueOverlap >= requiredQuorum + 1) {
        confidence = ConfidenceLevel.high;
      }
    }

    // Geometric centre of the Marzullo window. Retained as the structural
    // anchor for participant containment below (the quorumDepth vs
    // participantCount divergence is defined against this geometric
    // centre, not the published estimate). `~/` truncates toward zero, so
    // on odd-width windows it sits one millisecond closer to bestStart.
    final midMs = (bestStart + bestEnd) ~/ 2;

    // One source, one vote: collapse the survivors to a single
    // representative per sourceId before weighting. A "chatty" source is
    // already counted once for quorum/participants (the sweep tracks
    // unique sourceIds), so it must not get one weighted vote per sample —
    // otherwise a single source emitting many samples could dominate the
    // published estimate. The representative is the source's
    // lowest-root-distance sample (its tightest measurement), with the
    // higher trust tier breaking ties.
    final representatives = <String, TimeSample>{};
    for (final s in bestSamples) {
      final existing = representatives[s.sourceId];
      if (existing == null ||
          s.rootDistanceMs < existing.rootDistanceMs ||
          (s.rootDistanceMs == existing.rootDistanceMs &&
              _tierWeight(_tierOf(s)) > _tierWeight(_tierOf(existing)))) {
        representatives[s.sourceId] = s;
      }
    }

    // Root-distance-weighted centre (Mills-style) over the per-source
    // representatives: each contributes its interval midpoint weighted by
    // `tierWeight(tier) / max(1, rootDistance)`, so a lower root distance
    // (tighter RTT + dispersion) or a higher trust tier pulls the
    // published estimate toward that sample. Clamped into
    // `[bestStart, bestEnd]` so a weighted estimate — including a
    // coordinated lower-tier cluster in the merged pass — can never
    // escape the Marzullo intersection.
    var weightSum = 0.0;
    var weightedMidSum = 0.0;
    for (final s in representatives.values) {
      final w = _tierWeight(_tierOf(s)) / max(1, s.rootDistanceMs);
      weightSum += w;
      weightedMidSum += w * s.interval.midpoint;
    }
    final combinedMs = weightSum > 0
        ? (weightedMidSum / weightSum).round().clamp(bestStart, bestEnd)
        : midMs;

    // Symmetric half-width that always covers the Marzullo window. Because
    // the weighted centre can sit off the geometric midpoint, the half-
    // width is the larger distance from the centre to either window edge,
    // so the published `[utc - U, utc + U]` never under-covers
    // `[bestStart, bestEnd]` (regression: trusted_time-02x). When the
    // centre is geometric this reduces to the ceiling half-width.
    final uncertaintyMs = max(combinedMs - bestStart, bestEnd - combinedMs);

    // The consensus authentication level is determined by the "weakest link."
    // If even one source in the quorum is unauthenticated, the entire
    // consensus cannot be considered fully authenticated.
    var effectiveAuth = NtsAuthLevel.verified;
    for (final s in bestSamples) {
      if (s.authLevel.index < effectiveAuth.index) {
        effectiveAuth = s.authLevel;
      }
    }

    // Participants are samples whose interval contains the geometric
    // centre of the consensus window (midMs), the engine's structural
    // anchor — not the weighted estimate published as utc. Keep only one
    // sample per unique source ID.
    final participantsMap = <String, TimeSample>{};
    for (final s in bestSamples) {
      if (s.interval.startMs <= midMs && midMs <= s.interval.endMs) {
        participantsMap[s.sourceId] = s;
      }
    }
    final participants = participantsMap.values.toSet();

    // participantCount should be the number of unique sources in participants
    final participantCount = participants.length;

    return ConsensusResult(
      utc: DateTime.fromMillisecondsSinceEpoch(combinedMs, isUtc: true),
      uncertaintyMs: max(1, uncertaintyMs),
      participantCount: participantCount,
      quorumDepth: bestUniqueOverlap,
      groupCount: groupCount,
      authLevel: effectiveAuth,
      confidence: confidence,
      interval: TimeInterval(startMs: bestStart, endMs: bestEnd),
      participants: participants,
    );
  }
}

enum _EndpointType { lower, upper }

final class _Endpoint {
  const _Endpoint(this.timeMs, this.type, this.sample);
  final int timeMs;
  final _EndpointType type;
  final TimeSample sample;
}

/// Trust tier of a single sample under the tiered-trust admission model
/// (design doc section 4.1). Classification keys off the joint
/// `(authLevel, trustBackend)` shape — no new field on [TimeSample].
enum _Tier {
  /// `NtsAuthLevel.verified`: bundled-roots or custom-roots NTS. Defines
  /// the truth box.
  verified,

  /// `NtsAuthLevel.none` with a non-null `trustBackend`: platform-mediated
  /// NTS. Admitted only if it intersects the verified truth box.
  platformNts,

  /// `NtsAuthLevel.none` with a null `trustBackend`: plain NTP / HTTPS /
  /// additional sources. Admitted under the same intersection rule;
  /// indistinguishable from [platformNts] at admission time.
  best,
}

/// Classifies a sample into its trust tier. Only `NtsSource` ever sets
/// `trustBackend`, so the joint shape uniquely separates platform-mediated
/// NTS from plain NTP/HTTPS without a dedicated field.
_Tier _tierOf(TimeSample s) {
  if (s.authLevel == NtsAuthLevel.verified) return _Tier.verified;
  if (s.trustBackend != null) return _Tier.platformNts;
  return _Tier.best;
}

/// Relative trust-tier weight for the root-distance-weighted combine
/// (design doc section 4.x). Root distance is the dominant term; this
/// weight only breaks ties between survivors with comparable root
/// distances, favouring verified samples over platform-mediated NTS over
/// plain best-effort sources. The truth-box `_withinBox` guard in
/// [MarzulloEngine.resolve] remains the hard anchor-protection mechanism.
double _tierWeight(_Tier tier) => switch (tier) {
  _Tier.verified => 4.0,
  _Tier.platformNts => 2.0,
  _Tier.best => 1.0,
};

/// Whether two closed intervals share at least one instant.
bool _intervalsIntersect(TimeInterval a, TimeInterval b) =>
    a.startMs <= b.endMs && a.endMs >= b.startMs;

/// Whether [ms] falls within the closed truth-box interval [box].
bool _withinBox(int ms, TimeInterval box) =>
    box.startMs <= ms && ms <= box.endMs;
