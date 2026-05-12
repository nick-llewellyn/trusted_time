import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../trusted_time.dart';

@immutable
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
  });

  /// The mid-point of the agreed consensus interval.
  final DateTime utc;

  /// The precision of the consensus, representing half the width of the overlap.
  final int uncertaintyMs;

  /// Number of unique time authorities whose interval contains the
  /// consensus midpoint reported as [utc].
  ///
  /// The midpoint is computed by integer-truncated division of the
  /// consensus window endpoints
  /// (`(interval.startMs + interval.endMs) ~/ 2`), so on odd-width
  /// windows it sits one millisecond closer to [interval.startMs] than
  /// the real centre would. Membership is checked against the truncated
  /// integer midpoint, not the real centre.
  ///
  /// This is a stricter measure than [quorumDepth]: a sample's interval
  /// can overlap the consensus window
  /// `[interval.startMs, interval.endMs]` (and so contribute to
  /// [groupCount]) without containing the midpoint, in which case it is
  /// excluded from this count. The two values diverge when the
  /// consensus window is wide and the sample distribution is asymmetric
  /// — for example, when one source's response latency is consistently
  /// bimodal and its late samples shift the window boundaries past
  /// where the other sources' midpoints sit.
  ///
  /// Use [quorumDepth] for quorum-floor reasoning and confidence-grading
  /// reasoning; use this field for "which authorities agreed at the
  /// midpoint" reasoning.
  final int participantCount;

  /// Number of unique sources active at the densest overlap point during
  /// Marzullo's sweep. This is the figure used by the engine's quorum
  /// check (`>= requiredQuorum`) and confidence grading.
  ///
  /// For values produced by [MarzulloEngine.resolve], always satisfies
  /// `quorumDepth >= participantCount`. (This is an engine invariant,
  /// not a structural one — the type permits any non-negative integer
  /// pairing, since [ConsensusResult] is publicly constructible for
  /// tests and mocks.)
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
  /// A sample is considered a participant if its interval contains the consensus midpoint.
  final Set<TimeSample> participants;

  /// The highest common authentication level achieved across the consensus group.
  final NtsAuthLevel authLevel;

  /// Qualitative grade of the consensus established by the [MarzulloEngine].
  final ConfidenceLevel confidence;

  /// The raw [TimeInterval] representing the intersection of all quorum samples.
  final TimeInterval? interval;
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

  /// Orchestrates the consensus resolution process across a set of samples.
  ///
  /// Returns a [ConsensusResult] if a quorum is achieved that satisfies
  /// the [minQuorumRatio] and [minGroupCount] constraints. Returns `null`
  /// if the samples are too divergent or the population is insufficient.
  ConsensusResult? resolve(List<TimeSample> samples) {
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

    // Marzullo midpoint and half-width. `~/` truncates toward zero, so
    // when the consensus window has odd width the published interval
    // `[midMs - uncertaintyMs, midMs + uncertaintyMs]` would miss the
    // truncation residual on one side of the true window
    // `[bestStart, bestEnd]`. Worst case for `bestStart=0, bestEnd=3`:
    // truncating gives `midMs=1, uncertaintyMs=1`, publishing `[0, 2]`
    // while the true window is `[0, 3]` — 1 ms uncovered at the top.
    //
    // Ceiling-divide the half-width so the published interval always
    // covers the true window. Worst-case overstatement is 1 ms; the
    // 1 ms minimum floor below remains the tight lower bound.
    final midMs = (bestStart + bestEnd) ~/ 2;
    final width = bestEnd - bestStart;
    final uncertaintyMs = (width + 1) ~/ 2;

    // The consensus authentication level is determined by the "weakest link."
    // If even one source in the quorum is unauthenticated, the entire
    // consensus cannot be considered fully authenticated.
    var effectiveAuth = NtsAuthLevel.verified;
    for (final s in bestSamples) {
      if (s.authLevel.index < effectiveAuth.index) {
        effectiveAuth = s.authLevel;
      }
    }

    // Participants are samples whose intervals contain the consensus midpoint
    // Keep only one sample per unique source ID
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
      utc: DateTime.fromMillisecondsSinceEpoch(midMs, isUtc: true),
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
