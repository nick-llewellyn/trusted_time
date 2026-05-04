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
    final rawSamples = await _queryConcurrently();
    if (rawSamples.isEmpty) {
      throw const TrustedTimeSyncException(
        'Every configured time source failed to respond.',
      );
    }

    // Reject samples whose source returned a negative round-trip time:
    // the documented `TimeSample.roundTripTime` contract is non-negative,
    // and admitting a violator would (a) inject a negative uncertainty
    // into the Marzullo sweep and crash it, and (b) win the lowest-RTT
    // reduction below — pinning the anchor's monotonic/wall reference
    // to a sample that never participated in consensus. Filtering once
    // here keeps consensus, anchor selection, and the quorum-failure
    // message in agreement on the eligible sample set. If every
    // surviving sample is malformed the standard quorum-failure path
    // below reports `0 eligible / N rejected`, which is more accurate
    // than a dedicated message would be (sources dropped for exceeding
    // `maxLatency` are already filtered upstream and never reach here).
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
      final rejected = rawSamples.length - eligible;
      final eligibleWord = eligible == 1 ? 'sample' : 'samples';
      final rejectedNote = rejected > 0
          ? ' ($rejected rejected as invalid)'
          : '';
      throw TrustedTimeSyncException(
        'Quorum not reached: got $eligible eligible $eligibleWord'
        '$rejectedNote, '
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
  Future<List<TimeSample>> _queryConcurrently() async {
    final results = await Future.wait(_sources.map(_querySafe));
    return results
        .whereType<TimeSample>()
        .where(
          (s) =>
              s.roundTripTime.inMilliseconds <=
              _config.maxLatency.inMilliseconds,
        )
        .toList();
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
