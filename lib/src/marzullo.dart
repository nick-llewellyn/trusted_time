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
    required this.participantSourceIds,
  });

  final DateTime utc;
  final int uncertaintyMs;
  final int participantCount;

  /// Source IDs whose intervals were active at the moment of maximum
  /// overlap. Callers pinning a monotonic/wall reference must restrict
  /// themselves to samples from these sources — a fast outlier excluded
  /// from the intersection has nothing to say about consensus UTC.
  final Set<String> participantSourceIds;
}

/// Resolves a single source-of-truth from overlapping confidence intervals
/// using [Marzullo's Algorithm](https://en.wikipedia.org/wiki/Marzullo%27s_algorithm).
final class MarzulloEngine {
  const MarzulloEngine({required this.minimumQuorum});

  final int minimumQuorum;

  ConsensusResult? resolve(List<SourceSample> samples) {
    // Defence in depth: SyncEngine is expected to drop samples whose
    // source reports a negative round-trip time before reaching this
    // method (so anchor selection, error messaging, and consensus all
    // see the same filtered set). The check is repeated here because
    // MarzulloEngine takes SourceSample directly and any future caller
    // that bypasses SyncEngine must not be able to crash the sweep:
    // a negative roundTripMs produces a negative uncertaintyMs which
    // inverts the interval, sorts the upper endpoint before its lower
    // endpoint, and would otherwise hit `activeSourceCounts[id]!` for
    // an id that was never inserted.
    final valid = samples.where((s) => s.roundTripMs >= 0).toList();
    if (valid.length < minimumQuorum) return null;

    final endpoints = <_Endpoint>[];
    for (final s in valid) {
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

    int? bestStart;
    int? bestEnd;

    // Multiset of currently-active source IDs. A plain Set would lose
    // multiplicity if the same source contributes overlapping samples:
    // when one of those samples closes its upper endpoint, set.remove
    // would drop the source even though another of its intervals is
    // still active, under-counting any later best-moment snapshot.
    final activeSourceCounts = <String, int>{};
    // The sweep optimises for the maximum number of *distinct authorities*
    // overlapping at a moment, not raw interval depth. Optimising on raw
    // depth lets one chatty source mask a later window with more unique
    // authorities (e.g. three samples from `a` plus one from `b` would
    // lock in depth=4 and ignore a later [c, d, e] window of depth=3
    // even though the latter is the only one that satisfies quorum=3).
    var bestSourceIdCount = 0;
    // Snapshot of the unique source IDs active when `bestSourceIdCount`
    // was last raised. Captured by value at that moment so that later
    // sweep activity (sources entering and leaving as endpoints close)
    // cannot mutate it. Callers use this set to filter post-consensus
    // anchor candidates — only sources that were inside the intersection
    // get to contribute a monotonic/wall reference.
    var bestParticipants = const <String>{};

    for (final ep in endpoints) {
      final id = ep.sample.sourceId;
      if (ep.type == _EndpointType.lower) {
        activeSourceCounts.update(id, (c) => c + 1, ifAbsent: () => 1);
        final unique = activeSourceCounts.length;
        if (unique > bestSourceIdCount) {
          bestSourceIdCount = unique;
          bestStart = ep.timeMs;
          // The correct closing endpoint for this new best hasn't been
          // encountered yet; clear any prior end-of-window candidate.
          bestEnd = null;
          // Materialise an immutable copy of the active source IDs
          // *now*; subsequent endpoint events will add and remove
          // entries from `activeSourceCounts` and would otherwise
          // corrupt the snapshot.
          bestParticipants = Set.unmodifiable(activeSourceCounts.keys);
        }
      } else {
        final newCount = activeSourceCounts[id]! - 1;
        if (newCount == 0) {
          activeSourceCounts.remove(id);
        } else {
          activeSourceCounts[id] = newCount;
        }
        // Mark the close of the best window the first time the unique
        // source count drops below the running maximum. Checking after
        // the decrement lets a same-source upper endpoint pass without
        // ending the window when another sample from that source is
        // still active.
        if (bestStart != null &&
            bestEnd == null &&
            activeSourceCounts.length < bestSourceIdCount) {
          bestEnd = ep.timeMs;
        }
      }
    }

    if (bestSourceIdCount < minimumQuorum ||
        bestStart == null ||
        bestEnd == null) {
      return null;
    }

    final midMs = (bestStart + bestEnd) ~/ 2;
    final uncertaintyMs = (bestEnd - bestStart) ~/ 2;

    return ConsensusResult(
      utc: DateTime.fromMillisecondsSinceEpoch(midMs, isUtc: true),
      // When all surviving intervals coincide on a single point the raw
      // intersection width is zero, but reporting `uncertaintyMs == 0`
      // would falsely advertise sub-millisecond consensus precision —
      // every clock has read jitter above that, and TrustAnchor exposes
      // uncertaintyMs publicly for callers reasoning about confidence
      // bounds. Floor at 1 ms so the published anchor reflects a
      // realistic best-case bound rather than a meaningless zero.
      uncertaintyMs: max(1, uncertaintyMs),
      participantCount: bestSourceIdCount,
      participantSourceIds: bestParticipants,
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
