import 'dart:math';

import 'package:nts/nts.dart' as nts;
import 'package:trusted_time_example/burst/burst_engine.dart';

/// Constructs an [NtsBurstClient] in test mode whose query callback
/// returns a deterministic [nts.NtsTimeSample] for each issue index.
///
/// `rtts[i]` controls the round-trip-time for the `i`th query:
/// - positive values produce a successful sample with that RTT
/// - `-1` (or any negative value) makes the query throw a synthetic
///   `_FakeQueryError` so the burst's failure path is exercised
///
/// All samples report `serverUtc = nowFn() + serverOffsetMicros` so
/// the per-sample offset reduces to a function of [serverOffsetMicros]
/// and the sample's RTT (`offset = serverOffset - rtt/2`).
NtsBurstClient _testClient({
  required int Function() nowFn,
  required List<int> rtts,
  required int serverOffsetMicros,
  Random? random,
}) {
  return NtsBurstClient.forTest(
    host: 'test.local',
    spec: const nts.NtsServerSpec(host: 'test.local', port: 4460),
    queryFn: (index) async {
      final rtt = rtts[index];
      if (rtt < 0) {
        throw _FakeQueryError('synthetic failure for issue $index');
      }
      return nts.NtsTimeSample(
        utcUnixMicros: nowFn() + serverOffsetMicros,
        roundTripMicros: rtt,
        serverStratum: 1,
        aeadId: 15,
        freshCookies: 8,
        phaseTimings: const nts.PhaseTimings(
          dnsMicros: 0,
          connectMicros: 0,
          tlsHandshakeMicros: 0,
          keRecordIoMicros: 0,
        ),
        trustBackend: nts.TrustBackend.platform,
      );
    },
    nowUtcMicros: nowFn,
    random: random,
  );
}

/// Re-exported so the test file can address the helper without an
/// extra import path.
NtsBurstClient testClient({
  required int Function() nowFn,
  required List<int> rtts,
  required int serverOffsetMicros,
  Random? random,
}) =>
    _testClient(
      nowFn: nowFn,
      rtts: rtts,
      serverOffsetMicros: serverOffsetMicros,
      random: random,
    );

class _FakeQueryError implements Exception {
  _FakeQueryError(this.message);
  final String message;
  @override
  String toString() => 'FakeQueryError: $message';
}
