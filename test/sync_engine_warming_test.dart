import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';
import 'support/fake_observers.dart';
import 'support/fake_sources.dart';

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

  Future<void>? _warmTask;

  @override
  Future<void> warm() {
    // Memoized, matching the Warmable contract real sources implement
    // (NtsSource caches its warm future): repeat calls — e.g. the
    // global warming barrier followed by the per-source Phase A —
    // await the same underlying task instead of re-running the delay.
    final existing = _warmTask;
    if (existing != null) return existing;
    events.add(
      WarmingEvent(id, WarmingPhase.warmStart, clock.elapsedMilliseconds),
    );
    if (throwSyncFromWarm) {
      // Memoize the failure before throwing so repeat calls return the
      // same failed Future instead of re-emitting warmStart and
      // re-throwing synchronously. ignore() keeps the cached future from
      // tripping the unhandled-async-error trap when no later call
      // awaits it.
      final error = StateError('synchronous warm failure: $id');
      _warmTask = Future<void>.error(error)..ignore();
      throw error;
    }
    return _warmTask = _doWarm();
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

void main() {
  group('SyncEngine Per-Source Warming Pipeline', () {
    late FakeMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = FakeMonotonicClock();
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
      );
    });

    test('global warming barrier: every warm completes before any '
        'getTime starts', () async {
      // The barrier (trusted_time-z6e) inverts the former
      // no-global-barrier property: all queries must launch against
      // fully-warmed state with converged start times, so the slowest
      // warm gates every source's first query. The mixed delays below
      // (5–300 ms) would previously have let the fast sources sample
      // ~295 ms before the slow one finished warming.
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();

      WarmingTestSource src(String id, Duration warmDelay) => WarmingTestSource(
        id: id,
        groupId: 'g-$id',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
        warmDelay: warmDelay,
        getTimeDelay: const Duration(milliseconds: 20),
      );

      final sources = [
        src('fast', const Duration(milliseconds: 5)),
        src('medium', const Duration(milliseconds: 60)),
        src('slow', const Duration(milliseconds: 300)),
      ];

      final engine = SyncEngine(
        config: config.copyWith(additionalSources: sources),
        clock: clock,
      );

      final anchor = await engine.sync();
      expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000020));

      final lastWarmEnd = events
          .where((e) => e.phase == WarmingPhase.warmEnd)
          .map((e) => e.atMs)
          .reduce(max);
      final firstGetTimeStart = events
          .where((e) => e.phase == WarmingPhase.getTimeStart)
          .map((e) => e.atMs)
          .reduce(min);
      expect(
        firstGetTimeStart,
        greaterThanOrEqualTo(lastWarmEnd),
        reason:
            'a query started at ${firstGetTimeStart}ms before the '
            'slowest warm finished at ${lastWarmEnd}ms; events: $events',
      );
    });

    test('warming barrier tolerates warm failures (cycle proceeds)', () async {
      // warmAllSources() swallows per-source warm failures, so a
      // throwing Warmable must not block the barrier nor the cycle.
      final events = <WarmingEvent>[];
      final clockSw = Stopwatch()..start();

      final healthy1 = WarmingTestSource(
        id: 'h1',
        groupId: 'g1',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
      );
      final healthy2 = WarmingTestSource(
        id: 'h2',
        groupId: 'g2',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
      );
      final broken = WarmingTestSource(
        id: 'broken',
        groupId: 'g3',
        utcMs: 1000000,
        events: events,
        clock: clockSw,
        throwAsyncFromWarm: true,
      );

      final engine = SyncEngine(
        config: config.copyWith(
          additionalSources: [healthy1, healthy2, broken],
        ),
        clock: clock,
      );

      final anchor = await engine.sync();
      expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000020));
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
    late FakeMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = FakeMonotonicClock();
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
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
}
