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
/// - [sequential] issues one query at a time and waits at least
///   `sequentialSpacing` (default 500 ms) after each query completes
///   before issuing the next, so wall-clock spacing is
///   `sequentialSpacing + per_query_latency` rather than fixed.
///   Best independence; worst latency. NTP `iburst` uses 2 s — too
///   slow for the trusted_time mobile-cadence context.
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
    required this.budget,
  });

  /// Source host this burst was directed at (e.g. `time.cloudflare.com`).
  final String host;

  /// Inter-burst spacing mode the burst was issued under.
  final BurstMode mode;

  /// Successful per-query results in the order they completed (not
  /// the order they were issued — parallel mode in particular returns
  /// results in completion order).
  final List<BurstQueryResult> queries;

  /// Failed queries, sorted by issue index so the list order matches
  /// the order the queries were issued (regardless of which mode
  /// completed them in which order — parallel/jittered modes append
  /// failures in completion order; the aggregator re-sorts before
  /// surfacing). Empty list when the whole burst succeeded;
  /// `queries.length + failures.length` equals the burst's *issued*
  /// sample count, which is the requested count after the `[1, 8]`
  /// clamp applied by [NtsBurstClient.burst].
  ///
  /// Each [BurstFailure] carries the issue [BurstFailure.index],
  /// the surfaced [BurstFailure.error], and the
  /// [BurstFailure.stackTrace] from the per-query `try`/`catch` so
  /// failures remain debuggable. `StackTrace.empty` is possible for
  /// synchronous non-`Error` throws but in practice every NTS-side
  /// failure produces a real stack.
  final List<BurstFailure> failures;

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

  /// Mobile-budget breakdown derived from the per-query
  /// [BurstQueryResult.sample] phase timings; see [BurstBudget].
  /// Always populated, even when the whole burst failed (in which
  /// case all fields are zero).
  final BurstBudget budget;

  /// Whether the burst yielded any usable estimate.
  bool get hasResult => minRttQuery != null;
}

/// Per-issue failure record carried in [BurstResult.failures].
///
/// Captures the issue-order [index], the surfaced [error], and the
/// [stackTrace] from the `try`/`catch` so failures remain debuggable
/// (especially for unexpected programmer errors that would otherwise
/// be silently demoted to "query failures").
typedef BurstFailure = ({int index, Object error, StackTrace stackTrace});

/// Mobile-budget breakdown derived from the per-query phase timings
/// surfaced by `package:nts` ([nts.PhaseTimings] on each
/// [nts.NtsTimeSample]) plus the per-query send / RTT timings the
/// engine already records. Carried on [BurstResult.budget].
///
/// Shapes the empirical numbers wy3 needs to retire the
/// "burst-on-establish" educated guess in ADRs 0006/0007/0008 with
/// observed ground truth (per the wy3 ticket: "12-18 hosts,
/// cold-start <3s, battery <1%/day"). See `trusted_time-wy3`.
///
/// All timing fields are microseconds; [dnsLookupCount] is a unitless
/// count. Every field is zero on a whole-burst failure (no successful
/// queries to derive timings from); see [BurstResult.budget].
///
/// CPU time on the orchestrating isolate is intentionally not
/// included here; that's tracked separately under
/// `trusted_time-8re` because it requires native method-channel
/// plumbing on each platform.
typedef BurstBudget = ({
  /// Wall-clock window the radio was active for the burst, computed
  /// as `max(sendUtcMicros + roundTripMicros) - min(sendUtcMicros)`
  /// across successful queries. Approximates the cost the burst
  /// imposes on the cellular / Wi-Fi radio (which dominates mobile
  /// energy use under typical idle baselines). For a parallel mode
  /// burst this is roughly `maxRttMicros`; for sequential mode it
  /// is roughly `(N-1) * sequentialSpacing + sum(rtts)`.
  int radioWindowMicros,

  /// Sum of [nts.PhaseTimings.dnsMicros] across successful queries.
  /// Zero on a fully cache-warm burst; non-zero whenever any query
  /// in the burst incurred a fresh DNS resolution (KE-host or
  /// NTPv4-host lookup) per the package:nts dartdoc on dnsMicros.
  int dnsTotalMicros,

  /// Number of successful queries that incurred a non-zero DNS
  /// lookup phase. Caller can derive a cache-hit ratio as
  /// `(queries.length - dnsLookupCount) / queries.length` *only
  /// when [BurstResult.queries] is non-empty*; on a whole-burst
  /// failure both counts are zero (see [BurstResult.budget]) and
  /// the ratio is undefined. A burst against a cookie-cached
  /// client should observe 0 here.
  int dnsLookupCount,

  /// Sum of all KE-pipeline phase timings
  /// ([nts.PhaseTimings.connectMicros] + `tlsHandshakeMicros` +
  /// `keRecordIoMicros`) across successful queries. Expected to be
  /// 0 for the second-and-later bursts against a cookie-cached
  /// client; a non-zero handshake total on a repeat burst means
  /// the engine paid the full TLS+KE round trip again, which
  /// invalidates the burst's RTT measurements as a steady-state
  /// proxy.
  int handshakeTotalMicros,
});
