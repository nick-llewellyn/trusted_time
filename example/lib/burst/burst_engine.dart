import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;

import 'burst_aggregation.dart';
import 'burst_types.dart';

/// Per-host NTS burst client. Fires `N` queries against a single
/// [host] using the supplied query callback, captures wall-clock
/// timings, and aggregates via min-RTT.
///
/// This class is example/-only instrumentation per the
/// `trusted_time-wy3` ticket scope; library-side burst APIs are
/// deferred until the measured numbers from [burst] justify them.
///
/// Tests inject a deterministic [_queryFn] so the algorithm can be
/// exercised without a real NTS-KE handshake; production callers
/// should construct one with the default factory which delegates to
/// [nts.NtsClient.query].
class NtsBurstClient {
  /// Production constructor. Mints a long-lived [nts.NtsClient] so
  /// cookies and the AEAD-NTPv4 session persist across queries within
  /// the same burst — bursts after the first issued against this
  /// client never repeat the NTS-KE handshake.
  NtsBurstClient({
    required this.host,
    required this.spec,
    nts.NtsClient? client,
    Random? random,
  })  : _client = client ?? nts.NtsClient(),
        _random = random ?? Random(),
        _queryFn = null,
        _nowUtcMicros = defaultNowUtcMicros;

  /// Test constructor. Bypasses the real `package:nts` client by
  /// taking an injectable [_queryFn] and an injectable [_nowUtcMicros]
  /// clock so unit tests can assert on the aggregation logic against
  /// hand-rolled fixtures.
  @visibleForTesting
  NtsBurstClient.forTest({
    required this.host,
    required this.spec,
    required Future<nts.NtsTimeSample> Function(int issueIndex) queryFn,
    required int Function() nowUtcMicros,
    Random? random,
  })  : _client = null,
        _random = random ?? Random(),
        _queryFn = queryFn,
        _nowUtcMicros = nowUtcMicros;

  /// Source hostname this client targets (e.g. `time.cloudflare.com`).
  final String host;

  /// Server connection spec passed unchanged to `package:nts` on every
  /// query.
  final nts.NtsServerSpec spec;

  final nts.NtsClient? _client;
  final Future<nts.NtsTimeSample> Function(int issueIndex)? _queryFn;
  final int Function() _nowUtcMicros;
  final Random _random;

  /// Fires [sampleCount] queries under the given [mode] and returns
  /// the aggregated [BurstResult].
  ///
  /// `sampleCount` is clamped to `[1, 8]` per the wy3 etiquette
  /// envelope. `jitterWindow` and `sequentialSpacing` only apply to
  /// their respective modes; the unused parameter is ignored.
  ///
  /// Returns even when every query fails — inspect
  /// [BurstResult.hasResult] to distinguish a successful aggregation
  /// from a whole-burst failure.
  Future<BurstResult> burst({
    required int sampleCount,
    BurstMode mode = BurstMode.parallel,
    Duration jitterWindow = const Duration(milliseconds: 200),
    Duration sequentialSpacing = const Duration(milliseconds: 500),
    int timeoutMs = nts.kDefaultTimeoutMs,
  }) async {
    final effectiveCount = sampleCount.clamp(1, 8);
    final issueDelays = _planIssueDelays(
      effectiveCount,
      mode,
      jitterWindow,
      sequentialSpacing,
    );

    final results = <BurstQueryResult>[];
    final failures = <({int index, Object error})>[];

    final futures = <Future<void>>[];
    for (var i = 0; i < effectiveCount; i++) {
      final idx = i;
      futures.add(
        Future.delayed(issueDelays[idx], () async {
          final sendUtcMicros = _nowUtcMicros();
          try {
            final sample = await _runQuery(idx, timeoutMs);
            results.add(_buildQueryResult(sample, sendUtcMicros));
          } catch (err) {
            failures.add((index: idx, error: err));
          }
        }),
      );
    }
    await Future.wait(futures);

    return aggregateBurst(
      host: host,
      mode: mode,
      completed: results,
      failures: failures,
    );
  }

  Future<nts.NtsTimeSample> _runQuery(int issueIndex, int timeoutMs) {
    final fn = _queryFn;
    if (fn != null) return fn(issueIndex);
    return _client!.query(spec: spec, timeoutMs: timeoutMs);
  }

  BurstQueryResult _buildQueryResult(
    nts.NtsTimeSample sample,
    int sendUtcMicros,
  ) {
    final offsetMicros =
        (sample.utcUnixMicros - sendUtcMicros) - sample.roundTripMicros ~/ 2;
    return BurstQueryResult(
      sample: sample,
      sendUtcMicros: sendUtcMicros,
      offsetMicros: offsetMicros,
    );
  }

  List<Duration> _planIssueDelays(
    int count,
    BurstMode mode,
    Duration jitterWindow,
    Duration sequentialSpacing,
  ) {
    switch (mode) {
      case BurstMode.parallel:
        return List.filled(count, Duration.zero);
      case BurstMode.jittered:
        final windowUs = jitterWindow.inMicroseconds;
        return [
          for (var i = 0; i < count; i++)
            Duration(microseconds: _random.nextInt(windowUs + 1)),
        ];
      case BurstMode.sequential:
        return [for (var i = 0; i < count; i++) sequentialSpacing * i];
    }
  }
}
