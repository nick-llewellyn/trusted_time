import 'dart:async';
import 'package:flutter/foundation.dart';
import 'exceptions.dart';
import 'models.dart';
import 'marzullo.dart';
import 'monotonic_clock.dart';
import 'sources/time_sources.dart';

/// Orchestrates parallel queries across multiple time authorities to establish
/// a quorum-based trust anchor.
///
/// The [SyncEngine] builds a list of [TrustedTimeSource] instances from the
/// [TrustedTimeConfig] and queries them concurrently. Valid responses are
/// fed into the [MarzulloEngine] to compute a consensus UTC time with bounded
/// uncertainty.
final class SyncEngine {
  /// Creates a sync engine with the given [config] and [clock].
  ///
  /// Time-source instances are built from the config and the clock is
  /// forwarded to NTS/HTTPS sources so each can pin its monotonic
  /// reference at response receipt.
  SyncEngine({required TrustedTimeConfig config, required MonotonicClock clock})
    : _config = config,
      _engine = MarzulloEngine(minimumQuorum: config.minimumQuorum),
      _sources = [
        for (final host in config.ntsServers) NtsSource(host, clock: clock),
        for (final url in config.httpsSources) HttpsSource(url, clock: clock),
        ...config.additionalSources,
      ];

  /// Test seam: build a SyncEngine with a pre-assembled list of sources.
  /// Bypasses the config-driven source construction so unit tests can
  /// inject [TrustedTimeSource] fakes directly.
  @visibleForTesting
  SyncEngine.withSources({
    required TrustedTimeConfig config,
    required List<TrustedTimeSource> sources,
  }) : _config = config,
       _engine = MarzulloEngine(minimumQuorum: config.minimumQuorum),
       _sources = List.unmodifiable(sources);

  final TrustedTimeConfig _config;
  final MarzulloEngine _engine;
  final List<TrustedTimeSource> _sources;

  /// Executes concurrent sampling and returns a hardware-pinned trust anchor.
  ///
  /// Queries all configured time sources in parallel, filters by maximum
  /// latency, and uses Marzullo's algorithm to find the consensus interval.
  /// Each Marzullo interval is built from the sample's advertised
  /// [TimeSample.uncertainty] — *not* a generic `RTT/2` derivation — so a
  /// custom source with access to tighter bounds (e.g. NTS exposing the
  /// server's stratum and root dispersion) can narrow consensus
  /// accordingly. The anchor's uptime is pinned to the captured monotonic
  /// reference of the lowest-RTT *consensus participant* — the lowest-RTT
  /// sample whose advertised uncertainty interval contained the consensus
  /// midpoint. Filtering on participation (rather than on every eligible
  /// response) keeps a fast outlier whose interval missed the
  /// intersection from winning the reduction, even when another sample
  /// from the same source did participate. Pinning at receipt avoids
  /// drift from a post-aggregation re-sample.
  ///
  /// Throws [TrustedTimeSyncException] if no sources respond or if quorum
  /// cannot be reached.
  Future<TrustAnchor> sync() async {
    final query = await _queryConcurrently();
    final rawSamples = query.eligible;
    if (rawSamples.isEmpty) {
      // No sample survived latency filtering. Four distinct failure
      // modes share this branch and need separate diagnostics so the
      // caller can attribute the cause:
      //
      //   - every source failed outright (no TimeSample, no timeout):
      //     network outage, DNS, refused connection.
      //   - every source returned a sample over the latency budget
      //     (post-hoc filter only): synthetic / instrumented sources,
      //     or sources that don't honour the configured timeout.
      //   - every source was killed by `Future.timeout(maxLatency)`
      //     before producing a sample (timeout only): the common
      //     production case for built-in HTTPS/NTS sources when the
      //     network is slow but reachable.
      //   - mixed: some timed out, some responded over budget.
      //
      // Conflating any of these as "failed to respond" — as the engine
      // did historically — misleads callers about why a sync that was
      // really an over-budget run came up empty.
      if (query.responded == 0 && query.timedOut == 0) {
        throw const TrustedTimeSyncException(
          'Every configured time source failed to respond.',
        );
      }
      final maxLatencyMs = _config.maxLatency.inMilliseconds;
      if (query.responded == 0) {
        // Pure-timeout case.
        final word = query.timedOut == 1 ? 'source' : 'sources';
        throw TrustedTimeSyncException(
          '${query.timedOut} $word timed out after maxLatency='
          '$maxLatencyMs ms.',
        );
      }
      if (query.timedOut == 0) {
        // Pure post-hoc-filter case.
        final word = query.responded == 1 ? 'source' : 'sources';
        throw TrustedTimeSyncException(
          '${query.responded} $word responded but every sample exceeded '
          'maxLatency=$maxLatencyMs ms.',
        );
      }
      // Mixed case: cite both buckets so the caller can attribute the
      // latency cause without parsing free-form prose.
      final total = query.responded + query.timedOut;
      final word = total == 1 ? 'source' : 'sources';
      throw TrustedTimeSyncException(
        '$total $word exceeded maxLatency=$maxLatencyMs ms '
        '(${query.timedOut} timed out, ${query.responded} responded with '
        'RTT > $maxLatencyMs ms).',
      );
    }

    // Reject samples whose source violated either the non-negative RTT
    // or the non-negative uncertainty contract: admitting a violator
    // would (a) inject a negative interval width into the Marzullo
    // sweep and crash it, and (b) win the lowest-RTT reduction below —
    // pinning the anchor's monotonic/wall reference to a sample that
    // never participated in consensus. Filtering once here keeps
    // consensus, anchor selection, and the quorum-failure message in
    // agreement on the eligible sample set. Latency drops and timeouts
    // are accounted for separately via `query.droppedForLatency` and
    // `query.timedOut` so that the quorum-failure message can surface
    // the real cause when some sources were over-budget and some were
    // malformed.
    final samples = rawSamples
        .where((s) => !s.roundTripTime.isNegative && !s.uncertainty.isNegative)
        .toList(growable: false);

    // Build SourceSamples 1:1 with `samples` so that participating
    // SourceSample instances returned by Marzullo can be mapped back
    // to their TimeSamples by parallel index. `uncertaintyMs` is taken
    // from the sample's advertised `TimeSample.uncertainty` rather than
    // the historical RTT/2 derivation, honouring the documented
    // contract that a custom source may report a tighter bound than
    // half the round-trip.
    final marzulloSamples = [
      for (final s in samples)
        SourceSample(
          sourceId: s.source.id,
          utc: s.networkUtc,
          roundTripMs: s.roundTripTime.inMilliseconds,
          uncertaintyMs: s.uncertainty.inMilliseconds,
        ),
    ];

    final result = _engine.resolve(marzulloSamples);
    if (result == null) {
      final eligible = samples.length;
      final invalid = rawSamples.length - eligible;
      final droppedForLatency = query.droppedForLatency;
      final timedOut = query.timedOut;
      final maxLatencyMs = _config.maxLatency.inMilliseconds;
      final eligibleWord = eligible == 1 ? 'sample' : 'samples';
      final notes = <String>[
        if (invalid > 0) '$invalid rejected as invalid',
        if (droppedForLatency > 0)
          '$droppedForLatency dropped for exceeding '
              'maxLatency=$maxLatencyMs ms',
        if (timedOut > 0) '$timedOut timed out at maxLatency=$maxLatencyMs ms',
      ];
      final notesPart = notes.isEmpty ? '' : ' (${notes.join('; ')})';
      throw TrustedTimeSyncException(
        'Quorum not reached: got $eligible eligible $eligibleWord$notesPart, '
        'need ${_config.minimumQuorum} for intersection.',
      );
    }

    // Pin uptime to the lowest-RTT consensus participant — the tightest
    // reference available among samples whose intervals were *inside*
    // the Marzullo intersection, recorded the instant the response was
    // received (not after slower siblings resolved). Filtering on
    // SourceSample identity (rather than `source.id`) is what keeps a
    // fast outlier — a sample whose interval missed the intersection
    // entirely — from winning the lowest-RTT pick, even when another
    // sample from the same source did participate (duplicate config,
    // future burst sampling, etc.). By construction the participant
    // set is non-empty (`minimumQuorum >= 1`) and every participant
    // came from `marzulloSamples`, so the filtered list is non-empty.
    final participantSamples = <TimeSample>[
      for (var i = 0; i < samples.length; i++)
        if (result.participants.contains(marzulloSamples[i])) samples[i],
    ];
    final best = participantSamples.reduce(
      (a, b) => a.roundTripTime <= b.roundTripTime ? a : b,
    );

    return TrustAnchor(
      networkUtcMs: result.utc.millisecondsSinceEpoch,
      uptimeMs: best.capturedMonotonicMs,
      wallMs: best.capturedAt.millisecondsSinceEpoch,
      uncertaintyMs: result.uncertaintyMs,
    );
  }

  /// Releases resources held by time sources (e.g., open HTTP clients).
  void dispose() {
    for (final source in _sources) {
      if (source is HttpsSource) source.dispose();
    }
  }

  /// Queries all sources concurrently and partitions outcomes.
  ///
  /// Returns the latency-eligible samples alongside three diagnostic
  /// counts: how many sources returned a [TimeSample] under the latency
  /// budget (`responded`), how many returned a sample whose RTT exceeded
  /// `maxLatency` (`droppedForLatency`), and how many were killed by the
  /// per-fetch `timeout(maxLatency)` before producing a sample at all
  /// (`timedOut`). All three counts are needed by [sync] to distinguish
  /// the failure modes that otherwise share an empty `eligible` list:
  ///
  /// - everything failed outright (DNS, refused, parse error) → no
  ///   timeouts, no responses.
  /// - everything responded but with RTT > budget → post-hoc filter only.
  /// - everything was killed at the budget by [Future.timeout] → timeout
  ///   only; this is the *common* production case for built-in HTTPS/NTS
  ///   sources and was previously misreported as "failed to respond".
  /// - mixed → both counts non-zero.
  Future<
    ({
      List<TimeSample> eligible,
      int responded,
      int droppedForLatency,
      int timedOut,
    })
  >
  _queryConcurrently() async {
    final outcomes = await Future.wait(_sources.map(_querySafe));
    final maxLatencyMs = _config.maxLatency.inMilliseconds;
    final eligible = <TimeSample>[];
    var responded = 0;
    var droppedForLatency = 0;
    var timedOut = 0;
    for (final outcome in outcomes) {
      final sample = outcome.sample;
      if (sample != null) {
        responded++;
        if (sample.roundTripTime.inMilliseconds <= maxLatencyMs) {
          eligible.add(sample);
        } else {
          droppedForLatency++;
        }
      } else if (outcome.timedOut) {
        timedOut++;
      }
    }
    return (
      eligible: eligible,
      responded: responded,
      droppedForLatency: droppedForLatency,
      timedOut: timedOut,
    );
  }

  /// Wraps a source query in a try-catch with timeout enforcement.
  ///
  /// Returns a record carrying either the sample (if `fetch()` resolved
  /// inside `maxLatency`) or a `timedOut` flag distinguishing the
  /// `TimeoutException` raised by [Future.timeout] from arbitrary other
  /// failures (DNS, refused connection, parse error, etc.). The split
  /// matters for diagnostics: a slow real-world fetch is killed by the
  /// timeout *before* a `TimeSample` is produced, so a generic null
  /// return would leave `_queryConcurrently` unable to distinguish "the
  /// network was too slow for the configured budget" from "every source
  /// failed to respond" — and callers would see the latter when the
  /// real cause was the former.
  Future<({TimeSample? sample, bool timedOut})> _querySafe(
    TrustedTimeSource source,
  ) async {
    try {
      final sample = await source.fetch().timeout(_config.maxLatency);
      return (sample: sample, timedOut: false);
    } on TimeoutException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[TrustedTime] Source ${source.id} exceeded maxLatency='
          '${_config.maxLatency.inMilliseconds} ms: $e',
        );
      }
      return (sample: null, timedOut: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TrustedTime] Source ${source.id} failed: $e');
      }
      return (sample: null, timedOut: false);
    }
  }
}
