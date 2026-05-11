import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/infra/sync_observer.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

class MockMonotonicClock implements MonotonicClock {
  @override
  Future<int> uptimeMs() async => 100000;
}

class RaceConditionSource implements TimeSource {
  RaceConditionSource(
    this.id,
    this.delay,
    this.utcMs, [
    this.groupId = 'test-group',
  ]);
  @override
  final String id;
  final Duration delay;
  final int utcMs;

  @override
  final String groupId;

  @override
  Future<TimeSample> getTime() async {
    await Future.delayed(delay);
    return TimeSample(
      interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}

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

enum WarmingPhase { warmStart, warmEnd, getTimeStart, getTimeEnd }

class WarmingEvent {
  const WarmingEvent(this.sourceId, this.phase, this.atMs);
  final String sourceId;
  final WarmingPhase phase;
  final int atMs;
  @override
  String toString() => '$sourceId/${phase.name}@${atMs}ms';
}

/// Test source with configurable warm/getTime delays and behaviors that
/// records every phase transition into a shared event log so tests can
/// reason about the per-source pipeline ordering and cross-source
/// concurrency.
class WarmingTestSource implements TimeSource, Warmable {
  WarmingTestSource({
    required this.id,
    required this.utcMs,
    required this.events,
    required this.clock,
    this.groupId = 'test-group',
    this.warmDelay = Duration.zero,
    this.getTimeDelay = const Duration(milliseconds: 20),
    this.throwSyncFromWarm = false,
    this.throwAsyncFromWarm = false,
  });

  @override
  final String id;
  @override
  final String groupId;
  final int utcMs;
  final Duration warmDelay;
  final Duration getTimeDelay;
  final bool throwSyncFromWarm;
  final bool throwAsyncFromWarm;
  final List<WarmingEvent> events;
  final Stopwatch clock;

  @override
  Future<void> warm() {
    events.add(
      WarmingEvent(id, WarmingPhase.warmStart, clock.elapsedMilliseconds),
    );
    if (throwSyncFromWarm) {
      throw StateError('synchronous warm failure: $id');
    }
    return _doWarm();
  }

  Future<void> _doWarm() async {
    if (throwAsyncFromWarm) {
      throw StateError('asynchronous warm failure: $id');
    }
    if (warmDelay > Duration.zero) {
      await Future.delayed(warmDelay);
    }
    events.add(
      WarmingEvent(id, WarmingPhase.warmEnd, clock.elapsedMilliseconds),
    );
  }

  @override
  Future<TimeSample> getTime() async {
    events.add(
      WarmingEvent(id, WarmingPhase.getTimeStart, clock.elapsedMilliseconds),
    );
    if (getTimeDelay > Duration.zero) {
      await Future.delayed(getTimeDelay);
    }
    events.add(
      WarmingEvent(id, WarmingPhase.getTimeEnd, clock.elapsedMilliseconds),
    );
    return TimeSample(
      interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// SyncObserver that records every onSourceFailed call so tests can
/// assert that warm-phase failures are surfaced.
class RecordingObserver implements SyncObserver {
  final List<({String sourceId, Object error})> sourceFailures = [];
  final List<ConsensusResult> consensusReached = [];
  final List<SyncMetrics> metricsReported = [];
  int syncStartedCount = 0;

  @override
  void onSourceFailed(String sourceId, Object error) {
    sourceFailures.add((sourceId: sourceId, error: error));
  }

  @override
  void onSyncStarted() {
    syncStartedCount++;
  }

  @override
  void onSampleReceived(TimeSample sample) {}
  @override
  void onConsensusReached(ConsensusResult result) {
    consensusReached.add(result);
  }

  @override
  void onSyncFailed(Object error) {}
  @override
  void onMetricsReported(SyncMetrics metrics) {
    metricsReported.add(metrics);
  }
}

void main() {
  group('SyncEngine Concurrency & Race Conditions', () {
    late TrustedTimeConfig config;
    late MockMonotonicClock clock;

    setUp(() {
      clock = MockMonotonicClock();
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1, // Relax for tests
        ntpServers: [],
        httpsSources: [],
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

  group('SyncEngine Per-Source Warming Pipeline', () {
    late MockMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = MockMonotonicClock();
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
        httpsSources: [],
      );
    });

    test('fast sources are not blocked by a slow sources warming phase '
        '(no global barrier)', () async {
      // Three fast sources are needed so that the engine reaches both
      // consensus quorum (2 samples) and stability (2 consecutive
      // matching results) before the slow source can finish warming.
      // This isolates the no-global-barrier property: with a barrier,
      // sync would block ~500ms; without, it completes in ~50ms.
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();

      WarmingTestSource fast(String id, String group) => WarmingTestSource(
        id: id,
        groupId: group,
        utcMs: 1000000,
        events: events,
        clock: clockSw,
        warmDelay: Duration.zero,
        getTimeDelay: const Duration(milliseconds: 50),
      );

      final fast1 = fast('fast1', 'g-fast1');
      final fast2 = fast('fast2', 'g-fast2');
      final fast3 = fast('fast3', 'g-fast3');
      final slow = WarmingTestSource(
        id: 'slow',
        groupId: 'g-slow',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
        warmDelay: const Duration(milliseconds: 500),
        getTimeDelay: const Duration(milliseconds: 50),
      );

      final engine = SyncEngine(
        config: config.copyWith(
          earlyExit: true,
          additionalSources: [fast1, fast2, fast3, slow],
        ),
        clock: clock,
      );

      final syncSw = Stopwatch()..start();
      final anchor = await engine.sync();
      syncSw.stop();
      final eventsAtReturn = events.toList();

      expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000020));

      // Primary assertion: sync completes well before the slow source's
      // warm could possibly finish (500 ms warm).
      expect(
        syncSw.elapsedMilliseconds,
        lessThan(300),
        reason:
            'sync took ${syncSw.elapsedMilliseconds}ms; fast sources '
            'should not have waited on slow source warming',
      );

      // Secondary assertion: at the moment sync() returned, the fast
      // sources had finished getTime, and the slow source's warm had
      // not yet completed.
      bool sawPhase(String id, WarmingPhase phase) =>
          eventsAtReturn.any((e) => e.sourceId == id && e.phase == phase);
      for (final id in ['fast1', 'fast2', 'fast3']) {
        expect(
          sawPhase(id, WarmingPhase.getTimeEnd),
          isTrue,
          reason: '$id should have completed getTime before sync returned',
        );
      }
      expect(
        sawPhase('slow', WarmingPhase.warmEnd),
        isFalse,
        reason:
            'slow.warm-end should not have completed yet; events: '
            '$eventsAtReturn',
      );
    });

    test('getTime is never invoked before warm has fully resolved (per-source '
        'sequential integrity)', () async {
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();

      final sources = [
        WarmingTestSource(
          id: 's1',
          groupId: 'g1',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 30),
          getTimeDelay: const Duration(milliseconds: 20),
        ),
        WarmingTestSource(
          id: 's2',
          groupId: 'g2',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 80),
          getTimeDelay: const Duration(milliseconds: 20),
        ),
        WarmingTestSource(
          id: 's3',
          groupId: 'g3',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 5),
          getTimeDelay: const Duration(milliseconds: 20),
        ),
      ];

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: sources),
        clock: clock,
      );

      await engine.sync();

      for (final source in sources) {
        final sourceEvents = events
            .where((e) => e.sourceId == source.id)
            .toList();
        // Expected ordering: warmStart -> warmEnd -> getTimeStart -> getTimeEnd
        expect(
          sourceEvents.map((e) => e.phase).toList(),
          equals([
            WarmingPhase.warmStart,
            WarmingPhase.warmEnd,
            WarmingPhase.getTimeStart,
            WarmingPhase.getTimeEnd,
          ]),
          reason:
              'unexpected phase ordering for ${source.id}: '
              '$sourceEvents',
        );

        final warmEndAt = sourceEvents
            .firstWhere((e) => e.phase == WarmingPhase.warmEnd)
            .atMs;
        final getTimeStartAt = sourceEvents
            .firstWhere((e) => e.phase == WarmingPhase.getTimeStart)
            .atMs;
        expect(
          getTimeStartAt,
          greaterThanOrEqualTo(warmEndAt),
          reason:
              '${source.id}: getTime started at ${getTimeStartAt}ms '
              'before warm finished at ${warmEndAt}ms',
        );
      }
    });

    test('synchronous and asynchronous warm failures are reported to the '
        'observer and do not prevent getTime from running', () async {
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();
      final observer = RecordingObserver();

      final syncThrower = WarmingTestSource(
        id: 'syncThrower',
        groupId: 'g-sync',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
        throwSyncFromWarm: true,
      );
      final asyncThrower = WarmingTestSource(
        id: 'asyncThrower',
        groupId: 'g-async',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
        throwAsyncFromWarm: true,
      );
      final healthy1 = WarmingTestSource(
        id: 'healthy1',
        groupId: 'g-h1',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
      );
      final healthy2 = WarmingTestSource(
        id: 'healthy2',
        groupId: 'g-h2',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
      );

      final engine = SyncEngine(
        config: config.copyWith(
          additionalSources: [syncThrower, asyncThrower, healthy1, healthy2],
        ),
        clock: clock,
        observer: observer,
      );

      final anchor = await engine.sync();
      expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000020));

      // Both throwers must surface as warm-phase failures on the
      // observer, tagged with the 'warm:' prefix the engine adds.
      final warmFailures = observer.sourceFailures
          .where((f) => f.error.toString().startsWith('warm:'))
          .toList();
      final failedIds = warmFailures.map((f) => f.sourceId).toSet();
      expect(failedIds, containsAll(<String>{'syncThrower', 'asyncThrower'}));

      // Both throwers must still have proceeded to getTime despite the
      // warm failure.
      bool sawGetTime(String id) => events.any(
        (e) => e.sourceId == id && e.phase == WarmingPhase.getTimeEnd,
      );
      expect(
        sawGetTime('syncThrower'),
        isTrue,
        reason: 'syncThrower.getTime did not run after sync warm throw',
      );
      expect(
        sawGetTime('asyncThrower'),
        isTrue,
        reason: 'asyncThrower.getTime did not run after async warm throw',
      );
    });
  });

  group('SyncEngine.warmAllSources', () {
    late MockMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = MockMonotonicClock();
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
        httpsSources: [],
      );
    });

    test('invokes warm() on every Warmable source in parallel', () async {
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();
      final sources = [
        WarmingTestSource(
          id: 'a',
          groupId: 'g-a',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 100),
        ),
        WarmingTestSource(
          id: 'b',
          groupId: 'g-b',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 100),
        ),
        WarmingTestSource(
          id: 'c',
          groupId: 'g-c',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 100),
        ),
      ];

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: sources),
        clock: clock,
      );

      final sw = Stopwatch()..start();
      await engine.warmAllSources();
      sw.stop();

      // All three sources must have completed warming.
      for (final id in ['a', 'b', 'c']) {
        expect(
          events.any(
            (e) => e.sourceId == id && e.phase == WarmingPhase.warmEnd,
          ),
          isTrue,
          reason: '$id.warm-end was not recorded',
        );
      }

      // Parallelism: 3 x 100ms warms must take ~100ms, not ~300ms.
      // 250ms is generous enough to absorb scheduling jitter on
      // slow CI without admitting accidental sequential execution.
      expect(
        sw.elapsedMilliseconds,
        lessThan(250),
        reason:
            'warmAllSources took ${sw.elapsedMilliseconds}ms; '
            'expected ~100ms (parallel) not ~300ms (sequential)',
      );
    });

    test('is a no-op when no source implements Warmable', () async {
      final source = RaceConditionSource('plain', Duration.zero, 1000000);

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: [source]),
        clock: clock,
      );

      final sw = Stopwatch()..start();
      await engine.warmAllSources();
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(50));
    });

    test('swallows individual warm failures so a misbehaving source cannot '
        'block bootstrap', () async {
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();
      final sources = [
        WarmingTestSource(
          id: 'syncThrower',
          groupId: 'g-sync',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          throwSyncFromWarm: true,
        ),
        WarmingTestSource(
          id: 'asyncThrower',
          groupId: 'g-async',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          throwAsyncFromWarm: true,
        ),
        WarmingTestSource(
          id: 'healthy',
          groupId: 'g-healthy',
          utcMs: 1000000,
          events: events,
          clock: clockSw,
          warmDelay: const Duration(milliseconds: 30),
        ),
      ];

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: sources),
        clock: clock,
      );

      // Must not throw.
      await engine.warmAllSources();

      // Healthy source must still have completed warming.
      expect(
        events.any(
          (e) => e.sourceId == 'healthy' && e.phase == WarmingPhase.warmEnd,
        ),
        isTrue,
        reason: 'healthy.warm-end did not run despite sibling failures',
      );
    });
  });

  group('SyncEngine TransientSourceError handling', () {
    late MockMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = MockMonotonicClock();
      // Override every default source list so the engine only queries
      // the test's `additionalSources`. Without `ntsServers: const []`,
      // the default `['time.cloudflare.com']` would instantiate an
      // NtsSource that either fails fast (RustLib.init not called in
      // the test harness) or attempts real network I/O on machines
      // where the native is initialised — both are unrelated noise
      // for the cooldown-semantics assertion.
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
        httpsSources: [],
        ntsServers: [],
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

  group('SyncEngine _completeSync re-entry guard (skj.2)', () {
    late MockMonotonicClock clock;

    setUp(() {
      clock = MockMonotonicClock();
    });

    test(
      'fires onConsensusReached/onMetricsReported exactly once per cycle '
      'when the last sample triggers both early-exit and finalize paths',
      () async {
        final observer = RecordingObserver();
        // Two sources returning identical intervals so the engine
        // reaches stableCount == requiredStability (2, no variance) on
        // the second sample. That second sample is also the last
        // pending query, so the listener fires _completeSync via the
        // early-exit branch AND _finalizeSync (which itself calls
        // _completeSync) via the pendingQueries == 0 branch in the
        // same listener invocation. Without the synchronous re-entry
        // guard this produced two onConsensusReached + two
        // onMetricsReported events per cycle.
        final s1 = RaceConditionSource('s1', Duration.zero, 1000000, 'g1');
        final s2 = RaceConditionSource('s2', Duration.zero, 1000000, 'g2');

        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            minimumQuorum: 2,
            minGroupCount: 2,
            ntpServers: [],
            httpsSources: [],
            ntsServers: [],
          ).copyWith(additionalSources: [s1, s2]),
          clock: clock,
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
        final s1 = RaceConditionSource('s1', Duration.zero, 1000000, 'g1');
        final s2 = RaceConditionSource('s2', Duration.zero, 1000000, 'g2');

        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            minimumQuorum: 2,
            minGroupCount: 2,
            ntpServers: [],
            httpsSources: [],
            ntsServers: [],
          ).copyWith(additionalSources: [s1, s2]),
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
}
