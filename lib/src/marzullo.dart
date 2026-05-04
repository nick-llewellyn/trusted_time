import 'dart:math';

import 'package:flutter/foundation.dart';

@immutable
final class SourceSample {
  const SourceSample({
    required this.sourceId,
    required this.utc,
    required this.roundTripMs,
  });

  final String sourceId;
  final DateTime utc;
  final int roundTripMs;

  int get uncertaintyMs => roundTripMs ~/ 2;
}

@immutable
final class ConsensusResult {
  const ConsensusResult({
    required this.utc,
    required this.uncertaintyMs,
    required this.participantCount,
  });

  final DateTime utc;
  final int uncertaintyMs;
  final int participantCount;
}

/// Resolves a single source-of-truth from overlapping confidence intervals
/// using [Marzullo's Algorithm](https://en.wikipedia.org/wiki/Marzullo%27s_algorithm).
final class MarzulloEngine {
  const MarzulloEngine({required this.minimumQuorum});

  final int minimumQuorum;

  ConsensusResult? resolve(List<SourceSample> samples) {
    if (samples.length < minimumQuorum) return null;

    final endpoints = <_Endpoint>[];
    for (final s in samples) {
      final center = s.utc.millisecondsSinceEpoch;
      final u = s.uncertaintyMs;
      endpoints
        ..add(_Endpoint(center - u, _EndpointType.lower, s))
        ..add(_Endpoint(center + u, _EndpointType.upper, s));
    }

    // Sort by time; at equal times, lower endpoints come first so overlap
    // counting uses closed-interval semantics (touching intervals overlap).
    endpoints.sort((a, b) {
      final cmp = a.timeMs.compareTo(b.timeMs);
      if (cmp != 0) return cmp;
      return a.type == _EndpointType.lower ? -1 : 1;
    });

    var best = 0;
    int? bestStart;
    int? bestEnd;
    var overlap = 0;

    // Multiset of currently-active source IDs. A plain Set would lose
    // multiplicity if the same source contributes overlapping samples:
    // when one of those samples closes its upper endpoint, set.remove
    // would drop the source even though another of its intervals is
    // still active, under-counting any later best-moment snapshot.
    final activeSourceCounts = <String, int>{};
    var bestSourceIdCount = 0;

    for (final ep in endpoints) {
      final id = ep.sample.sourceId;
      if (ep.type == _EndpointType.lower) {
        overlap++;
        activeSourceCounts.update(id, (c) => c + 1, ifAbsent: () => 1);
        if (overlap > best) {
          best = overlap;
          bestStart = ep.timeMs;
          // #7: Reset bestEnd when we find a new maximum overlap depth.
          // The correct closing endpoint hasn't been encountered yet.
          bestEnd = null;
          // Snapshot unique-source-ID count at the best moment so
          // participantCount reports authorities, not raw overlap depth.
          bestSourceIdCount = activeSourceCounts.length;
        }
      } else {
        if (overlap == best && bestStart != null && bestEnd == null) {
          bestEnd = ep.timeMs;
        }
        final newCount = activeSourceCounts[id]! - 1;
        if (newCount == 0) {
          activeSourceCounts.remove(id);
        } else {
          activeSourceCounts[id] = newCount;
        }
        overlap--;
      }
    }

    // Gate on unique-source count, not raw overlap depth: minimumQuorum
    // names distinct authorities, so two overlapping samples from one
    // source must not satisfy a quorum of two. bestSourceIdCount is
    // always <= best, making this strictly stronger than `best < ...`.
    if (bestSourceIdCount < minimumQuorum ||
        bestStart == null ||
        bestEnd == null) {
      return null;
    }

    final midMs = (bestStart + bestEnd) ~/ 2;
    final uncertaintyMs = (bestEnd - bestStart) ~/ 2;

    return ConsensusResult(
      utc: DateTime.fromMillisecondsSinceEpoch(midMs, isUtc: true),
      // 1 ms floor prevents downstream divide-by-zero and signals the
      // best-case precision honestly even when intervals coincide exactly.
      uncertaintyMs: max(1, uncertaintyMs),
      participantCount: bestSourceIdCount,
    );
  }
}

enum _EndpointType { lower, upper }

final class _Endpoint {
  const _Endpoint(this.timeMs, this.type, this.sample);

  final int timeMs;
  final _EndpointType type;
  final SourceSample sample;
}
