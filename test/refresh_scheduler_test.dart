import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/infra/refresh_scheduler.dart';

void main() {
  group('RefreshScheduler timer-field invariant', () {
    // The class contract is that a null timer field means "nothing
    // armed". Every explicit mutator pairs cancel() with = null, but a
    // timer that simply *fires* must clear its own field too — the
    // scheduler cannot rely on onTick to do it. In the engine, onTick
    // is _performSync, whose in-flight guard returns early when a cycle
    // is already running, so the callback may never reach the code that
    // would clear the field.

    // Every case disposes inside the fakeAsync zone rather than via
    // addTearDown: a tear-down runs after the zone has exited, so any
    // timer still armed at that point has already leaked. Disposing
    // in-zone also makes "nothing left armed" assertable.

    test('a fired retry timer clears retryTimerActive', () {
      fakeAsync((async) {
        final scheduler = RefreshScheduler(
          initialInterval: const Duration(minutes: 5),
          onTick: () {},
        );

        scheduler.scheduleRetry(const Duration(seconds: 2));
        expect(scheduler.retryTimerActive, isTrue);

        async.elapse(const Duration(seconds: 2));
        expect(scheduler.retryTimerActive, isFalse);

        scheduler.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a retry timer whose onTick bails early still clears the '
        'field', () {
      // Reproduces the engine's re-entry shape: the callback returns
      // without touching the scheduler, so self-clearing on fire is the
      // only thing keeping retryTimerActive honest.
      fakeAsync((async) {
        var ticks = 0;
        final scheduler = RefreshScheduler(
          initialInterval: const Duration(minutes: 5),
          onTick: () => ticks++,
        );

        scheduler.scheduleRetry(const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 2));

        expect(ticks, 1);
        expect(scheduler.retryTimerActive, isFalse);

        scheduler.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a fired refresh timer does not suppress the next arming', () {
      // scheduleRefresh cancels before re-arming, so a stale non-null
      // field would not block a re-arm — but it would leave the fired
      // Timer reachable. Pin that a fire/re-arm cycle produces exactly
      // one tick per interval rather than dropping or doubling one.
      fakeAsync((async) {
        var ticks = 0;
        late final RefreshScheduler scheduler;
        scheduler = RefreshScheduler(
          initialInterval: const Duration(minutes: 5),
          onTick: () {
            ticks++;
            scheduler.scheduleRefresh();
          },
        );

        scheduler.scheduleRefresh();
        async.elapse(const Duration(minutes: 15));

        expect(ticks, 3);

        // onTick re-arms, so a timer is still pending here by design.
        // Dispose in-zone so it does not outlive the zone.
        expect(async.pendingTimers, hasLength(1));
        scheduler.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('dispose during a pending timer suppresses the tick', () {
      fakeAsync((async) {
        var ticks = 0;
        final scheduler = RefreshScheduler(
          initialInterval: const Duration(minutes: 5),
          onTick: () => ticks++,
        );

        scheduler.scheduleRetry(const Duration(seconds: 2));
        scheduler.dispose();
        async.elapse(const Duration(seconds: 10));

        expect(ticks, 0);
        expect(scheduler.retryTimerActive, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
