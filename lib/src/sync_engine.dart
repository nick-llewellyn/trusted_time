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
  /// The anchor's uptime is pinned to the lowest-RTT sample's captured
  /// monotonic reference, avoiding drift from a post-aggregation re-sample.
  ///
  /// Throws [TrustedTimeSyncException] if no sources respond or if quorum
  /// cannot be reached.
  Future<TrustAnchor> sync() async {
    final samples = await _queryConcurrently();
    if (samples.isEmpty) {
      throw const TrustedTimeSyncException(
        'Every configured time source failed to respond.',
      );
    }

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
      throw TrustedTimeSyncException(
        'Quorum not reached: got ${samples.length} samples, '
        'need ${_config.minimumQuorum} for intersection.',
      );
    }

    // Pin uptime to the lowest-RTT sample's captured monotonic — this is
    // the tightest reference available, recorded the instant its response
    // was received (not after slower siblings resolved).
    final best = samples.reduce(
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
