import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;

/// Inter-burst spacing modes; see ADR 0007 §"Open question 1" and the
/// `trusted_time-wy3` design notes.
///
/// The three modes trade wall-clock cost against statistical
/// independence of the per-burst samples:
///
/// - [parallel] fires all `N` queries at `t = 0`. Best wall-clock; risk
///   that all samples experience the same transient buffering.
/// - [jittered] fires over a configurable window (default 200 ms).
///   Slightly worse wall-clock; mostly-independent jitter samples.
/// - [sequential] fires at fixed intervals (default 500 ms). Best
///   independence; worst latency. NTP `iburst` uses 2 s — too slow for
///   the trusted_time mobile-cadence context.
enum BurstMode { parallel, jittered, sequential }

/// One query within a burst, paired with the wall-clock observations
/// the engine needs to compute the consensus offset and per-sample
/// uncertainty.
@immutable
class BurstQueryResult {
  const BurstQueryResult({
    required this.sample,
    required this.sendUtcMicros,
    required this.offsetMicros,
  });

  /// Raw NTS sample as returned by `package:nts`. The protocol-level
  /// fields (`utcUnixMicros`, `roundTripMicros`, `phaseTimings`,
  /// `trustBackend`) are consumed unchanged downstream — this class
  /// adds local-clock timing observations the wrapper layer needs.
  final nts.NtsTimeSample sample;

  /// Local wall-clock microseconds at which the request was issued,
  /// captured immediately before the `package:nts` call. Combined with
  /// [sample]'s `utcUnixMicros` and `roundTripMicros` it yields the
  /// per-sample [offsetMicros] estimate without re-reading the local
  /// clock at receive time.
  final int sendUtcMicros;

  /// Per-sample server-vs-local clock offset in microseconds, with the
  /// symmetric one-way-delay assumption (`offset = (server -
  /// localSend) - roundTrip/2`). Positive offset means the server's
  /// clock is ahead of the local clock.
  final int offsetMicros;

  /// Round-trip in microseconds; alias for [nts.NtsTimeSample.roundTripMicros].
  int get rttMicros => sample.roundTripMicros;
}

/// Aggregated outcome of one [NtsBurstClient.burst] call against a
/// single host.
///
/// Aggregation follows the min-RTT pattern documented in
/// `trusted_time-wy3`: the offset estimate is taken from the
/// minimum-RTT successful query (which has the tightest one-way-delay
/// uncertainty), and the per-source interval width is widened by a
/// jitter floor derived from the spread between min-RTT and
/// median-RTT to avoid over-tightening on a single fortunate sample.
@immutable
class BurstResult {
  const BurstResult({
    required this.host,
    required this.mode,
    required this.queries,
    required this.failures,
    required this.minRttQuery,
    required this.minRttMicros,
    required this.medianRttMicros,
    required this.maxRttMicros,
    required this.aggregatedOffsetMicros,
    required this.aggregatedUncertaintyMicros,
    required this.intraOffsetSpreadMicros,
  });

  /// Source host this burst was directed at (e.g. `time.cloudflare.com`).
  final String host;

  /// Inter-burst spacing mode the burst was issued under.
  final BurstMode mode;

  /// Successful per-query results in the order they completed (not
  /// the order they were issued — parallel mode in particular returns
  /// results in completion order).
  final List<BurstQueryResult> queries;

  /// Per-issue-order index and surfaced error for each failed query.
  /// Empty list when the whole burst succeeded; `queries.length +
  /// failures.length` equals the burst's *issued* sample count, which
  /// is the requested count after the `[1, 8]` clamp applied by
  /// [NtsBurstClient.burst].
  final List<({int index, Object error})> failures;

  /// Minimum-RTT successful query, or `null` if every query failed.
  /// When non-null this is the canonical sample for downstream
  /// consensus admission — its [BurstQueryResult.offsetMicros] is the
  /// burst's [aggregatedOffsetMicros].
  final BurstQueryResult? minRttQuery;

  /// Aggregate RTT statistics across [queries]; all in microseconds.
  /// Zero when [queries] is empty.
  final int minRttMicros;
  final int medianRttMicros;
  final int maxRttMicros;

  /// Burst-level offset estimate. Equal to
  /// `minRttQuery!.offsetMicros` when the burst produced at least one
  /// successful query; `0` (and [aggregatedUncertaintyMicros] flagged
  /// via [minRttQuery] being `null`) when the whole burst failed.
  final int aggregatedOffsetMicros;

  /// Burst-level uncertainty in microseconds, computed as
  /// `min_rtt/2 + jitter_floor` where `jitter_floor = max(0, p50_rtt -
  /// min_rtt) / 2`. This is the per-source interval half-width the
  /// Marzullo step would use if the burst were admitted.
  final int aggregatedUncertaintyMicros;

  /// `max(offsets) - min(offsets)` across [queries] in microseconds.
  /// Useful as an integrity check: a large spread relative to RTT
  /// suggests the server (or the path) drifted within the burst
  /// window and the min-RTT estimate may be over-confident.
  final int intraOffsetSpreadMicros;

  /// Whether the burst yielded any usable estimate.
  bool get hasResult => minRttQuery != null;
}
