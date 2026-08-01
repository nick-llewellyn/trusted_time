import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/vantage_baseline.dart';

/// Folds [cycles] identical observations of [rttMs] into [start].
VantageBaseline settle(
  VantageBaseline start,
  int rttMs, {
  int cycles = 6,
  int responders = 5,
}) {
  var b = start;
  for (var i = 0; i < cycles; i++) {
    b = b.observe(List.filled(responders, rttMs));
  }
  return b;
}

void main() {
  group('observability gate', () {
    test('a cycle below the responder floor is not evidence', () {
      // Two survivors of a partial outage measure whichever hosts
      // happened to answer, not the vantage.
      const fresh = VantageBaseline();
      expect(fresh.observe([20, 22]), fresh);
      expect(fresh.observe(const <int>[]), fresh);
    });

    test('negative round trips are discarded before the floor applies', () {
      // A negative delay is not a fast host; dropping it can take the
      // cycle below the floor, which is the correct outcome.
      const fresh = VantageBaseline();
      expect(fresh.observe([-1, -1, 20]), fresh);
    });

    test('the first observable cycle seeds the baseline at its median', () {
      final b = const VantageBaseline().observe([10, 20, 30, 500, 500]);
      // Median, not mean: two badly-routed hosts do not move it.
      expect(b.ewmaRttMs, 30);
      expect(b.observationCount, 1);
      expect(b.epoch, 0);
    });

    test('an even sample count averages the middle pair', () {
      final b = const VantageBaseline().observe([10, 20, 30, 40]);
      expect(b.ewmaRttMs, 25);
    });
  });

  group('warmup', () {
    test('a cold baseline cannot report a shift', () {
      // One observation is a baseline of itself. Without the warmup
      // gate the second cycle would compare against an unsmoothed
      // single sample and fire on ordinary variance.
      var b = const VantageBaseline().observe([20, 20, 20]);
      expect(b.isWarm, isFalse);
      b = b.observe([400, 400, 400]);
      b = b.observe([400, 400, 400]);
      expect(b.epoch, 0, reason: 'shift suppressed until warm');
    });

    test('warmth is reached after the third observation', () {
      var b = const VantageBaseline();
      for (var i = 0; i < 3; i++) {
        b = b.observe([20, 20, 20]);
      }
      expect(b.isWarm, isTrue);
    });
  });

  group('shift detection', () {
    test('a sustained latency jump opens a new epoch', () {
      final home = settle(const VantageBaseline(), 25);
      expect(home.epoch, 0);

      // First out-of-band cycle debounces rather than firing.
      final pending = home.observe([180, 180, 180, 180]);
      expect(pending.epoch, 0);
      expect(pending.pendingShiftCount, 1);
      expect(
        pending.ewmaRttMs,
        home.ewmaRttMs,
        reason:
            'a suspected shift must not drag the baseline it is '
            'being measured against',
      );

      final moved = pending.observe([180, 180, 180, 180]);
      expect(moved.epoch, 1);
      expect(
        moved.ewmaRttMs,
        180,
        reason:
            'epoch boundary replaces, not '
            'smooths',
      );
      expect(moved.observationCount, 1, reason: 'warmup restarts');
      expect(moved.pendingShiftCount, 0);
    });

    test('a single congested cycle is weather, not a move', () {
      final home = settle(const VantageBaseline(), 25);
      final spike = home.observe([180, 180, 180, 180]);
      expect(spike.pendingShiftCount, 1);

      final recovered = spike.observe([26, 26, 26, 26]);
      expect(recovered.epoch, 0);
      expect(recovered.pendingShiftCount, 0, reason: 'debounce resets');
      expect(recovered.ewmaRttMs, closeTo(25.2, 0.5));
    });

    test('a move toward the network fires on the same evidence', () {
      // Symmetric by construction: leaving a high-latency vantage
      // invalidates the rankings exactly as much as entering one.
      final far = settle(const VantageBaseline(), 200);
      final near = settle(far, 20, cycles: 2);
      expect(near.epoch, 1);
      expect(near.ewmaRttMs, 20);
    });

    test('ordinary drift never fires, however far it accumulates', () {
      // The baseline follows a slow walk, so a vantage that degrades
      // gradually is tracked rather than treated as a move.
      var b = settle(const VantageBaseline(), 25);
      for (var rtt = 25; rtt <= 200; rtt += 5) {
        b = b.observe(List.filled(4, rtt));
      }
      expect(b.epoch, 0);
      expect(b.ewmaRttMs, greaterThan(150));
    });

    test('the absolute floor suppresses ratio shifts at the fast end', () {
      // 10ms -> 25ms clears the 1.8x ratio and is unremarkable.
      final b = settle(const VantageBaseline(), 10);
      final after = settle(b, 25, cycles: 2);
      expect(after.epoch, 0);
    });

    test('the ratio suppresses absolute shifts at the slow end', () {
      // 300ms -> 345ms clears the 40ms floor but is a 1.15x change.
      final b = settle(const VantageBaseline(), 300);
      final after = settle(b, 345, cycles: 2);
      expect(after.epoch, 0);
    });

    test('epochs accumulate across successive moves', () {
      var b = settle(const VantageBaseline(), 25);
      b = settle(b, 200, cycles: 2);
      expect(b.epoch, 1);
      b = settle(b, 25, cycles: 5);
      expect(b.epoch, 2);
    });
  });
}
