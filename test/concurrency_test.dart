import 'dart:async';

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

/// Monotonic clock that deliberately holds the first [uptimeMs] call
/// pending until either a second call arrives or one event-loop turn
/// elapses. Used by the `_completeSync` re-entry guard tests (skj.2)
/// to force two `_completeSync` invocations to overlap on the same
/// microtask burst — without this gate, the default microtask
/// scheduling lets the first call's `_createAnchor` resolve and
/// complete the [Completer] before the second call even reaches its
/// guard check, so the race never actually fires in-process even
/// though it is reachable on a real device.
///
/// Behaviour: the first [uptimeMs] call races
/// [_secondCallStarted.future] against `Future.delayed(Duration.zero)`
/// via [Future.any]. Whichever resolves first releases the gate. The
/// second [uptimeMs] call resolves [_secondCallStarted] synchronously
/// and itself returns immediately.
///
/// Why one event-loop turn is the right fallback window: the race
/// fires when both `_completeSync` invocations are scheduled by the
/// same SyncEngine listener tick. The first invocation hits its
/// `await _clock.uptimeMs()` and yields; the second invocation —
/// scheduled as an `unawaited` microtask in the same listener tick —
/// reaches its own `await _clock.uptimeMs()` within a small handful
/// of microtasks. `Future.delayed(Duration.zero)` is timer-driven
/// and resolves only after the current event-loop iteration drains
/// its microtask queue, so the second call (if it is going to come)
/// always wins the race against the timer fallback.
///
/// Equivalently: when the production re-entry guards are working,
/// only one `_completeSync` reaches `_createAnchor`, so
/// [_secondCallStarted] is never completed and the timer wins after
/// one event-loop turn — the test completes in microseconds, not
/// hundreds of milliseconds. When the guards are disabled the
/// second call wins, the gate releases synchronously, and the
/// duplicate-emission assertion still fires.
class GatedMonotonicClock implements MonotonicClock {
  final Completer<void> _secondCallStarted = Completer<void>();
  int callCount = 0;

  @override
  Future<int> uptimeMs() async {
    callCount++;
    if (callCount == 1) {
      await Future.any([
        _secondCallStarted.future,
        Future<void>.delayed(Duration.zero),
      ]);
      return 100000;
    } else {
      if (!_secondCallStarted.isCompleted) {
        _secondCallStarted.complete();
      }
      return 100000;
    }
  }
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

/// Records every sample handed to the engine's stream listener so
/// stability-guard tests can assert how many samples the engine
/// consumed before early-exit fired. The engine's listener returns
/// before calling [onSampleReceived] once the completer is completed
/// (see `if (completer.isCompleted) return;` at the top of the
/// listener), so a recorded sample count of N implies early-exit
/// fired no earlier than sample N.
class SampleCountingObserver implements SyncObserver {
  final List<TimeSample> samplesReceived = [];

  @override
  void onSampleReceived(TimeSample sample) {
    samplesReceived.add(sample);
  }

  @override
  void onSourceFailed(String sourceId, Object error) {}
  @override
  void onSyncStarted() {}
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
            ntpServers: [],
            httpsSources: [],
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
            ntpServers: [],
            httpsSources: [],
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
    // than 500 ms (the variance check at sync_engine.dart:248-253).
    // The N=2 path is implicitly covered by the existing tests in this
    // file (see comments at lines ~398, ~455, ~1186 referencing
    // `stableCount == requiredStability` with no variance). The two
    // tests below close the remaining acceptance gap on
    // trusted_time-ads:
    //  * variance > 500 ms forces requiredStability=3, so early-exit
    //    must wait for one extra matching resolve;
    //  * a divergent intermediate `MarzulloEngine.resolve` resets
    //    `stableCount` to 1, so a "match, match, diverge, match"
    //    sequence does not collapse to a premature exit.
    //
    // Both tests count `onSampleReceived` events to infer where
    // early-exit fired: the engine's stream listener guards every
    // sample with `if (completer.isCompleted) return;` before invoking
    // the observer, so a late-arriving sample whose delay exceeds the
    // window between early-exit firing and the completer resolving is
    // silently dropped and never recorded.

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
      // Sample 6's 200 ms delay is far longer than the few microtasks
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
          const Duration(milliseconds: 5),
          1000990,
          1001010,
          'g1',
        ),
        WideIntervalSource(
          's2',
          const Duration(milliseconds: 10),
          999990,
          1000010,
          'g2',
        ),
        WideIntervalSource(
          's3',
          const Duration(milliseconds: 15),
          999990,
          1000010,
          'g3',
        ),
        WideIntervalSource(
          's4',
          const Duration(milliseconds: 20),
          999990,
          1000010,
          'g4',
        ),
        WideIntervalSource(
          's5',
          const Duration(milliseconds: 25),
          999990,
          1000010,
          'g5',
        ),
        WideIntervalSource(
          's6',
          const Duration(milliseconds: 200),
          999990,
          1000010,
          'g6',
        ),
      ];

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 2,
          ntpServers: [],
          httpsSources: [],
          ntsServers: [],
        ).copyWith(additionalSources: sources),
        clock: MockMonotonicClock(),
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
      // Sample 6's 200 ms delay drops it before it reaches the
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
          const Duration(milliseconds: 5),
          999000,
          1001000,
          'g1',
        ),
        WideIntervalSource(
          'd2',
          const Duration(milliseconds: 10),
          999500,
          1000500,
          'g2',
        ),
        WideIntervalSource(
          'd3',
          const Duration(milliseconds: 15),
          999990,
          1000010,
          'g3',
        ),
        WideIntervalSource(
          'd4',
          const Duration(milliseconds: 20),
          999990,
          1000010,
          'g4',
        ),
        WideIntervalSource(
          'd5',
          const Duration(milliseconds: 25),
          999990,
          1000010,
          'g5',
        ),
        WideIntervalSource(
          'd6',
          const Duration(milliseconds: 200),
          999990,
          1000010,
          'g6',
        ),
      ];

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 2,
          ntpServers: [],
          httpsSources: [],
          ntsServers: [],
        ).copyWith(additionalSources: sources),
        clock: MockMonotonicClock(),
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
