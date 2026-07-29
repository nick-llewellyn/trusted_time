import 'package:flutter/foundation.dart';

import 'confidence_level.dart';

@immutable
/// Diagnostic metrics captured during a synchronization cycle.
final class SyncMetrics {
  /// Creates a new [SyncMetrics] instance with diagnostic data from a synchronization cycle.
  const SyncMetrics({
    required this.latencyMs,
    required this.uncertaintyMs,
    required this.participantCount,
    required this.quorumDepth,
    required this.groupCount,
    required this.confidence,
    required this.confidenceBreakdown,
  });

  /// The total time taken for the network synchronization cycle.
  final int latencyMs;

  /// The precision achieved by the resolved consensus.
  final int uncertaintyMs;

  /// The number of unique time authorities whose interval contains the
  /// consensus midpoint. Stricter than [quorumDepth] — see
  /// `ConsensusResult.participantCount` for the divergence conditions.
  /// Use [quorumDepth] for quorum-floor reasoning.
  final int participantCount;

  /// The number of unique sources active at the densest overlap point
  /// during Marzullo's sweep. This is the figure used by the quorum
  /// check and confidence grading.
  ///
  /// For values produced by the engine, always satisfies
  /// `quorumDepth >= participantCount`. This is an engine invariant,
  /// not a structural one — the type does not constrain the pairing,
  /// since [SyncMetrics] is publicly constructible for tests and mocks
  /// (and the underlying `int` field permits negative values too, even
  /// though engine-produced metrics are always non-negative). See
  /// `ConsensusResult.quorumDepth`.
  final int quorumDepth;

  /// The number of administrative groups represented in the quorum.
  final int groupCount;

  /// The qualitative grade of the synchronization result.
  final ConfidenceLevel confidence;

  /// A granular breakdown of confidence factors (e.g., depth, diversity, stability).
  final Map<String, double> confidenceBreakdown;
}
