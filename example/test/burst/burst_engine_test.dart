import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
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
      // Mobile-budget figures derived from the per-query timings.
      // Every send is at the same fixed clock value (the test helper
      // uses a constant nowFn) so firstSend == every sendUtcMicros;
      // lastReceive = sendUtcMicros + max(rtts) = sendUtcMicros +
      // 200_000. Test fixtures use zero PhaseTimings so the DNS /
      // handshake aggregates are all zero — the dedicated
      // 'budget' test below exercises non-zero PhaseTimings.
      expect(result.budget.radioWindowMicros, 200000);
      expect(result.budget.dnsTotalMicros, 0);
      expect(result.budget.dnsLookupCount, 0);
      expect(result.budget.handshakeTotalMicros, 0);
    });

    test('jittered mode: completes within the configured window', () {
      // fake_async virtualises Future.delayed: the burst's per-issue
      // delays consume virtual time only, so the test is decoupled
      // from CI scheduler jitter that previously made a Stopwatch
      // assertion flaky.
      fakeAsync((async) {
        final client = testClient(
          nowFn: _fixedNow(_anchorMicros),
          rtts: List.filled(6, 50000),
          serverOffsetMicros: 0,
          random: Random(0xBEEF), // deterministic jitter
        );

        BurstResult? result;
        client
            .burst(
              sampleCount: 6,
              mode: BurstMode.jittered,
              jitterWindow: const Duration(milliseconds: 100),
            )
            .then((r) => result = r);

        // Advance enough virtual time to cover any per-issue delay
        // bounded by jitterWindow plus the (zero) mocked query
        // duration. 200ms is generous; the burst must complete.
        async.elapse(const Duration(milliseconds: 200));

        expect(result, isNotNull);
        expect(result!.queries, hasLength(6));
        // Pending timers must have all fired — confirms no per-issue
        // delay leaked past the window bound.
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('sequential mode: each query waits for the configured spacing', () {
      // Use fake_async to make the spacing assertion deterministic:
      // the previous Stopwatch lower-bound was vulnerable to CI
      // scheduler skew. Here we drive virtual time forward in
      // tranches to verify that the next query genuinely waits for
      // the configured spacing rather than firing concurrently.
      fakeAsync((async) {
        final client = testClient(
          nowFn: _fixedNow(_anchorMicros),
          rtts: const [10000, 10000, 10000],
          serverOffsetMicros: 0,
        );

        BurstResult? result;
        client
            .burst(
              sampleCount: 3,
              mode: BurstMode.sequential,
              sequentialSpacing: const Duration(milliseconds: 50),
            )
            .then((r) => result = r);

        // After the first synchronous flush only one query has fired
        // (mocked queries are instant) and the engine is awaiting
        // Future.delayed(50ms) before the second issue.
        async.flushMicrotasks();
        expect(result, isNull);

        // Advance 49ms — still under the spacing, second issue must
        // not have fired yet.
        async.elapse(const Duration(milliseconds: 49));
        expect(result, isNull);

        // Advance another 60ms (total 109ms of virtual time, 9ms
        // past the two 50ms spacing tranches the burst needs) so
        // both remaining delays fire and the burst can complete.
        async.elapse(const Duration(milliseconds: 60));

        expect(result, isNotNull);
        expect(result!.queries, hasLength(3));
      });
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
      expect(result.failures.single.error, isA<Exception>());
      // stackTrace must be captured alongside the error so callers
      // can diagnose unexpected programmer errors that would otherwise
      // be silently demoted to "query failures".
      expect(result.failures.single.stackTrace, isNot(StackTrace.empty));
      expect(result.minRttMicros, 60000);
      expect(result.minRttQuery!.rttMicros, 60000);
    });

    test('failures are sorted by issue index regardless of completion order',
        () async {
      // Three failures at indices 0, 2, 4 plus successes at 1, 3.
      // In parallel mode the failure futures may complete in any
      // order; the aggregator must still surface them sorted by
      // index so the BurstResult.failures dartdoc holds.
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: const [-1, 50000, -1, 50000, -1],
        serverOffsetMicros: 0,
      );

      final result = await client.burst(
        sampleCount: 5,
        mode: BurstMode.parallel,
      );

      expect(result.failures, hasLength(3));
      expect(
        result.failures.map((f) => f.index).toList(),
        [0, 2, 4],
      );
    });

    test(
        'budget: aggregates DNS / handshake phase timings from package:nts PhaseTimings',
        () async {
      // Three queries with mixed phase timings: query 0 paid the
      // full KE handshake (DNS + connect + TLS + KE I/O); queries
      // 1 and 2 are cookie-cached (zero handshake phases) — query 1
      // still incurred a fresh DNS lookup (e.g. KE-host TTL expired
      // mid-burst) while query 2 was fully cache-warm.
      final phases = const [
        nts.PhaseTimings(
          dnsMicros: 30000,
          connectMicros: 12000,
          tlsHandshakeMicros: 80000,
          keRecordIoMicros: 20000,
        ),
        nts.PhaseTimings(
          dnsMicros: 5000,
          connectMicros: 0,
          tlsHandshakeMicros: 0,
          keRecordIoMicros: 0,
        ),
        nts.PhaseTimings(
          dnsMicros: 0,
          connectMicros: 0,
          tlsHandshakeMicros: 0,
          keRecordIoMicros: 0,
        ),
      ];
      final client = testClient(
        nowFn: _fixedNow(_anchorMicros),
        rtts: const [50000, 60000, 70000],
        serverOffsetMicros: 0,
        phaseTimings: phases,
      );

      final result = await client.burst(
        sampleCount: 3,
        mode: BurstMode.parallel,
      );

      // dnsTotal sums all dnsMicros (30k + 5k + 0 = 35k); dnsLookups
      // counts queries with non-zero dnsMicros (2). handshakeTotal
      // sums (connect + tls + keRecordIo) across all queries — only
      // query 0 contributes here = 12k + 80k + 20k = 112k.
      expect(result.budget.dnsTotalMicros, 35000);
      expect(result.budget.dnsLookupCount, 2);
      expect(result.budget.handshakeTotalMicros, 112000);
      // radioWindow is bracketed by min(send) and max(send + rtt);
      // all sends are at the same fixed clock value, so it equals
      // max(rtts) = 70000.
      expect(result.budget.radioWindowMicros, 70000);
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
      // Whole-burst failure: no successful queries to derive
      // mobile-budget figures from. Aggregator zero-fills the
      // budget rather than nullable so the panel can render the
      // budget row unconditionally.
      expect(result.budget.radioWindowMicros, 0);
      expect(result.budget.dnsTotalMicros, 0);
      expect(result.budget.dnsLookupCount, 0);
      expect(result.budget.handshakeTotalMicros, 0);
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
