import 'dart:async';

import 'package:trusted_time/src/monotonic_clock.dart';

/// A [MonotonicClock] answering from mutable in-memory fields, and
/// counting the [getBootId] round-trips a test provoked.
///
/// The defaults model an app that has been up long enough for any
/// plausible consensus age to predate boot — the ordinary case for
/// tests that need a clock but do not care what it reads. Tests that
/// do care set [value] and [bootId] explicitly, either at construction
/// or between phases of a single test.
class FakeMonotonicClock implements MonotonicClock {
  FakeMonotonicClock({this.value = 100000, this.bootId = 'boot-test'});

  /// Device uptime reporting a value smaller than any plausible
  /// consensus age — models an app that started immediately after
  /// boot, for the backdating uptime-floor guard.
  FakeMonotonicClock.justBooted() : this(value: 600);

  /// Milliseconds returned by [uptimeMs]; mutable so a test can
  /// advance uptime between phases.
  int value;

  /// Identity returned by [getBootId]; mutable so a test can model a
  /// reboot, and nullable so it can model a platform that cannot
  /// supply one.
  String? bootId;

  /// Number of [getBootId] invocations, so a test can assert that a
  /// verdict was reached without paying the boot-ID IPC round trip.
  int bootIdCalls = 0;

  @override
  Future<int> uptimeMs() async => value;

  @override
  Future<String?> getBootId() async {
    bootIdCalls++;
    return bootId;
  }
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
