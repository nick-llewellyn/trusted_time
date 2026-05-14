import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_example/burst/burst_types.dart';

import 'burst_test_helpers.dart';

void main() {
  group('NtsBurstClient.burst', () {
    test('parallel mode: aggregates min-RTT and computes jitter floor',
        () async {
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        // RTTs (in micros) for issues 0..3: 100k, 50k, 200k, 80k.
        // Median = (80+100)/2 = 90; min = 50; jitter = (90-50)/2 = 20.
        // Aggregated uncertainty = 50/2 + 20 = 45 (micros).
        rtts: const [100000, 50000, 200000, 80000],
        // All servers report the same UTC at 't = sendUtc + 1 second'.
        serverOffsetMicros: 1000000,
      );

      final result = await client.burst(
        sampleCount: 4,
        mode: BurstMode.parallel,
      );

      expect(result.queries, hasLength(4));
      expect(result.failures, isEmpty);
      expect(result.minRttMicros, 50000);
      expect(result.medianRttMicros, 90000);
      expect(result.maxRttMicros, 200000);
      expect(result.aggregatedUncertaintyMicros, 45000);
      expect(result.minRttQuery!.rttMicros, 50000);
      // Per-sample offset = (server - localSend) - rtt/2; with all
      // server timestamps fixed at +1_000_000us, the offset varies
      // only with rtt/2. min-RTT sample (rtt=50k) -> offset =
      // 1_000_000 - 25_000 = 975_000.
      expect(result.aggregatedOffsetMicros, 975000);
    });

    test('jittered mode: completes within the configured window', () async {
      final stopwatch = Stopwatch()..start();
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: List.filled(6, 50000),
        serverOffsetMicros: 0,
        random: Random(0xBEEF), // deterministic jitter
      );

      final result = await client.burst(
        sampleCount: 6,
        mode: BurstMode.jittered,
        jitterWindow: const Duration(milliseconds: 100),
      );
      stopwatch.stop();

      expect(result.queries, hasLength(6));
      // Jitter window bounds the maximum issue delay; mocked queries
      // are instant so the whole burst completes within (window +
      // generous slack for the await scheduler).
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });

    test('sequential mode: each query waits for the configured spacing',
        () async {
      final stopwatch = Stopwatch()..start();
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: const [10000, 10000, 10000],
        serverOffsetMicros: 0,
      );

      final result = await client.burst(
        sampleCount: 3,
        mode: BurstMode.sequential,
        sequentialSpacing: const Duration(milliseconds: 50),
      );

      stopwatch.stop();
      expect(result.queries, hasLength(3));
      // 3 queries with 50ms spacing -> last issue starts at +100ms,
      // plus the (mocked, instant) query itself. Expect at least
      // ~100ms of wall-clock; allow generous slack for slow CI.
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(95));
    });

    test('partial failures: aggregates over successes; failures preserved',
        () async {
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        // index 1 fails; indices 0, 2, 3 succeed with RTTs below.
        rtts: const [100000, -1, 60000, 90000],
        serverOffsetMicros: 500000,
      );

      final result = await client.burst(
        sampleCount: 4,
        mode: BurstMode.parallel,
      );

      expect(result.queries, hasLength(3));
      expect(result.failures, hasLength(1));
      expect(result.failures.single.index, 1);
      expect(result.minRttMicros, 60000);
      expect(result.minRttQuery!.rttMicros, 60000);
    });

    test('whole-burst failure: returns hasResult=false with empty stats',
        () async {
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: const [-1, -1, -1],
        serverOffsetMicros: 0,
      );

      final result = await client.burst(
        sampleCount: 3,
        mode: BurstMode.parallel,
      );

      expect(result.hasResult, isFalse);
      expect(result.queries, isEmpty);
      expect(result.failures, hasLength(3));
      expect(result.minRttMicros, 0);
      expect(result.aggregatedOffsetMicros, 0);
      expect(result.aggregatedUncertaintyMicros, 0);
    });

    test('sampleCount is clamped to [1, 8]', () async {
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: List.filled(20, 50000),
        serverOffsetMicros: 0,
      );

      final tooMany = await client.burst(
        sampleCount: 20,
        mode: BurstMode.parallel,
      );
      expect(tooMany.queries, hasLength(8));

      final tooFew = await client.burst(
        sampleCount: 0,
        mode: BurstMode.parallel,
      );
      expect(tooFew.queries, hasLength(1));
    });

    test('rejects negative or oversized jitterWindow / sequentialSpacing',
        () async {
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: const [50000],
        serverOffsetMicros: 0,
      );

      expect(
        () => client.burst(
          sampleCount: 1,
          mode: BurstMode.jittered,
          jitterWindow: const Duration(microseconds: -1),
        ),
        throwsArgumentError,
      );
      expect(
        () => client.burst(
          sampleCount: 1,
          mode: BurstMode.sequential,
          sequentialSpacing: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
      expect(
        () => client.burst(
          sampleCount: 1,
          mode: BurstMode.jittered,
          jitterWindow: const Duration(minutes: 75),
        ),
        throwsArgumentError,
      );
    });

    test(
        'sequential mode actually serializes — second query waits for first to complete',
        () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: const [50000, 50000, 50000],
        serverOffsetMicros: 0,
        // Fake query that takes 100ms wall-clock per call so a buggy
        // sequential mode (pre-scheduled Future.delayed) would let
        // the next query fire 50ms before the previous completes.
        queryDelay: const Duration(milliseconds: 100),
        onIssue: () {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
        },
        onComplete: () => inFlight--,
      );

      await client.burst(
        sampleCount: 3,
        mode: BurstMode.sequential,
        sequentialSpacing: const Duration(milliseconds: 50),
      );

      expect(maxInFlight, 1, reason: 'sequential mode must serialize');
    });
  });
}

// Arbitrary fixed UTC anchor for the deterministic clock. Written
// without digit separators because `example/pubspec.yaml`'s SDK
// constraint is `>=3.4.0 <4.0.0`; numeric digit separators are a
// Dart 3.6 language feature, so the analyzer rejects them whenever
// the lower bound predates 3.6 (verified: an earlier draft of this
// file used `1_700_000_000_000_000` and `flutter analyze` failed
// with `experiment_not_enabled`). Bumping the lower bound to >=3.6.0
// would let the separator form back in.
const int _anchorMicros = 1700000000000000;

int Function() _fixedNow(int micros) => () => micros;
