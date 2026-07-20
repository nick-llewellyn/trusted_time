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
NtsBurstClient testClient({
  required int Function() nowFn,
  required List<int> rtts,
  required int serverOffsetMicros,
  // Spec the fake client reports as its target. Defaults to a
  // placeholder so the existing engine tests keep their `test.local`
  // host; [testClientFactory] overrides it with the panel-selected
  // `(host, port)` so [BurstResult.host] matches what the dropdown
  // shows in widget tests.
  nts.NtsServerSpec spec = const nts.NtsServerSpec(
    host: 'test.local',
    port: 4460,
  ),
  Random? random,
  Duration? queryDelay,
  void Function()? onIssue,
  void Function()? onComplete,
}) {
  return NtsBurstClient.forTest(
    spec: spec,
    queryFn: (index) async {
      try {
        // onIssue is inside the try so a misbehaving callback (e.g.
        // a test that throws from its in-flight tracker) still hits
        // the finally and runs onComplete, keeping in-flight
        // accounting consistent with what callers observed.
        onIssue?.call();
        if (queryDelay != null) await Future.delayed(queryDelay);
        final rtt = rtts[index];
        if (rtt < 0) {
          throw _FakeQueryError('synthetic failure for issue $index');
        }
        const phases = nts.PhaseTimings(
          dnsMicros: 0,
          connectMicros: 0,
          tlsHandshakeMicros: 0,
          keRecordIoMicros: 0,
        );
        return nts.NtsTimeSample(
          utcUnixMicros: nowFn() + serverOffsetMicros,
          roundTripMicros: rtt,
          serverStratum: 1,
          aeadId: 15,
          freshCookies: 8,
          phaseTimings: phases,
          trustBackend: nts.TrustBackend.platform,
        );
      } finally {
        onComplete?.call();
      }
    },
    nowUtcMicros: nowFn,
    random: random,
  );
}

/// Builds a burst-client factory suitable for injecting into a
/// `BurstProbePanel` widget test via its `clientFactory` seam. Each
/// invocation forwards the panel-selected `(host, port)` into
/// [testClient] so the resulting [NtsBurstClient.forTest] reports the
/// dropdown's host on [BurstResult.host], while the burst behaviour is
/// driven by the same deterministic [rtts] / [serverOffsetMicros]
/// fixtures as the engine unit tests.
///
/// Returns the bare `NtsBurstClient Function(String, int)` rather than
/// the panel's `NtsBurstClientFactory` typedef so this helper — shared
/// with the non-widget engine tests — doesn't drag the Flutter / UI
/// layer into their dependency graph. The closure is still
/// structurally assignable to `clientFactory` at the widget-test
/// call site.
///
/// [onCreate] fires whenever the panel consults the factory: once for a
/// run of consecutive bursts against an unchanged `(host, port)`, and
/// again whenever the target changes (the panel keeps only a single
/// most-recently-used client, so switching away and back re-consults).
/// This lets a test assert that repeated bursts against the same host
/// reuse the cached client rather than rebuilding it each burst.
NtsBurstClient Function(String host, int port) testClientFactory({
  required int Function() nowFn,
  required List<int> rtts,
  required int serverOffsetMicros,
  Random? random,
  Duration? queryDelay,
  void Function()? onIssue,
  void Function()? onComplete,
  void Function(String host, int port)? onCreate,
}) {
  return (host, port) {
    onCreate?.call(host, port);
    return testClient(
      spec: nts.NtsServerSpec(host: host, port: port),
      nowFn: nowFn,
      rtts: rtts,
      serverOffsetMicros: serverOffsetMicros,
      random: random,
      queryDelay: queryDelay,
      onIssue: onIssue,
      onComplete: onComplete,
    );
  };
}

class _FakeQueryError implements Exception {
  _FakeQueryError(this.message);
  final String message;
  @override
  String toString() => 'FakeQueryError: $message';
}
