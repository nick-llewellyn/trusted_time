import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

void main() {
  group('SyncClock', () {
    late SyncClock clock;

    setUp(() => clock = SyncClock());
    tearDown(() => clock.dispose());

    test('elapsedSinceAnchorMs uses monotonic stopwatch, not wall clock', () {
      clock.update(1000, DateTime.now().millisecondsSinceEpoch);

      final elapsed1 = clock.elapsedSinceAnchorMs();
      expect(elapsed1, greaterThanOrEqualTo(0));
      expect(elapsed1, lessThan(100));
    });

    test('update resets the stopwatch', () async {
      clock.update(1000, DateTime.now().millisecondsSinceEpoch);
      await Future.delayed(const Duration(milliseconds: 100));
      final beforeReset = clock.elapsedSinceAnchorMs();
      expect(beforeReset, greaterThanOrEqualTo(20)); // generous lower bound

      clock.update(2000, DateTime.now().millisecondsSinceEpoch);
      final afterReset = clock.elapsedSinceAnchorMs();
      expect(afterReset, lessThan(beforeReset));
      expect(afterReset, lessThan(50));
    });

    test('elapsed increases monotonically over time', () async {
      clock.update(500, DateTime.now().millisecondsSinceEpoch);

      final t1 = clock.elapsedSinceAnchorMs();
      await Future.delayed(const Duration(milliseconds: 50));
      final t2 = clock.elapsedSinceAnchorMs();
      await Future.delayed(const Duration(milliseconds: 50));
      final t3 = clock.elapsedSinceAnchorMs();

      expect(t2, greaterThan(t1));
      expect(t3, greaterThan(t2));
    });

    test('lastUptimeMs and lastWallMs reflect last update', () {
      final wallMs = DateTime.now().millisecondsSinceEpoch;
      clock.update(42000, wallMs);

      expect(clock.lastUptimeMs, 42000);
      expect(clock.lastWallMs, wallMs);
    });

    test('dispose clears all state and stops stopwatch', () {
      clock.update(5000, DateTime.now().millisecondsSinceEpoch);
      expect(clock.lastUptimeMs, 5000);

      clock.dispose();
      expect(clock.lastUptimeMs, 0);
      expect(clock.lastWallMs, 0);
      expect(clock.elapsedSinceAnchorMs(), 0);
    });

    test('initialElapsedMs seeds elapsed time for warm-restore gap', () {
      // Regression for trusted_time-e9m: a persisted anchor restored
      // 90s after capture must report ~90s of elapsed time, not 0s.
      clock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 90000,
      );

      final elapsed = clock.elapsedSinceAnchorMs();
      expect(elapsed, greaterThanOrEqualTo(90000));
      expect(elapsed, lessThan(90100)); // small tolerance for stopwatch tick
    });

    test('initialElapsedMs accumulates with stopwatch over time', () async {
      clock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 5000,
      );

      final t1 = clock.elapsedSinceAnchorMs();
      await Future.delayed(const Duration(milliseconds: 50));
      final t2 = clock.elapsedSinceAnchorMs();

      expect(t1, greaterThanOrEqualTo(5000));
      expect(t2, greaterThan(t1));
      expect(t2 - t1, greaterThanOrEqualTo(40));
    });

    test('subsequent update without initialElapsedMs clears the offset', () {
      // A fresh sync after a warm restore must not carry the stale gap.
      clock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 60000,
      );
      expect(clock.elapsedSinceAnchorMs(), greaterThanOrEqualTo(60000));

      clock.update(2000, DateTime.now().millisecondsSinceEpoch);
      final elapsed = clock.elapsedSinceAnchorMs();
      expect(elapsed, lessThan(100));
    });

    test('dispose clears the initialElapsedMs offset', () {
      clock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 30000,
      );
      expect(clock.elapsedSinceAnchorMs(), greaterThanOrEqualTo(30000));

      clock.dispose();
      expect(clock.elapsedSinceAnchorMs(), 0);
    });
  });
}
