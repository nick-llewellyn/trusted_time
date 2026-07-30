import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';
import 'support/fake_observers.dart';
import 'support/fake_sources.dart';

/// Test source with an explicitly-controlled [TimeInterval] so the
/// stability-guard tests can construct samples whose midpoint deviates
/// from the consensus midpoint by more than the variance threshold,
/// or whose width drives mid-stream divergence in the resolved
/// interval as more samples accumulate.
class WideIntervalSource implements TimeSource {
  WideIntervalSource(
    this.id,
    this.delay,
    this.startMs,
    this.endMs, [
    this.groupId = 'test-group',
  ]);
  @override
  final String id;
  final Duration delay;
  final int startMs;
  final int endMs;
  @override
  final String groupId;

  @override
  Future<TimeSample> getTime() async {
    await Future.delayed(delay);
    return TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: groupId,
    );
  }
}

void main() {
  group('SyncEngine Concurrency & Race Conditions', () {
    late TrustedTimeConfig config;
    late FakeMonotonicClock clock;

    setUp(() {
      clock = FakeMonotonicClock();
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1, // Relax for tests
        disableNtpForTesting: true,
      );
    });

    test(
      'resolves correctly when multiple sources respond in the same microtask',
      () async {
        final source1 = RaceConditionSource(
          's1',
          const Duration(milliseconds: 50),
          1000000,
          'g1',
        );
        final source2 = RaceConditionSource(
          's2',
          const Duration(milliseconds: 50),
          1000000,
          'g2',
        );
        final source3 = RaceConditionSource(
          's3',
          const Duration(milliseconds: 50),
          1000000,
          'g3',
        );

        final engine = SyncEngine(
          config: config.copyWith(
            additionalSources: [source1, source2, source3],
          ),
          clock: clock,
        );

        final anchor = await engine.sync();
        expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000020));
      },
    );

    test(
      'handles stream closure during late query completion without StateError',
      () async {
        final source1 = RaceConditionSource(
          's1',
          const Duration(milliseconds: 10),
          1000000,
          'g1',
        );
        final source2 = RaceConditionSource(
          's2',
          const Duration(milliseconds: 20),
          1000000,
          'g2',
        );
        final source3 = RaceConditionSource(
          's3',
          const Duration(milliseconds: 100),
          1000000,
          'g3',
        );

        final engine = SyncEngine(
          config: config.copyWith(
            minimumQuorum: 2,
            earlyExit: true,
            additionalSources: [source1, source2, source3],
          ),
          clock: clock,
        );

        final anchor = await engine.sync();
        expect(anchor.networkUtcMs, 1000000);

        await Future.delayed(const Duration(milliseconds: 150));
      },
    );

    test(
      'outlier filtering is deterministic across simultaneous arrivals',
      () async {
        // 4 sources to ensure stableCount >= 2 after filtering 1 outlier
        final s1 = RaceConditionSource(
          's1',
          const Duration(milliseconds: 50),
          1000000,
          'g1',
        );
        final s2 = RaceConditionSource(
          's2',
          const Duration(milliseconds: 50),
          1000002,
          'g2',
        );
        final s3 = RaceConditionSource(
          's3',
          const Duration(milliseconds: 50),
          1000001,
          'g3',
        );
        final s4 = RaceConditionSource(
          's4',
          const Duration(milliseconds: 50),
          2000000,
          'g4',
        );

        final engine = SyncEngine(
          config: config.copyWith(
            minimumQuorum: 2,
            additionalSources: [s1, s2, s3, s4],
          ),
          clock: clock,
        );

        final anchor = await engine.sync();
        expect(anchor.networkUtcMs, closeTo(1000000, 100));
      },
    );
  });

  group('SyncEngine _completeSync re-entry guard (skj.2)', () {
    late FakeMonotonicClock clock;

    setUp(() {
      clock = FakeMonotonicClock();
    });

    test(
      'fires onConsensusReached/onMetricsReported exactly once per cycle '
      'when the last sample triggers both early-exit and finalize paths',
      () async {
        final observer = RecordingObserver();
        // Three sources returning identical intervals so the engine
        // can reach stableCount == requiredStability (2, no variance)
        // on the third sample. MarzulloEngine.resolve returns null
        // for the first sample (under minimumQuorum), so the second
        // sample is the *first* non-null resolve and produces
        // stableCount == 1; the third sample produces a matching
        // resolve and brings stableCount to 2. Both _completeSync
        // call sites then fire from the *same* listener invocation
        // — sample 3's:
        //
        //  * The stability check trips `stableCount >=
        //    requiredStability`, so the early-exit branch fires
        //    `unawaited(_completeSync(...))` (call A).
        //  * Immediately after, in the same listener tick,
        //    `pendingQueries` is decremented from 1 to 0, which
        //    triggers `_finalizeSync` -> `_completeSync` (call B).
        //
        // Both calls are scheduled before either yields, so without
        // a synchronous re-entry guard both pass `completer.isCompleted
        // == false`, both await `_createAnchor`, and both emit
        // observer events.
        //
        // GatedMonotonicClock holds call A's _createAnchor pending
        // until call B's _createAnchor also begins, forcing both
        // _completeSync continuations to resume in the same
        // microtask burst. Without this gate, default microtask
        // scheduling lets call A complete the Completer before call
        // B's guard even runs, so the race never fires in-process
        // even though it is reachable on a real device — the
        // empirical witness from integration/bleeding-edge stress
        // runs (Pixel Tablet, 2026-05-08) confirms the race fires
        // when wall-clock timing of source responses brings the two
        // call sites into overlap.
        final gatedClock = GatedMonotonicClock();
        final s1 = RaceConditionSource('s1', Duration.zero, 1000000, 'g1');
        final s2 = RaceConditionSource('s2', Duration.zero, 1000000, 'g2');
        final s3 = RaceConditionSource('s3', Duration.zero, 1000000, 'g3');

        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            minimumQuorum: 2,
            minGroupCount: 2,
            disableNtpForTesting: true,
            ntsServers: [],
          ).copyWith(additionalSources: [s1, s2, s3]),
          clock: gatedClock,
          observer: observer,
        );

        await engine.sync();

        expect(
          observer.consensusReached,
          hasLength(1),
          reason:
              'onConsensusReached should fire exactly once per sync cycle; '
              'duplicate emission indicates the _completeSync re-entry '
              'race has reappeared',
        );
        expect(
          observer.metricsReported,
          hasLength(1),
          reason:
              'onMetricsReported should fire exactly once per sync cycle; '
              'duplicate emission indicates the _completeSync re-entry '
              'race has reappeared',
        );
        expect(
          observer.syncStartedCount,
          1,
          reason:
              'sanity: a single sync() call must produce exactly one '
              'onSyncStarted event',
        );
      },
    );

    test(
      'fires onConsensusReached/onMetricsReported exactly once per cycle '
      'across repeated sync invocations (re-entry guard resets cleanly)',
      () async {
        final observer = RecordingObserver();
        // Three identical sources so each cycle actually exercises
        // the early-exit + finalize race (see the previous test for
        // why two sources is insufficient). This is what makes the
        // "guard resets cleanly" assertion meaningful — without the
        // race firing every cycle, this test would only verify that
        // sync completes successfully three times.
        final s1 = RaceConditionSource('s1', Duration.zero, 1000000, 'g1');
        final s2 = RaceConditionSource('s2', Duration.zero, 1000000, 'g2');
        final s3 = RaceConditionSource('s3', Duration.zero, 1000000, 'g3');

        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            minimumQuorum: 2,
            minGroupCount: 2,
            disableNtpForTesting: true,
            ntsServers: [],
          ).copyWith(additionalSources: [s1, s2, s3]),
          clock: clock,
          observer: observer,
        );

        // Three serial sync cycles must each emit exactly one
        // consensus + metrics event. Catches a regression where the
        // re-entry flag stays true after the first cycle and the
        // second cycle silently elides its own (legitimate)
        // _completeSync.
        for (var i = 0; i < 3; i++) {
          await engine.sync();
        }

        expect(observer.consensusReached, hasLength(3));
        expect(observer.metricsReported, hasLength(3));
        expect(observer.syncStartedCount, 3);
      },
    );
  });

  group('SyncEngine Consensus Stability Guard', () {
    // The engine requires `stableCount >= requiredStability` consecutive
    // matching `MarzulloEngine.resolve` results before firing early-exit.
    // `requiredStability` is 2 by default and escalates to 3 when any
    // sample's midpoint deviates from the consensus midpoint by more
    // than 500 ms (see the `varianceDetected` block in `SyncEngine.sync`
    // in `lib/src/sync_engine.dart`). The N=2 path is implicitly
    // covered by several existing tests in this file -- e.g.
    // `outlier filtering is deterministic across simultaneous arrivals`
    // in the `Adaptive Outlier Filtering` group, and the two tests in
    // the `_completeSync re-entry guard (skj.2)` group, which reach
    // `stableCount == requiredStability` (= 2, no variance) by design.
    // The two tests below close the remaining acceptance gap on
    // trusted_time-ads:
    //  * variance > 500 ms forces requiredStability=3, so early-exit
    //    must wait for one extra matching resolve;
    //  * a divergent intermediate `MarzulloEngine.resolve` resets
    //    `stableCount` to 1, so a "match, match, diverge, match"
    //    sequence does not collapse to a premature exit.
    //
    // Both tests count `onSampleReceived` events to infer where
    // early-exit fired -- see `SampleCountingObserver` for the full
    // mechanics of which samples reach the listener and which are
    // dropped at the per-source fan-out / stream-closure layer.
    //
    // Per-source delays are spaced at 20 ms so the relative arrival
    // order is robust against the ~1-10 ms timer-resolution and
    // scheduling jitter that shows up under CI load. The "late"
    // last source is held back by 400 ms, leaving ~300 ms of margin
    // between the last expected arrival (100 ms) and the first sample
    // that must be dropped (400 ms) -- comfortably more than the few
    // microtasks the engine needs between firing early-exit and
    // closing the sample controller, while still keeping each test
    // under half a second of wall time.

    test('volatile pool (variance > 500 ms) requires N=3 matching '
        'intervals before early-exit', () async {
      // s1 is a 20-ms-wide narrow interval centred on 1 001 000, so
      // its midpoint sits 1 000 ms above the eventual narrow consensus
      // midpoint of 1 000 000 — well above the 500 ms variance
      // threshold. s1 does not overlap s2..s5, so `MarzulloEngine`
      // never includes it in the deepest-overlap window, but it
      // remains in `samples` for the variance check
      // (`samples.any(...)`) and so escalates `requiredStability` to
      // 3 from the moment a non-null resolve is produced.
      //
      // Resolve sequence given the per-sample arrival order:
      //   samples=[s1]            → null (only 1 valid sample)
      //   samples=[s1,s2]         → null (depth 1 < requiredQuorum 2)
      //   samples=[s1,s2,s3]      → [999990,1000010] (depth 2)
      //                              stableCount 1
      //   samples=[s1,s2,s3,s4]   → same                stableCount 2
      //   samples=[s1,s2,s3,s4,s5]→ same                stableCount 3
      //                              → early-exit fires
      // Sample 6's 400 ms delay is far longer than the few microtasks
      // the engine needs to complete the completer after sample 5,
      // so it is dropped before reaching the observer.
      //
      // Counterfactual: if the variance check had not escalated
      // `requiredStability` from 2 to 3, early-exit would have fired
      // at sample 4 (`stableCount` reaching 2) and the recorded count
      // would be 4, not 5.
      final observer = SampleCountingObserver();
      final sources = [
        WideIntervalSource(
          's1',
          const Duration(milliseconds: 20),
          1000990,
          1001010,
          'g1',
        ),
        WideIntervalSource(
          's2',
          const Duration(milliseconds: 40),
          999990,
          1000010,
          'g2',
        ),
        WideIntervalSource(
          's3',
          const Duration(milliseconds: 60),
          999990,
          1000010,
          'g3',
        ),
        WideIntervalSource(
          's4',
          const Duration(milliseconds: 80),
          999990,
          1000010,
          'g4',
        ),
        WideIntervalSource(
          's5',
          const Duration(milliseconds: 100),
          999990,
          1000010,
          'g5',
        ),
        WideIntervalSource(
          's6',
          const Duration(milliseconds: 400),
          999990,
          1000010,
          'g6',
        ),
      ];

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 2,
          disableNtpForTesting: true,
          ntsServers: [],
        ).copyWith(additionalSources: sources),
        clock: FakeMonotonicClock(),
        observer: observer,
      );

      await engine.sync();

      expect(
        observer.samplesReceived,
        hasLength(5),
        reason:
            'with variance > 500 ms the engine must observe N=3 '
            'consecutive matching intervals before early-exit; the N=2 '
            'path would have exited after sample 4 (recorded count 4)',
      );
    });

    test('mid-stream divergence in MarzulloEngine.resolve resets the '
        'stability counter', () async {
      // All arriving samples share midpoint 1 000 000 and the
      // resolved consensus midpoints stay within ±250 ms of that, so
      // the variance check never fires and `requiredStability` stays
      // at 2 throughout. Sample widths shrink monotonically, which
      // shifts the deepest-overlap window each step:
      //   d1+d2          → [999500, 1001000] (depth 2, mid 1000250)
      //   d1+d2+d3       → [999990, 1000500] (depth 3, mid 1000245)
      //                    diverges from previous → stableCount=1
      //   d1+d2+d3+d4    → [999990, 1000010] (depth 4, mid 1000000)
      //                    diverges again      → stableCount=1
      //   d1+d2+d3+d4+d5 → same                → stableCount=2
      //                                         → early-exit fires
      // Sample 6's 400 ms delay drops it before it reaches the
      // observer.
      //
      // Counterfactual: if the reset branch were missing — e.g. if
      // `stableCount` were incremented unconditionally — the counter
      // would have reached 2 at sample 3 and early-exit would have
      // fired three samples earlier on a consensus the engine has
      // never observed twice in a row, with the recorded count 3
      // instead of 5.
      final observer = SampleCountingObserver();
      final sources = [
        WideIntervalSource(
          'd1',
          const Duration(milliseconds: 20),
          999000,
          1001000,
          'g1',
        ),
        WideIntervalSource(
          'd2',
          const Duration(milliseconds: 40),
          999500,
          1000500,
          'g2',
        ),
        WideIntervalSource(
          'd3',
          const Duration(milliseconds: 60),
          999990,
          1000010,
          'g3',
        ),
        WideIntervalSource(
          'd4',
          const Duration(milliseconds: 80),
          999990,
          1000010,
          'g4',
        ),
        WideIntervalSource(
          'd5',
          const Duration(milliseconds: 100),
          999990,
          1000010,
          'g5',
        ),
        WideIntervalSource(
          'd6',
          const Duration(milliseconds: 400),
          999990,
          1000010,
          'g6',
        ),
      ];

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 2,
          disableNtpForTesting: true,
          ntsServers: [],
        ).copyWith(additionalSources: sources),
        clock: FakeMonotonicClock(),
        observer: observer,
      );

      await engine.sync();

      expect(
        observer.samplesReceived,
        hasLength(5),
        reason:
            'each successive resolve produces a different interval so '
            'stableCount keeps resetting to 1; only sample 5 finally '
            'matches sample 4\'s interval and brings stableCount to '
            '2, firing early-exit. Without the reset, stableCount '
            'would have reached 2 at sample 3 and the recorded count '
            'would be 3',
      );
    });
  });
}
