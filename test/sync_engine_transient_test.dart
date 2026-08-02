import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';
import 'support/fake_observers.dart';
import 'support/fake_sources.dart';

/// Test source that throws [TransientSourceError] on every [getTime]
/// call. Records its call count so tests can assert whether the engine
/// has escalated it to the regular cooldown path (after which it stops
/// being called) versus retrying it forever (the pre-streak-guard
/// behaviour). The thrown error carries its call ordinal so failure
/// assertions can distinguish individual cycles in the recorded
/// observer history.
class RepeatingTransientSource implements TimeSource {
  RepeatingTransientSource({required this.id, this.groupId = 'test-group'});

  @override
  final String id;
  @override
  final String groupId;

  int callCount = 0;

  @override
  Future<TimeSample> getTime() async {
    callCount++;
    throw TransientSourceError('repeating stub call $callCount');
  }
}

/// Test source that alternates between throwing [TransientSourceError]
/// (odd-numbered calls) and returning a valid sample (even-numbered
/// calls). Used to assert that a successful query resets the engine's
/// transient-streak counter and prevents escalation.
class AlternatingTransientSource implements TimeSource {
  AlternatingTransientSource({
    required this.id,
    required this.utcMs,
    this.groupId = 'test-group',
  });

  @override
  final String id;
  @override
  final String groupId;
  final int utcMs;

  int callCount = 0;

  @override
  Future<TimeSample> getTime() async {
    callCount++;
    if (callCount.isOdd) {
      throw TransientSourceError('alternating stub call $callCount');
    }
    return TimeSample(
      interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// Test source that throws a configurable error on the first [getTime]
/// call and returns a valid sample on every subsequent call. Records its
/// call count so tests can assert whether it was retried after a failure
/// (i.e., not blacklisted by the engine's cooldown path).
class FlakySource implements TimeSource {
  FlakySource({
    required this.id,
    required this.utcMs,
    required this.firstCallError,
    this.groupId = 'test-group',
  });

  @override
  final String id;
  @override
  final String groupId;
  final int utcMs;
  final Object firstCallError;

  int callCount = 0;

  @override
  Future<TimeSample> getTime() async {
    callCount++;
    if (callCount == 1) {
      throw firstCallError;
    }
    return TimeSample(
      interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}

void main() {
  group('SyncEngine TransientSourceError handling', () {
    late FakeMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = FakeMonotonicClock();
      // Override every default source list so the engine only queries
      // the test's `additionalSources`. Without `disableNts: true`,
      // the curated NTS inventory would instantiate an
      // NtsSource per host that either fails fast (NtsRustLib.init not called in
      // the test harness) or attempts real network I/O on machines
      // where the native is initialised — both are unrelated noise
      // for the cooldown-semantics assertion.
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        disableNtpForTesting: true,
        disableNts: true,
      );
    });

    test('TransientSourceError is reported to observer and does not blacklist '
        'the source on the next sync cycle', () async {
      final observer = RecordingObserver();
      final flaky = FlakySource(
        id: 'flaky',
        groupId: 'g-flaky',
        utcMs: 1000000,
        firstCallError: const TransientSourceError('dnsSaturation stub'),
      );
      // Two healthy sources so the first cycle still reaches quorum
      // when flaky throws.
      final healthy1 = RaceConditionSource(
        'h1',
        Duration.zero,
        1000000,
        'g-h1',
      );
      final healthy2 = RaceConditionSource(
        'h2',
        Duration.zero,
        1000000,
        'g-h2',
      );

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: [flaky, healthy1, healthy2]),
        clock: clock,
        observer: observer,
      );

      // Cycle 1: flaky throws TransientSourceError; quorum still met.
      await engine.sync();

      // Observer must have been notified with the TransientSourceError
      // instance itself, not a stringified or wrapped form.
      final flakyFailures = observer.sourceFailures
          .where((f) => f.sourceId == 'flaky')
          .toList();
      expect(flakyFailures, hasLength(1));
      expect(flakyFailures.single.error, isA<TransientSourceError>());

      // Cycle 2: flaky must be queried again. If the engine had treated
      // the failure as cooldown-eligible, _blacklistUntil would skip it
      // (default cooldown = 2^1 = 2 minutes, which would push the next
      // attempt well past this test's wall clock).
      await engine.sync();
      expect(
        flaky.callCount,
        2,
        reason:
            'flaky.getTime was not retried on cycle 2; '
            'TransientSourceError appears to have triggered cooldown',
      );
    });

    test('a non-transient exception does blacklist the source on the next '
        'sync cycle (contrast case)', () async {
      final observer = RecordingObserver();
      final flaky = FlakySource(
        id: 'flaky',
        groupId: 'g-flaky',
        utcMs: 1000000,
        firstCallError: StateError('regular failure'),
      );
      final healthy1 = RaceConditionSource(
        'h1',
        Duration.zero,
        1000000,
        'g-h1',
      );
      final healthy2 = RaceConditionSource(
        'h2',
        Duration.zero,
        1000000,
        'g-h2',
      );

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: [flaky, healthy1, healthy2]),
        clock: clock,
        observer: observer,
      );

      await engine.sync();

      final flakyFailures = observer.sourceFailures
          .where((f) => f.sourceId == 'flaky')
          .toList();
      expect(flakyFailures, hasLength(1));
      expect(flakyFailures.single.error, isA<StateError>());

      await engine.sync();
      expect(
        flaky.callCount,
        1,
        reason:
            'flaky.getTime should have been blacklisted after a '
            'non-transient failure but was retried on cycle 2',
      );
    });

    test('sustained TransientSourceError escalates to cooldown after '
        'transientStreakThreshold cycles', () async {
      final observer = RecordingObserver();
      final stuck = RepeatingTransientSource(id: 'stuck', groupId: 'g-stuck');
      // Two healthy sources so each pre-escalation cycle still reaches
      // quorum and the engine does not abort cycle 2 with a
      // quorum-failure exception before the escalation path runs.
      final healthy1 = RaceConditionSource(
        'h1',
        Duration.zero,
        1000000,
        'g-h1',
      );
      final healthy2 = RaceConditionSource(
        'h2',
        Duration.zero,
        1000000,
        'g-h2',
      );

      final engine = SyncEngine(
        config: config.copyWith(
          additionalSources: [stuck, healthy1, healthy2],
          transientStreakThreshold: 2,
        ),
        clock: clock,
        observer: observer,
      );

      // Cycle 1: stuck throws transient. Streak=1 < threshold, so no
      // cooldown is armed and the source must be retried next cycle.
      await engine.sync();
      // Cycle 2: stuck throws transient again. Streak=2 == threshold,
      // so the engine escalates: bumps _sourceHealth and arms
      // _blacklistUntil with a 2-minute cooldown (2^1).
      await engine.sync();
      expect(
        stuck.callCount,
        2,
        reason:
            'stuck.getTime should have been retried on cycle 2 '
            'because the streak was still under threshold at cycle 1',
      );

      // Cycle 3: stuck must now be filtered by activeSources because
      // _blacklistUntil['stuck'] > now. If escalation did not arm the
      // cooldown, callCount would be 3 here.
      await engine.sync();
      expect(
        stuck.callCount,
        2,
        reason:
            'stuck.getTime should have been blacklisted after the '
            'transient-streak escalation on cycle 2 but was retried '
            'on cycle 3',
      );

      // Observer recorded exactly two transient-failure events
      // (cycles 1 and 2); cycle 3 was a cooldown skip with no
      // observer notification.
      final stuckFailures = observer.sourceFailures
          .where((f) => f.sourceId == 'stuck')
          .toList();
      expect(stuckFailures, hasLength(2));
      expect(stuckFailures[0].error, isA<TransientSourceError>());
      expect(stuckFailures[1].error, isA<TransientSourceError>());
    });

    test('a successful query resets the transient-streak counter so '
        'escalation only fires on consecutive transient failures', () async {
      final observer = RecordingObserver();
      final flapping = AlternatingTransientSource(
        id: 'flapping',
        groupId: 'g-flapping',
        utcMs: 1000000,
      );
      final healthy1 = RaceConditionSource(
        'h1',
        Duration.zero,
        1000000,
        'g-h1',
      );
      final healthy2 = RaceConditionSource(
        'h2',
        Duration.zero,
        1000000,
        'g-h2',
      );

      final engine = SyncEngine(
        config: config.copyWith(
          additionalSources: [flapping, healthy1, healthy2],
          transientStreakThreshold: 2,
        ),
        clock: clock,
        observer: observer,
      );

      // Five cycles: cycles 1, 3, 5 throw transient; cycles 2, 4 succeed.
      // The streak reaches 1 between every pair of transients but is
      // wiped to 0 by the success in between, so it can never reach the
      // threshold of 2 and no cooldown is ever armed.
      for (var i = 0; i < 5; i++) {
        await engine.sync();
      }

      expect(
        flapping.callCount,
        5,
        reason:
            'flapping.getTime should have been called on every '
            'cycle; intervening successes should have reset the '
            'transient-streak counter and prevented escalation',
      );

      final flappingFailures = observer.sourceFailures
          .where((f) => f.sourceId == 'flapping')
          .toList();
      expect(flappingFailures, hasLength(3));
    });

    test('transientStreakThreshold = 0 disables escalation; sustained '
        'transient failures retry indefinitely (legacy behaviour)', () async {
      final observer = RecordingObserver();
      final stuck = RepeatingTransientSource(id: 'stuck', groupId: 'g-stuck');
      final healthy1 = RaceConditionSource(
        'h1',
        Duration.zero,
        1000000,
        'g-h1',
      );
      final healthy2 = RaceConditionSource(
        'h2',
        Duration.zero,
        1000000,
        'g-h2',
      );

      final engine = SyncEngine(
        config: config.copyWith(
          additionalSources: [stuck, healthy1, healthy2],
          transientStreakThreshold: 0,
        ),
        clock: clock,
        observer: observer,
      );

      // Run more cycles than any non-zero threshold would tolerate.
      // With escalation disabled, every cycle must call stuck.getTime
      // and the source must never enter cooldown.
      for (var i = 0; i < 8; i++) {
        await engine.sync();
      }

      expect(
        stuck.callCount,
        8,
        reason:
            'transientStreakThreshold = 0 should disable escalation; '
            'stuck.getTime should have been called on every cycle',
      );

      final stuckFailures = observer.sourceFailures
          .where((f) => f.sourceId == 'stuck')
          .toList();
      expect(stuckFailures, hasLength(8));
    });
  });

  group('SyncEngine quality-tracker integration (4em, a4d)', () {
    late FakeMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = FakeMonotonicClock();
      // disableNts: true keeps the curated NTS inventory out of the
      // pool (see the TransientSourceError group for the full rationale).
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        disableNtpForTesting: true,
        disableNts: true,
      );
    });

    test('starvation guard re-admits a cooled source after '
        '_kStarvationCycles successful cycles (trusted_time-4em)', () async {
      // flaky fails once with a non-transient error -> blacklisted with a
      // 2-minute cooldown that never expires within this (instant) test.
      // h1/h2 keep every cycle reaching quorum so the engine advances its
      // internal cycle counter on each success. The cooldown filter keeps
      // flaky out of the ranked set every cycle, so the only path that can
      // re-query it is the starvation rescue.
      final flaky = FlakySource(
        id: 'flaky',
        groupId: 'g-flaky',
        utcMs: 1000000,
        firstCallError: StateError('regular failure'),
      );
      final h1 = RaceConditionSource('h1', Duration.zero, 1000000, 'g-h1');
      final h2 = RaceConditionSource('h2', Duration.zero, 1000000, 'g-h2');

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: [flaky, h1, h2]),
        clock: clock,
      );

      // Cycle 1 fails flaky (callCount 1) and arms the cooldown; cycles
      // 2-5 must NOT re-query it, because it has not yet gone unqueried
      // for _kStarvationCycles (5) advanced cycles.
      for (var i = 0; i < 5; i++) {
        await engine.sync();
      }
      expect(
        flaky.callCount,
        1,
        reason:
            'a cooled source must not be re-queried before the starvation '
            'threshold; isStarved is still false here',
      );

      // Cycle 6: flaky has now been unqueried for 5 advanced cycles, so the
      // starvation rescue force-includes it for a single query. Pre-fix
      // (dead rescue branch) callCount would stay 1 forever.
      await engine.sync();
      expect(
        flaky.callCount,
        2,
        reason:
            'starvation rescue must force-include a source stuck in '
            'cooldown once it has gone unqueried for _kStarvationCycles '
            'successful cycles; a permanently-1 callCount means the rescue '
            'branch is unreachable (trusted_time-4em regression)',
      );
    });

    test(
      'records non-participant samples with participatedInConsensus=false '
      'so participation rate is not pinned at 1.0 (trusted_time-a4d)',
      () async {
        final tracker = SourceQualityTracker();
        // w1/w2/w3 agree on 1_000_000 and form the consensus winning set.
        final w1 = RaceConditionSource('w1', Duration.zero, 1000000, 'g1');
        final w2 = RaceConditionSource('w2', Duration.zero, 1000000, 'g2');
        final w3 = RaceConditionSource('w3', Duration.zero, 1000000, 'g3');
        // loser returns a valid, non-outlier sample 5 s away from
        // consensus: its uncertainty (10 ms) is far under the outlier cap,
        // so it is collected into `samples`, but its interval does not
        // contain the consensus midpoint, so it is excluded from
        // result.participants.
        final loser = RaceConditionSource(
          'loser',
          Duration.zero,
          1005000,
          'g4',
        );

        // earlyExit:false so the engine collects every source's sample
        // before completing. With the default early-exit the engine would
        // complete on the three agreeing winners and drop loser's
        // (marginally later) sample before it could be recorded — a
        // property of the engine's exit timing, not of the recording loop
        // under test here.
        final engine = SyncEngine(
          config: config.copyWith(
            additionalSources: [w1, w2, w3, loser],
            earlyExit: false,
          ),
          clock: clock,
          qualityTracker: tracker,
        );

        await engine.sync();

        // Pre-fix the recording loop iterated result.participants only, so
        // a losing source was never recorded at all (participationRate ->
        // null) and a winner's rate was a vacuous 1.0. Post-fix the full
        // collected sample population is recorded with the correct flag.
        expect(
          tracker.participationRate('loser'),
          0.0,
          reason:
              'a source that returned a valid sample but lost consensus '
              'must be recorded as a non-participant, not skipped; null '
              'here means the engine still records winners only '
              '(trusted_time-a4d)',
        );
        expect(
          tracker.participationRate('w1'),
          1.0,
          reason: 'a consensus winner must record as a participant',
        );
      },
    );

    test('colliding source ids query only the first-seen source, matching '
        "ranked()'s first-seen dedup (trusted_time-awj)", () async {
      // dupA and dupB share id "dup" (a misconfiguration the tracker
      // defends against). ranked() deduplicates ids keeping the first
      // occurrence; healthyById must resolve that same colliding id to
      // the first-seen source so the ranked slot and the queried
      // instance agree. Pre-fix, healthyById (a map literal) kept the
      // last-seen source, so dupB was queried and dupA was not --
      // letting one misconfigured id contribute the wrong (and
      // construction-order-dependent) instance, and risking two samples
      // from one id reaching the quorum.
      final dupA = CountingSource('dup', 1000000, 'g-dup');
      final dupB = CountingSource('dup', 1000000, 'g-dup');
      final h1 = RaceConditionSource('h1', Duration.zero, 1000000, 'g-h1');
      final h2 = RaceConditionSource('h2', Duration.zero, 1000000, 'g-h2');

      // earlyExit:false so every active source is queried, removing exit
      // timing as a variable: dupB's callCount staying 0 then means it
      // was excluded from the active set, not merely raced past.
      final engine = SyncEngine(
        config: config.copyWith(
          additionalSources: [dupA, dupB, h1, h2],
          earlyExit: false,
        ),
        clock: clock,
      );

      await engine.sync();

      expect(
        dupA.callCount,
        1,
        reason: 'the first-seen source for a colliding id must be queried',
      );
      expect(
        dupB.callCount,
        0,
        reason:
            'the second source sharing an id must never be queried; '
            "querying it disagrees with ranked()'s first-seen dedup and "
            'would let one misconfigured id contribute two samples to the '
            'quorum (trusted_time-awj)',
      );
    });
  });
}
