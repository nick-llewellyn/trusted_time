import 'dart:math' as math;

import 'burst_types.dart';

/// Aggregates a set of completed [BurstQueryResult]s and the
/// per-query [failures] (in arbitrary completion order) into a
/// [BurstResult]. Failures are sorted by issue index before being
/// stored so callers see them in the same order the queries were
/// issued, matching the documented "per-issue-order" contract of
/// [BurstResult.failures].
///
/// Pure function on its inputs; extracted from [NtsBurstClient] so
/// the min-RTT / median-RTT / jitter-floor reductions can be unit
/// tested without mocking the burst issue path.
BurstResult aggregateBurst({
  required String host,
  required BurstMode mode,
  required List<BurstQueryResult> completed,
  required List<BurstFailure> failures,
}) {
  // Sort by issue index so the public list order matches the
  // documented "per-issue-order" contract of BurstResult.failures
  // regardless of which mode (parallel/jittered/sequential) issued
  // the queries. Copy first to keep this function pure on its inputs.
  final sortedFailures = [...failures]
    ..sort((a, b) => a.index.compareTo(b.index));

  if (completed.isEmpty) {
    return BurstResult(
      host: host,
      mode: mode,
      queries: const [],
      failures: List.unmodifiable(sortedFailures),
      minRttQuery: null,
      minRttMicros: 0,
      medianRttMicros: 0,
      maxRttMicros: 0,
      aggregatedOffsetMicros: 0,
      aggregatedUncertaintyMicros: 0,
      intraOffsetSpreadMicros: 0,
    );
  }

  final rtts = [for (final q in completed) q.rttMicros]..sort();
  final offsets = [for (final q in completed) q.offsetMicros]..sort();
  final minRtt = rtts.first;
  final maxRtt = rtts.last;
  final medianRtt = _median(rtts);
  final minRttQuery = completed.reduce(
    (a, b) => a.rttMicros <= b.rttMicros ? a : b,
  );

  // jitter_floor = max(0, p50_rtt - min_rtt) / 2; widens the per-source
  // uncertainty so a single fortunate sample cannot collapse the
  // interval below what the burst's RTT spread justifies. medianRtt
  // and minRtt are both microsecond counts derived from RTTs of
  // burst-bounded queries (≤ 8 successful samples, each well under
  // the practical jitter envelope), so no upper-bound clamp is
  // needed — math.max guards only the negative branch.
  final jitterFloor = math.max(0, medianRtt - minRtt) ~/ 2;
  final uncertainty = minRtt ~/ 2 + jitterFloor;

  final spread = offsets.last - offsets.first;

  return BurstResult(
    host: host,
    mode: mode,
    queries: List.unmodifiable(completed),
    failures: List.unmodifiable(sortedFailures),
    minRttQuery: minRttQuery,
    minRttMicros: minRtt,
    medianRttMicros: medianRtt,
    maxRttMicros: maxRtt,
    aggregatedOffsetMicros: minRttQuery.offsetMicros,
    aggregatedUncertaintyMicros: uncertainty,
    intraOffsetSpreadMicros: spread,
  );
}

/// Median of a non-empty, ascending-sorted list of integers.
/// Even-length lists return the truncated arithmetic mean of the two
/// middle elements (`(a + b) ~/ 2`) so the return type stays integer
/// and the value is bounded by the actual sample distribution.
int _median(List<int> sorted) {
  final n = sorted.length;
  if (n.isOdd) return sorted[n ~/ 2];
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) ~/ 2;
}

/// Default wall-clock source: microseconds since the Unix epoch from
/// `DateTime.now()`. Production [NtsBurstClient] uses this; tests
/// inject a deterministic clock instead.
///
/// `microsecondsSinceEpoch` is an absolute Unix-epoch count and is
/// therefore unaffected by the [DateTime]'s timezone, so no `.toUtc()`
/// conversion is necessary — adding one would allocate an extra
/// [DateTime] per call without changing the returned value.
int defaultNowUtcMicros() => DateTime.now().microsecondsSinceEpoch;
