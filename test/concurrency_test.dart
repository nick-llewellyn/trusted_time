import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/infra/sync_observer.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';
import 'package:trusted_time/src/infra/dns_budget.dart';

class MockMonotonicClock implements MonotonicClock {
  @override
  Future<int> uptimeMs() async => 100000;
  @override
  Future<String?> getBootId() async => 'boot-test';
}

/// Monotonic clock reporting a device uptime smaller than any
/// plausible consensus age — models an app that started immediately
/// after boot, for the backdating uptime-floor guard test.
class JustBootedMonotonicClock implements MonotonicClock {
  @override
  Future<int> uptimeMs() async => 600;
  @override
  Future<String?> getBootId() async => 'boot-test';
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
  Future<String?> getBootId() async => 'boot-test';

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

/// Test source whose sample carries an explicit [TimeSample.receivedAtMs]
/// alongside a controlled interval, so the receipt-normalization tests
/// can construct populations that only overlap after the engine shifts
/// them to a common reference instant (or, with null stamps, verify the
/// engine leaves them unshifted).
class ReceiptStampedSource implements TimeSource {
  ReceiptStampedSource(
    this.id,
    this.delay,
    this.startMs,
    this.endMs,
    this.receivedAtMs, [
    this.groupId = 'test-group',
  ]);
  @override
  final String id;
  final Duration delay;
  final int startMs;
  final int endMs;
  final int? receivedAtMs;
  @override
  final String groupId;

  @override
  Future<TimeSample> getTime() async {
    await Future.delayed(delay);
    return TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: groupId,
      receivedAtMs: receivedAtMs,
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

/// Test source that records how many times [getTime] was invoked, so the
/// colliding-id regression test can assert which of two sources sharing an
/// `id` the engine actually queries.
class CountingSource implements TimeSource {
  CountingSource(this.id, this.utcMs, [this.groupId = 'test-group']);
  @override
  final String id;
  final int utcMs;
  @override
  final String groupId;

  int callCount = 0;

  @override
  Future<TimeSample> getTime() async {
    callCount++;
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
/// consumed before early-exit fired.
///
/// Two engine paths drop samples after the completer resolves:
///   * the per-source fan-out loop in `SyncEngine.sync` guards every
///     `sampleController.add(sample)` with
///     `if (!streamClosed && !sampleController.isClosed)`, and the
///     `finally` block sets `streamClosed = true` and closes the
///     controller as soon as the completer resolves -- so a source
///     whose `getTime()` future resolves after completion has its
///     sample silently discarded before it ever reaches the listener;
///   * if a sample is already queued on the stream when the completer
///     completes, the listener's `if (completer.isCompleted) return;`
///     guard at the top short-circuits before invoking the observer.
///
/// The combined effect is that a sample is recorded by this observer
/// only if it reaches the listener before the completer resolves. The
/// "no recorded sample after early-exit" guarantee therefore relies
/// on the test pool's source delays leaving a comfortable wall-clock
/// margin between the last "expected" arrival and the first "should
/// be dropped" arrival -- the stability-guard tests below pin that
/// margin at 300 ms (last expected at 100 ms, first dropped at 400
/// ms), which is large compared to the few microtasks the engine
/// needs between firing early-exit and the completer resolving.
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
    late MockMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = MockMonotonicClock();
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

  group('SyncEngine fail-closed trust resolution', () {
    late MockMonotonicClock clock;

    setUp(() {
      clock = MockMonotonicClock();
    });

    test(
      'invalid trust config fails closed even when ntsServers is empty',
      () async {
        // Regression: effectiveTrustMode used to be resolved only inside
        // the ntsServers comprehension, so an invalid config
        // (usePlatformTrust: true + non-empty customRootCerts) with an
        // empty ntsServers list skipped the ArgumentError entirely and
        // still built NTP/additional sources — bypassing the
        // "fail closed before any source is built" guarantee asserted in
        // the Secure Time Contract. The resolver is now read once up
        // front in _buildSources, so source construction fails closed
        // regardless of whether any NTS server is configured.
        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            usePlatformTrust: true,
            customRootCerts: [1, 2, 3],
          ),
          clock: clock,
        );

        // _sources is late-built on first access; warmAllSources is the
        // public trigger that reaches it, surfacing the ArgumentError on
        // the returned Future.
        await expectLater(engine.warmAllSources(), throwsArgumentError);
      },
    );

    test(
      'valid config with empty ntsServers builds without over-rejecting',
      () async {
        // Positive control: the up-front resolution must not reject a
        // valid config. bundledOnly (the effective default) is valid, so
        // source construction succeeds even with no NTS servers present.
        final engine = SyncEngine(
          config: const TrustedTimeConfig(ntpServers: [], ntsServers: []),
          clock: clock,
        );

        await expectLater(engine.warmAllSources(), completes);
      },
    );
  });

  group('SyncEngine TransientSourceError handling', () {
    late MockMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = MockMonotonicClock();
      // Override every default source list so the engine only queries
      // the test's `additionalSources`. Without `ntsServers: const []`,
      // the default `['time.cloudflare.com']` would instantiate an
      // NtsSource that either fails fast (NtsRustLib.init not called in
      // the test harness) or attempts real network I/O on machines
      // where the native is initialised — both are unrelated noise
      // for the cooldown-semantics assertion.
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
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

  group('SyncEngine quality-tracker integration (4em, a4d)', () {
    late MockMonotonicClock clock;
    late TrustedTimeConfig config;

    setUp(() {
      clock = MockMonotonicClock();
      // ntsServers: [] keeps the default Cloudflare NtsSource out of the
      // pool (see the TransientSourceError group for the full rationale).
      config = const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        ntpServers: [],
        ntsServers: [],
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
          ntpServers: [],
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
          ntpServers: [],
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

  group('SyncEngine receipt normalization', () {
    // Samples estimate the true time at their own receipt instant, so
    // two accurate sources whose responses land seconds apart produce
    // intervals that do not overlap at all in absolute terms — the
    // exact failure signature seen on a just-woken radio, where the
    // first response rides a stalling link. The engine shifts every
    // stamped sample to the latest receipt instant before Marzullo
    // intersection (SyncEngine._normalizedToLatestReceipt), so receipt
    // spread alone can no longer break quorum.

    test('samples received seconds apart reach quorum after '
        'normalization', () async {
      // Both sources estimate the same true time with ±50 ms
      // uncertainty, but s2's response arrives 3 s after s1's. In
      // absolute terms the intervals are disjoint ([999950,1000050]
      // vs [1002950,1003050]); normalized to s2's receipt instant,
      // s1's interval shifts forward by 3000 ms and they coincide.
      final s1 = ReceiptStampedSource(
        's1',
        const Duration(milliseconds: 10),
        999950,
        1000050,
        1000000,
        'g1',
      );
      final s2 = ReceiptStampedSource(
        's2',
        const Duration(milliseconds: 30),
        1002950,
        1003050,
        1003000,
        'g2',
      );

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 1,
          ntpServers: [],
          ntsServers: [],
        ).copyWith(additionalSources: [s1, s2]),
        clock: MockMonotonicClock(),
      );

      final anchor = await engine.sync();
      // Consensus forms at the shared reference (s2's receipt), where
      // both normalized intervals are [1002950,1003050].
      expect(anchor.networkUtcMs, closeTo(1003000, 60));
    });

    test(
      'unstamped samples are consumed unshifted (legacy behaviour)',
      () async {
        // Same disjoint intervals but no receipt stamps: the engine has
        // no basis to normalize, so the cycle must still fail quorum
        // exactly as before the receivedAtMs field existed.
        final s1 = ReceiptStampedSource(
          's1',
          const Duration(milliseconds: 10),
          999950,
          1000050,
          null,
          'g1',
        );
        final s2 = ReceiptStampedSource(
          's2',
          const Duration(milliseconds: 30),
          1002950,
          1003050,
          null,
          'g2',
        );

        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            minimumQuorum: 2,
            minGroupCount: 1,
            ntpServers: [],
            ntsServers: [],
          ).copyWith(additionalSources: [s1, s2]),
          clock: MockMonotonicClock(),
        );

        await expectLater(
          engine.sync(),
          throwsA(isA<TrustedTimeSyncException>()),
        );
      },
    );

    test('mixed population: stamped samples normalize, unstamped pass '
        'through', () async {
      // s1 and s2 are stamped 2 s apart and normalize onto each other;
      // s3 is unstamped but its absolute interval already overlaps the
      // normalized pair at the reference instant, so all three
      // participate.
      final s1 = ReceiptStampedSource(
        's1',
        const Duration(milliseconds: 10),
        999950,
        1000050,
        1000000,
        'g1',
      );
      final s2 = ReceiptStampedSource(
        's2',
        const Duration(milliseconds: 30),
        1001950,
        1002050,
        1002000,
        'g2',
      );
      final s3 = ReceiptStampedSource(
        's3',
        const Duration(milliseconds: 50),
        1001940,
        1002060,
        null,
        'g3',
      );

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 3,
          minGroupCount: 1,
          ntpServers: [],
          ntsServers: [],
        ).copyWith(additionalSources: [s1, s2, s3]),
        clock: MockMonotonicClock(),
      );

      final anchor = await engine.sync();
      expect(anchor.networkUtcMs, closeTo(1002000, 60));
    });

    test('anchor readings are backdated by the consensus reference '
        'age', () async {
      // The consensus UTC is valid at the normalization reference (the
      // latest receipt stamp), but uptimeMs/wallMs are read later, in
      // _createAnchor. The engine subtracts the measured age so all
      // anchor fields describe the reference instant. A scripted
      // receipt reader makes the age deterministic: stamps land at
      // 1000 and 2000 ms, anchor creation observes 3500 ms → age 1500.
      var micros = 0;
      TimeSample.debugSetReceiptReader(
        MonotonicReader(read: () => micros, isSleepAware: true),
      );
      addTearDown(() => TimeSample.debugSetReceiptReader(null));
      micros = 3_500_000;

      final s1 = ReceiptStampedSource(
        's1',
        const Duration(milliseconds: 10),
        999950,
        1000050,
        1000,
        'g1',
      );
      final s2 = ReceiptStampedSource(
        's2',
        const Duration(milliseconds: 30),
        1000950,
        1001050,
        2000,
        'g2',
      );

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 1,
          ntpServers: [],
          ntsServers: [],
        ).copyWith(additionalSources: [s1, s2]),
        clock: MockMonotonicClock(),
      );

      final anchor = await engine.sync();
      // MockMonotonicClock reads 100000; receipt age is 3500 − 2000.
      expect(anchor.uptimeMs, 100000 - 1500);
    });

    test('stamps on an unrelated scale do not corrupt the anchor', () async {
      // Synthetic fixture stamps (here: absolute-wall-scale values far
      // beyond the process receipt timeline) yield a negative or
      // over-budget raw age; both degenerate cases must fall back to
      // the unbackdated readings rather than skew the anchor.
      final s1 = ReceiptStampedSource(
        's1',
        const Duration(milliseconds: 10),
        999950,
        1000050,
        1000000,
        'g1',
      );
      final s2 = ReceiptStampedSource(
        's2',
        const Duration(milliseconds: 30),
        999950,
        1000050,
        1000000,
        'g2',
      );

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 1,
          ntpServers: [],
          ntsServers: [],
        ).copyWith(additionalSources: [s1, s2]),
        clock: MockMonotonicClock(),
      );

      final anchor = await engine.sync();
      expect(anchor.uptimeMs, 100000);
    });

    test('an age exceeding the device uptime does not backdate the '
        'anchor', () async {
      // Just-booted device: uptime (600 ms) is smaller than the
      // measured consensus age (1500 ms). Subtracting would yield a
      // negative uptimeMs, breaking the "ms since boot" invariant, so
      // the engine must fall back to the unbackdated readings.
      var micros = 0;
      TimeSample.debugSetReceiptReader(
        MonotonicReader(read: () => micros, isSleepAware: true),
      );
      addTearDown(() => TimeSample.debugSetReceiptReader(null));
      micros = 3_500_000;

      final s1 = ReceiptStampedSource(
        's1',
        const Duration(milliseconds: 10),
        999950,
        1000050,
        1000,
        'g1',
      );
      final s2 = ReceiptStampedSource(
        's2',
        const Duration(milliseconds: 30),
        1000950,
        1001050,
        2000,
        'g2',
      );

      final engine = SyncEngine(
        config: const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 1,
          ntpServers: [],
          ntsServers: [],
        ).copyWith(additionalSources: [s1, s2]),
        clock: JustBootedMonotonicClock(),
      );

      final anchor = await engine.sync();
      expect(anchor.uptimeMs, 600);
    });
  });

  group('DnsBudget (ADR 0008)', () {
    test('a cache hit does not consume a permit', () async {
      final budget = DnsBudget(2);
      var calls = 0;
      Future<List<int>> resolve() async {
        calls++;
        return const [1, 2, 3];
      }

      expect(await budget.guard('h', resolve), const [1, 2, 3]);
      expect(calls, 1);
      expect(budget.availablePermits, 2);

      // A second lookup for the same key within the TTL is served from
      // cache: resolve is not re-run and no permit is taken.
      expect(await budget.guard('h', resolve), const [1, 2, 3]);
      expect(calls, 1);
      expect(budget.availablePermits, 2);
    });

    test('serialises uncached lookups beyond the cap, then releases', () async {
      final budget = DnsBudget(1);
      final gate = Completer<void>();
      var active = 0;
      var maxActive = 0;
      Future<List<int>> slow(String key) => budget.guard(key, () async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        await gate.future;
        active--;
        return const [0];
      });

      final a = slow('a');
      final b = slow('b');
      await Future<void>.delayed(Duration.zero);
      // Only one lookup may be in flight under a cap of 1.
      expect(maxActive, 1);

      gate.complete();
      await Future.wait([a, b]);
      expect(maxActive, 1);
      expect(budget.availablePermits, 1);
    });

    test(
      'throws DnsBudgetSaturation when no permit frees up in time',
      () async {
        final budget = DnsBudget(
          1,
          acquireTimeout: const Duration(milliseconds: 50),
        );
        final held = Completer<List<int>>();
        // Occupy the only permit until the test releases it.
        unawaited(budget.guard('holder', () => held.future));
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          budget.guard('blocked', () async => const [0]),
          throwsA(isA<DnsBudgetSaturation>()),
        );
        held.complete(const [0]);
      },
    );

    test('a resolution error propagates and frees the permit', () async {
      final budget = DnsBudget(1);
      await expectLater(
        budget.guard('h', () async => throw const FormatException('boom')),
        throwsA(isA<FormatException>()),
      );
      // The permit must have been released despite the failure.
      expect(budget.availablePermits, 1);
    });

    test('rejects a non-positive maxConcurrent with ArgumentError', () {
      // Runtime validation (not assert): the type is instantiable outside
      // TrustedTimeConfig, and a stripped assert in release would let
      // DnsBudget(0) construct and then deny every lookup forever.
      expect(() => DnsBudget(0), throwsArgumentError);
      expect(() => DnsBudget(-1), throwsArgumentError);
    });

    test('rejects a non-positive acquireTimeout or cacheTtl', () {
      expect(
        () => DnsBudget(1, acquireTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => DnsBudget(1, cacheTtl: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    });

    test('exposes its admission window via acquireTimeout', () {
      const window = Duration(milliseconds: 250);
      expect(DnsBudget(2, acquireTimeout: window).acquireTimeout, window);
    });
  });

  group('SyncEngine.isCertValidityFailure classification', () {
    // Strong signal: rustls diagnostics naming the validity window.
    const positives = <Object>[
      nts.NtsErrorKeProtocol(message: 'invalid peer certificate: Expired'),
      nts.NtsErrorKeProtocol(message: 'invalid peer certificate: NotValidYet'),
      nts.NtsErrorKeProtocol(message: 'certificate not valid yet'),
      // Weak signal: TLS-phase timeout (middlebox killed the handshake).
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.tls),
    ];
    for (final e in positives) {
      test('accepts $e', () {
        expect(SyncEngine.isCertValidityFailure(e), isTrue);
      });
    }

    const negatives = <Object>[
      nts.NtsErrorKeProtocol(message: 'unexpected KE record type 42'),
      // Shares rustls's generic `invalid peer certificate` prefix but
      // is not a validity-window problem: must not arm the rescue.
      nts.NtsErrorKeProtocol(
        message: 'invalid peer certificate: UnknownIssuer',
      ),
      nts.NtsErrorKeProtocol(message: 'invalid peer certificate: BadSignature'),
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.connect),
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.dnsTimeout),
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.ntp),
      nts.NtsErrorAuthentication(message: 'AEAD open failed'),
      FormatException('not an nts error at all'),
    ];
    for (final e in negatives) {
      test('rejects $e', () {
        expect(SyncEngine.isCertValidityFailure(e), isFalse);
      });
    }
  });

  group('SyncEngine pre-sync rescue orchestration', () {
    late MockMonotonicClock clock;

    /// Coarse instant far above the plausibility floor.
    final plausibleCoarse = DateTime.utc(2026, 7, 20, 12);

    setUp(() {
      clock = MockMonotonicClock();
    });

    SyncEngine buildEngine(List<TimeSource> sources, {int minimumQuorum = 1}) =>
        SyncEngine(
          config: TrustedTimeConfig(
            ntpServers: const [],
            ntsServers: const [],
            minimumQuorum: minimumQuorum,
            minGroupCount: 1,
            additionalSources: sources,
            maxLatency: const Duration(milliseconds: 500),
          ),
          clock: clock,
        );

    TimeSample probeSample(DateTime instant) => TimeSample(
      interval: TimeInterval(
        startMs: instant.millisecondsSinceEpoch - 50,
        endMs: instant.millisecondsSinceEpoch + 50,
      ),
      sourceId: 'ntp:probe.example',
      groupId: 'probe',
    );

    test(
      'cold-start cert failure arms rescue, retry succeeds, state clears',
      () async {
        // Two sources: Marzullo consensus needs at least two samples.
        final a = RescuableNtsSource('nts:skewed-a.example', utcMs: 1000000);
        final b = RescuableNtsSource('nts:skewed-b.example', utcMs: 1000000);
        final engine = buildEngine([a, b]);
        a.engine = engine;
        b.engine = engine;
        engine.rescueProbeOverride = () async => probeSample(plausibleCoarse);

        final anchor = await engine.sync();

        expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000010));
        // First attempt ran unarmed (null); the retry ran with the
        // coarse instant (the probe interval midpoint) pinned.
        for (final s in [a, b]) {
          expect(
            s.observedVerificationTimes.whereType<DateTime>().single,
            plausibleCoarse,
          );
        }
        // Rescue instant is cleared once the retry cycle settles.
        expect(engine.debugRescueVerificationTime, isNull);
        expect(engine.rescueAttempted, isTrue);
      },
    );

    test('rescue prefers NTP samples already collected this cycle', () async {
      final ntsSource = RescuableNtsSource(
        'nts:skewed.example',
        utcMs: plausibleCoarse.millisecondsSinceEpoch,
      );
      // An NTP-prefixed sibling that succeeds during the failing
      // cycle; its sample's midpoint is the expected coarse estimate.
      // Quorum 2 forces the first cycle to fail even though the
      // sibling produced a sample.
      final ntpSibling = RaceConditionSource(
        '${TimeSource.prefixNtp}sibling.example',
        const Duration(milliseconds: 5),
        plausibleCoarse.millisecondsSinceEpoch,
        'g-ntp',
      );
      final engine = buildEngine([ntsSource, ntpSibling], minimumQuorum: 2);
      ntsSource.engine = engine;
      var probeCalled = false;
      engine.rescueProbeOverride = () async {
        probeCalled = true;
        throw StateError('probe must not run when cycle samples exist');
      };

      final anchor = await engine.sync();
      expect(probeCalled, isFalse);
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>().single,
        plausibleCoarse,
      );
      expect(
        anchor.networkUtcMs,
        inInclusiveRange(
          plausibleCoarse.millisecondsSinceEpoch - 20,
          plausibleCoarse.millisecondsSinceEpoch + 20,
        ),
      );
    });

    test('rescue is one-shot: second cert failure does not re-arm', () async {
      final ntsSource = RescuableNtsSource(
        'nts:skewed.example',
        utcMs: 1000000,
        healAfterRescue: false,
      );
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      var probeCalls = 0;
      engine.rescueProbeOverride = () async {
        probeCalls++;
        return probeSample(plausibleCoarse);
      };

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(probeCalls, 1);
      expect(engine.rescueAttempted, isTrue);
      expect(engine.debugRescueVerificationTime, isNull);

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      // No second probe: the one-shot latch held.
      expect(probeCalls, 1);
    });

    test('no rescue without a coarse estimate (empty ntpServers, no '
        'cycle samples): original error propagates', () async {
      final ntsSource = RescuableNtsSource('nts:skewed.example', utcMs: 0);
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      // No probe override and no ntpServers: rescue unavailable.

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(engine.rescueAttempted, isTrue);
      // The NTS source only ever saw null verification times — the
      // rescue was never armed.
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>(),
        isEmpty,
      );
    });

    test('coarse estimate below the plausibility floor is rejected', () async {
      final ntsSource = RescuableNtsSource('nts:skewed.example', utcMs: 0);
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      final backdated = SyncEngine.rescueFloorUtc.subtract(
        const Duration(days: 365),
      );
      engine.rescueProbeOverride = () async => probeSample(backdated);

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>(),
        isEmpty,
      );
    });

    test('a backdated cycle sample is skipped, not allowed to poison '
        'the rescue while a plausible sibling exists', () async {
      // Two NTP siblings succeed during the failing cycle: a backdated
      // one (broken server / replayed old time) that completes first,
      // and a plausible one. The plausibility floor must act as a
      // per-candidate filter inside acquisition — skipping the poison
      // and arming from the plausible sibling — rather than a single
      // post-selection gate that would reject the whole rescue because
      // best-candidate selection happened to pick the poison.
      final backdatedMs = SyncEngine.rescueFloorUtc
          .subtract(const Duration(days: 365))
          .millisecondsSinceEpoch;
      final ntsSource = RescuableNtsSource(
        'nts:skewed.example',
        utcMs: plausibleCoarse.millisecondsSinceEpoch,
      );
      final poisonedSibling = RaceConditionSource(
        '${TimeSource.prefixNtp}poisoned.example',
        const Duration(milliseconds: 5),
        backdatedMs,
        'g-ntp-poison',
      );
      final plausibleSibling = RaceConditionSource(
        '${TimeSource.prefixNtp}plausible.example',
        const Duration(milliseconds: 10),
        plausibleCoarse.millisecondsSinceEpoch,
        'g-ntp-ok',
      );
      // The two NTP intervals are disjoint, so the first cycle cannot
      // reach quorum 2 without the (cert-failing) NTS source.
      final engine = buildEngine([
        ntsSource,
        poisonedSibling,
        plausibleSibling,
      ], minimumQuorum: 2);
      ntsSource.engine = engine;
      var probeCalled = false;
      engine.rescueProbeOverride = () async {
        probeCalled = true;
        throw StateError('probe must not run when cycle samples exist');
      };

      final anchor = await engine.sync();
      expect(probeCalled, isFalse);
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>().single,
        plausibleCoarse,
      );
      expect(
        anchor.networkUtcMs,
        inInclusiveRange(
          plausibleCoarse.millisecondsSinceEpoch - 20,
          plausibleCoarse.millisecondsSinceEpoch + 20,
        ),
      );
    });

    test('no rescue once an anchor exists (warm engine)', () async {
      // Both succeed on the first cycle (anchoring the engine), then
      // fail every subsequent cycle with a cert-validity signature.
      final a = RescuableNtsSource(
        'nts:flaky-a.example',
        utcMs: 1000000,
        succeedFirstCall: true,
        healAfterRescue: false,
      );
      final b = RescuableNtsSource(
        'nts:flaky-b.example',
        utcMs: 1000000,
        succeedFirstCall: true,
        healAfterRescue: false,
      );
      final engine = buildEngine([a, b]);
      a.engine = engine;
      b.engine = engine;
      var probeCalls = 0;
      engine.rescueProbeOverride = () async {
        probeCalls++;
        throw StateError('unreachable');
      };

      await engine.sync();

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(probeCalls, 0);
      expect(engine.rescueAttempted, isFalse);
    });

    test('non-cert NTS failure does not trigger the rescue', () async {
      final ntsSource = RescuableNtsSource(
        'nts:down.example',
        utcMs: 0,
        error: const nts.NtsErrorTimeout(phase: nts.TimeoutPhase.connect),
        healAfterRescue: false,
      );
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      var probeCalls = 0;
      engine.rescueProbeOverride = () async {
        probeCalls++;
        throw StateError('unreachable');
      };

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(probeCalls, 0);
      expect(engine.rescueAttempted, isFalse);
    });
  });
}

/// Fake NTS-prefixed source scripting the cold-start clock-skew
/// deadlock: a [getTime] call made *without* a rescue verification
/// instant armed on the [engine] fails with a certificate
/// validity-window error, while a call made while the instant is
/// armed succeeds (unless [healAfterRescue] is false — modelling a
/// server whose certificate is genuinely broken).
///
/// The fake mirrors a real [NtsSource]'s wiring by reading the
/// engine's rescue state at each call via
/// [SyncEngine.debugRescueVerificationTime], recording what would
/// have been forwarded to `package:nts` in
/// [observedVerificationTimes]. The [engine] reference is set by the
/// test after construction (the engine needs the source list at
/// construction time, so the reference is circular by necessity).
class RescuableNtsSource implements TimeSource {
  RescuableNtsSource(
    this.id, {
    required this.utcMs,
    this.error = const nts.NtsErrorKeProtocol(
      message: 'invalid peer certificate: Expired',
    ),
    this.healAfterRescue = true,
    this.succeedFirstCall = false,
  });

  @override
  final String id;

  @override
  String get groupId => 'g-nts';

  /// Midpoint reported when the source succeeds.
  final int utcMs;

  /// Error thrown while the deadlock holds.
  final Object error;

  /// Whether an armed rescue instant heals the source.
  final bool healAfterRescue;

  /// Whether the very first call succeeds unconditionally (used to
  /// anchor an engine before scripting failures).
  final bool succeedFirstCall;

  /// Engine whose rescue state this fake consults.
  SyncEngine? engine;

  var _calls = 0;

  /// Verification instants observed at each [getTime] call (null when
  /// no rescue was armed).
  final observedVerificationTimes = <DateTime?>[];

  @override
  Future<TimeSample> getTime() async {
    _calls++;
    final armed = engine?.debugRescueVerificationTime;
    observedVerificationTimes.add(armed);
    final healed = armed != null && healAfterRescue;
    final firstFreebie = succeedFirstCall && _calls == 1;
    if (!healed && !firstFreebie) {
      throw error;
    }
    return TimeSample(
      interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}
