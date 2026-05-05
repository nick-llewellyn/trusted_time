import 'dart:math';

import 'package:flutter/foundation.dart';

@immutable
final class SourceSample {
  /// Constructs a sample for the Marzullo sweep.
  ///
  /// All time quantities are in microseconds so that NTS and other
  /// sub-millisecond-resolution sources are honoured directly during
  /// the sweep. Earlier revisions of this engine operated in
  /// milliseconds, which silently truncated an advertised ±200 µs
  /// bound to ±0 ms; combined with millisecond-truncated sample
  /// centres, two samples that disagreed by sub-millisecond margins
  /// could end up sharing a single-point interval at the same
  /// truncated millisecond and falsely overlap. Storing centres and
  /// widths at microsecond resolution closes that gap; the engine's
  /// reported uncertainty is still floored at 1 ms (1000 µs) before
  /// surfacing to public callers, because that is the realistic
  /// best-case bound any wall clock can claim.
  ///
  /// [uncertaintyMicros] defaults to `roundTripMicros ~/ 2` when
  /// omitted, which matches the historical RTT/2 derivation used by
  /// `HttpsSource` and the test fakes. Custom sources (notably NTS,
  /// which has access to the server's stratum + dispersion fields)
  /// may pass a tighter explicit value: `TimeSample.uncertainty` is
  /// plumbed through `SyncEngine` to this parameter so consensus
  /// intervals honour the advertised bound rather than falling back
  /// to a generic round-trip estimate.
  const SourceSample({
    required this.sourceId,
    required this.utc,
    required this.roundTripMicros,
    int? uncertaintyMicros,
  }) : uncertaintyMicros = uncertaintyMicros ?? roundTripMicros ~/ 2;

  final String sourceId;
  final DateTime utc;
  final int roundTripMicros;
  final int uncertaintyMicros;
}

@immutable
final class ConsensusResult {
  const ConsensusResult({
    required this.utc,
    required this.uncertaintyMicros,
    required this.participantCount,
    required this.participants,
  });

  final DateTime utc;

  /// Half-width of the consensus interval in microseconds. Floored at
  /// 1 ms (1000 µs) so the engine never advertises sub-millisecond
  /// consensus precision below realistic wall-clock read jitter.
  /// `SyncEngine` rounds this up to whole milliseconds before storing
  /// it on the public-facing `TrustAnchor.uncertaintyMs`.
  final int uncertaintyMicros;
  final int participantCount;

  /// The specific [SourceSample] instances whose uncertainty interval
  /// `[utc - u, utc + u]` contains the consensus midpoint reported in
  /// [utc]. Computed by interval-containment of that midpoint rather
  /// than by snapshotting the active set at a sweep instant: a same-
  /// source sample whose interval ends mid-window is correctly excluded
  /// here even though its source ID stays in the sweep's active multiset
  /// (because a sibling sample from the same source is still active).
  ///
  /// Callers pinning a monotonic/wall reference must restrict themselves
  /// to *these* samples — a fast outlier excluded from the intersection
  /// has nothing to say about consensus UTC, even when another sample
  /// from the same source did participate. Identifying participants by
  /// source ID alone would re-admit the outlier whenever its source
  /// contributed more than one sample (duplicate config, future burst
  /// sampling, etc.).
  final Set<SourceSample> participants;
}

/// Resolves a single source-of-truth from overlapping confidence intervals
/// using [Marzullo's Algorithm](https://en.wikipedia.org/wiki/Marzullo%27s_algorithm).
final class MarzulloEngine {
  const MarzulloEngine({required this.minimumQuorum});

  final int minimumQuorum;

  ConsensusResult? resolve(List<SourceSample> samples) {
    // Defence in depth: SyncEngine is expected to drop samples whose
    // source reports a negative round-trip time or negative uncertainty
    // before reaching this method (so anchor selection, error messaging,
    // and consensus all see the same filtered set). The check is repeated
    // here because MarzulloEngine takes SourceSample directly and any
    // future caller that bypasses SyncEngine must not be able to crash
    // the sweep: a negative `uncertaintyMicros` inverts the interval,
    // sorts the upper endpoint before its lower endpoint, and would
    // otherwise hit `activeSourceCounts[id]!` for an id that was never
    // inserted. RTT is checked alongside because it survives into
    // anchor selection (lowest-RTT-among-participants) and a negative
    // value there would win unfairly.
    final valid = samples
        .where((s) => s.roundTripMicros >= 0 && s.uncertaintyMicros >= 0)
        .toList();
    if (valid.length < minimumQuorum) return null;

    final endpoints = <_Endpoint>[];
    for (final s in valid) {
      // Microsecond-resolution centre: `millisecondsSinceEpoch` would
      // truncate sub-millisecond offsets between samples, so two
      // genuinely disagreeing centres ~200 µs apart would collide on
      // the same millisecond and falsely overlap once their advertised
      // sub-millisecond uncertainties also truncated to zero. Using
      // `microsecondsSinceEpoch` keeps centres and widths at the same
      // resolution as the inputs the engine receives.
      final center = s.utc.microsecondsSinceEpoch;
      final u = s.uncertaintyMicros;
      endpoints
        ..add(_Endpoint(center - u, _EndpointType.lower, s))
        ..add(_Endpoint(center + u, _EndpointType.upper, s));
    }

    // Sort by time; at equal times, lower endpoints come first so overlap
    // counting uses closed-interval semantics (touching intervals overlap).
    endpoints.sort((a, b) {
      final cmp = a.timeMicros.compareTo(b.timeMicros);
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

    for (final ep in endpoints) {
      final id = ep.sample.sourceId;
      if (ep.type == _EndpointType.lower) {
        activeSourceCounts.update(id, (c) => c + 1, ifAbsent: () => 1);
        final unique = activeSourceCounts.length;
        if (unique > bestSourceIdCount) {
          bestSourceIdCount = unique;
          bestStart = ep.timeMicros;
          // The correct closing endpoint for this new best hasn't been
          // encountered yet; clear any prior end-of-window candidate.
          bestEnd = null;
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
          bestEnd = ep.timeMicros;
        }
      }
    }

    if (bestSourceIdCount < minimumQuorum ||
        bestStart == null ||
        bestEnd == null) {
      return null;
    }

    final midMicros = (bestStart + bestEnd) ~/ 2;
    final uncertaintyMicros = (bestEnd - bestStart) ~/ 2;

    // Identify participants by interval-containment of the consensus
    // midpoint rather than by snapshotting the active set during the
    // sweep. The sweep guarantees a constant *unique-source* count
    // throughout `[bestStart, bestEnd]`, but a same-source sample can
    // enter or leave during the window without changing that count —
    // so an active-set snapshot at `bestStart` could include a sample
    // whose interval ends mid-window (and therefore does not actually
    // contain consensus UTC). Filtering on `|s.utc - midMicros| <=
    // s.uncertaintyMicros` captures exactly the samples whose reported
    // time is consistent with consensus, with no dependence on sweep
    // instant.
    final participants = <SourceSample>{
      for (final s in valid)
        if ((s.utc.microsecondsSinceEpoch - midMicros).abs() <=
            s.uncertaintyMicros)
          s,
    };

    return ConsensusResult(
      utc: DateTime.fromMicrosecondsSinceEpoch(midMicros, isUtc: true),
      // Floor at 1 ms (1000 µs). The raw `uncertaintyMicros` above is
      // `(bestEnd - bestStart) ~/ 2`, which can collapse to zero (or
      // any sub-millisecond value) for tightly agreeing samples.
      // `TrustAnchor.uncertaintyMs` is rounded up from this value
      // before being surfaced to public callers, and consumers reason
      // about confidence bounds against it; a value below 1 ms would
      // falsely advertise sub-millisecond consensus precision below
      // any real clock's read jitter. The floor produces a realistic
      // best-case bound for any sub-2 ms window rather than a
      // meaningless zero, and is applied here (not at the SyncEngine
      // boundary) so direct callers of MarzulloEngine see the same
      // floor behaviour as the production wiring.
      uncertaintyMicros: max(1000, uncertaintyMicros),
      participantCount: bestSourceIdCount,
      participants: Set.unmodifiable(participants),
    );
  }
}

enum _EndpointType { lower, upper }

final class _Endpoint {
  const _Endpoint(this.timeMicros, this.type, this.sample);

  final int timeMicros;
  final _EndpointType type;
  final SourceSample sample;
}
