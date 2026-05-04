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
  /// The anchor's uptime is pinned to the captured monotonic reference of
  /// the lowest-RTT *consensus participant* — the lowest-RTT sample whose
  /// uncertainty interval contained the consensus midpoint. Filtering on
  /// participation (rather than on every eligible response) keeps a fast
  /// outlier whose interval missed the intersection from winning the
  /// reduction, even when another sample from the same source did
  /// participate. Pinning at receipt avoids drift from a post-aggregation
  /// re-sample.
  ///
  /// Throws [TrustedTimeSyncException] if no sources respond or if quorum
  /// cannot be reached.
  Future<TrustAnchor> sync() async {
    final query = await _queryConcurrently();
    final rawSamples = query.eligible;
    if (rawSamples.isEmpty) {
      // No sample survived latency filtering. Two distinct failure
      // modes share this branch and need different diagnostics: every
      // source genuinely failed to respond (network down, all hosts
      // unreachable), or every responding source returned a sample
      // whose RTT exceeded `maxLatency` (network up but congested,
      // or `maxLatency` set too tight). Conflating the two as "failed
      // to respond" hides the real cause from callers.
      if (query.responded == 0) {
        throw const TrustedTimeSyncException(
          'Every configured time source failed to respond.',
        );
      }
      final word = query.responded == 1 ? 'source' : 'sources';
      throw TrustedTimeSyncException(
        '${query.responded} $word responded but every sample exceeded '
        'maxLatency=${_config.maxLatency.inMilliseconds} ms.',
      );
    }

    // Reject samples whose source returned a negative round-trip time:
    // the documented `TimeSample.roundTripTime` contract is non-negative,
    // and admitting a violator would (a) inject a negative uncertainty
    // into the Marzullo sweep and crash it, and (b) win the lowest-RTT
    // reduction below — pinning the anchor's monotonic/wall reference
    // to a sample that never participated in consensus. Filtering once
    // here keeps consensus, anchor selection, and the quorum-failure
    // message in agreement on the eligible sample set. Latency drops
    // are accounted for separately via `query.droppedForLatency` so
    // that the quorum-failure message can surface the real cause when
    // some sources were too late and some were malformed.
    final samples = rawSamples
        .where((s) => !s.roundTripTime.isNegative)
        .toList(growable: false);

    // Build SourceSamples 1:1 with `samples` so that participating
    // SourceSample instances returned by Marzullo can be mapped back
    // to their TimeSamples by parallel index.
    final marzulloSamples = [
      for (final s in samples)
        SourceSample(
          sourceId: s.source.id,
          utc: s.networkUtc,
          roundTripMs: s.roundTripTime.inMilliseconds,
        ),
    ];

    final result = _engine.resolve(marzulloSamples);
    if (result == null) {
      final eligible = samples.length;
      final invalid = rawSamples.length - eligible;
      final droppedForLatency = query.droppedForLatency;
      final eligibleWord = eligible == 1 ? 'sample' : 'samples';
      final notes = <String>[
        if (invalid > 0) '$invalid rejected as invalid',
        if (droppedForLatency > 0)
          '$droppedForLatency dropped for exceeding '
              'maxLatency=${_config.maxLatency.inMilliseconds} ms',
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

  /// Queries all sources concurrently and filters by max latency.
  ///
  /// Returns the latency-eligible samples alongside two diagnostic
  /// counts: how many sources actually returned a [TimeSample]
  /// (regardless of latency), and how many of those responses were
  /// dropped for exceeding [TrustedTimeConfig.maxLatency]. Both counts
  /// are needed by [sync] to distinguish "no source responded" from
  /// "every source responded but every sample was too late" — the two
  /// failure modes share an empty `eligible` list but warrant
  /// different diagnostics.
  Future<({List<TimeSample> eligible, int responded, int droppedForLatency})>
  _queryConcurrently() async {
    final results = await Future.wait(_sources.map(_querySafe));
    final responses = results.whereType<TimeSample>().toList(growable: false);
    final maxLatencyMs = _config.maxLatency.inMilliseconds;
    final eligible = <TimeSample>[];
    var droppedForLatency = 0;
    for (final s in responses) {
      if (s.roundTripTime.inMilliseconds <= maxLatencyMs) {
        eligible.add(s);
      } else {
        droppedForLatency++;
      }
    }
    return (
      eligible: eligible,
      responded: responses.length,
      droppedForLatency: droppedForLatency,
    );
  }

  /// Wraps a source query in a try-catch with timeout enforcement.
  ///
  /// Returns `null` on failure to allow graceful degradation.
  Future<TimeSample?> _querySafe(TrustedTimeSource source) async {
    try {
      return await source.fetch().timeout(_config.maxLatency);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TrustedTime] Source ${source.id} failed: $e');
      }
      return null;
    }
  }
}
