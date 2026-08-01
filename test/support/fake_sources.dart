import 'dart:async';

import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/sources/nts_auth_level.dart';

/// A [TimeSource] whose sample interval, auth level, and trust backend are
/// fully specified so tier classification can be exercised deterministically.
///
/// Callers drive the real engine with these rather than stubbing an
/// assessment, because a verified assessment is only reachable by
/// establishing a genuine anchor through a live sync.
class TierSource implements TimeSource {
  TierSource({
    required this.id,
    required this.groupId,
    required this.startMs,
    required this.endMs,
    this.authLevel = NtsAuthLevel.none,
    this.trustBackend,
  });

  @override
  final String id;
  @override
  final String groupId;
  final int startMs;
  final int endMs;
  final NtsAuthLevel authLevel;
  final nts.TrustBackend? trustBackend;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: startMs, endMs: endMs),
    sourceId: id,
    groupId: groupId,
    authLevel: authLevel,
    trustBackend: trustBackend,
  );
}

/// A deterministic [TimeSource] centred on a fixed UTC instant with a
/// ±15ms uncertainty interval, optionally scripted to throw — always
/// ([shouldThrow]) or for the first [failuresBeforeSuccess] queries only
/// (modelling a transient outage that recovers, e.g. a just-woken radio).
class FakeSource implements TimeSource {
  FakeSource({
    required this.idValue,
    required this.groupIdValue,
    required this.utc,
    this.shouldThrow = false,
    this.failuresBeforeSuccess = 0,
    this.delayMs = 30,
  });

  final String idValue;
  final String groupIdValue;
  final DateTime utc;
  final bool shouldThrow;
  final int failuresBeforeSuccess;

  /// Round trip reported on every sample, mutable so one source can be
  /// walked across a simulated network move between cycles.
  int delayMs;

  /// Total [getTime] invocations, across engine instances.
  int calls = 0;

  @override
  String get id => idValue;

  @override
  String get groupId => groupIdValue;

  @override
  Future<TimeSample> getTime() async {
    calls++;
    if (shouldThrow || calls <= failuresBeforeSuccess) {
      throw Exception('source down');
    }
    final mid = utc.millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(startMs: mid - 15, endMs: mid + 15),
      sourceId: idValue,
      groupId: groupIdValue,
      delayMs: delayMs,
    );
  }
}

/// A [TimeSource] centred on a fixed instant that answers after a
/// caller-supplied [delay], so tests can script the order in which
/// sources resolve within a single sync cycle.
///
/// The delay is the whole point: passing [Duration.zero] to several
/// sources lands their samples in the same microtask drain, while
/// staggered delays interleave them across event-loop turns.
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

/// A [TimeSource] centred on a fixed instant that tallies its own
/// [getTime] invocations, so a test can prove how often one particular
/// source was queried.
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

/// Mutable midpoint shared across sync cycles so a test can move
/// "network time" between cycles.
class MidpointBox {
  MidpointBox(this.midpointMs);
  int midpointMs;
}

/// Shared getTime() tally so a test can count how many queries actually
/// executed independently of which ranked source the engine selected.
class ProbeCounter {
  int count = 0;
}

/// A [TimeSource] that reports an interval centred on a [MidpointBox]
/// so consensus can be driven deterministically.
class BoxedSource implements TimeSource {
  BoxedSource(this.box, {required this.id, required this.groupId});

  final MidpointBox box;
  @override
  final String id;
  @override
  final String groupId;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(
      startMs: box.midpointMs - halfWidthMs,
      endMs: box.midpointMs + halfWidthMs,
    ),
    sourceId: id,
    groupId: groupId,
  );
}

/// A [BoxedSource] variant that tallies every getTime() call into a
/// shared [ProbeCounter].
class BoxedCountingSource implements TimeSource {
  BoxedCountingSource(
    this.box, {
    required this.id,
    required this.groupId,
    required this.counter,
  });

  final MidpointBox box;
  @override
  final String id;
  @override
  final String groupId;
  final ProbeCounter counter;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async {
    counter.count++;
    return TimeSample(
      interval: TimeInterval(
        startMs: box.midpointMs - halfWidthMs,
        endMs: box.midpointMs + halfWidthMs,
      ),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// A [TimeSource] whose every query throws, driving the engine into a
/// quorum failure — the transient classification path.
class FailingSource implements TimeSource {
  FailingSource({required this.id, required this.groupId});

  @override
  final String id;
  @override
  final String groupId;

  @override
  Future<TimeSample> getTime() async => throw Exception('unreachable host');
}

/// A [TimeSource] whose [getTime] always throws a [StateError], to
/// exercise the per-source failure logging path.
class FailingNtsSource implements TimeSource {
  @override
  final String id = 'nts:fail';
  @override
  final String groupId = 'gfail';

  @override
  Future<TimeSample> getTime() async => throw StateError('source boom');
}

/// A [TimeSource] blocked on an external gate, letting a test hold the
/// first sync cycle in flight and release it deterministically.
///
/// [entered] (optional) resolves when [getTime] is first invoked. In a
/// cycle, `onSyncStarted` strictly precedes the source queries and the
/// impl's in-flight guard is armed before the engine's `sync()` is
/// awaited — so a test awaiting [entered] knows both have happened.
class GatedSource implements TimeSource {
  GatedSource(
    this._gate, {
    required this.id,
    required this.groupId,
    this.entered,
  });

  final Completer<void> _gate;
  final Completer<void>? entered;
  @override
  final String id;
  @override
  final String groupId;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async {
    if (entered != null && !entered!.isCompleted) entered!.complete();
    await _gate.future;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(
        startMs: nowMs - halfWidthMs,
        endMs: nowMs + halfWidthMs,
      ),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// A [TimeSource] that answers immediately until the flag flips, then
/// blocks on the gate — so a test can establish an anchor with the
/// first cycle and hold a *subsequent* cycle in flight.
class GatedThenBoxedSource implements TimeSource {
  GatedThenBoxedSource(
    this._gateActive,
    this._gate, {
    required this.id,
    required this.groupId,
  });

  final bool Function() _gateActive;
  final Completer<void> _gate;
  @override
  final String id;
  @override
  final String groupId;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async {
    if (_gateActive()) await _gate.future;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(
        startMs: nowMs - halfWidthMs,
        endMs: nowMs + halfWidthMs,
      ),
      sourceId: id,
      groupId: groupId,
    );
  }
}
