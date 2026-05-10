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

  @override
  void onSourceFailed(String sourceId, Object error) {
    sourceFailures.add((sourceId: sourceId, error: error));
  }

  @override
  void onSyncStarted() {}
  @override
  void onSampleReceived(TimeSample sample) {}
  @override
  void onConsensusReached(ConsensusResult result) {}
  @override
  void onSyncFailed(Object error) {}
  @override
  void onMetricsReported(SyncMetrics metrics) {}
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
  });
}
