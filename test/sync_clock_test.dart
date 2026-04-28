import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

void main() {
  group('SyncClock', () {
    setUp(() => SyncClock.reset());
    tearDown(() => SyncClock.reset());

    test('elapsedSinceAnchorMs uses monotonic stopwatch, not wall clock', () {
      SyncClock.update(1000, DateTime.now().millisecondsSinceEpoch);

      final elapsed1 = SyncClock.elapsedSinceAnchorMs();
      expect(elapsed1, greaterThanOrEqualTo(0));
      expect(elapsed1, lessThan(100));
    });

    test('update resets the stopwatch', () async {
      SyncClock.update(1000, DateTime.now().millisecondsSinceEpoch);
      await Future.delayed(const Duration(milliseconds: 100));
      final beforeReset = SyncClock.elapsedSinceAnchorMs();
      expect(beforeReset, greaterThanOrEqualTo(20)); // generous lower bound

      SyncClock.update(2000, DateTime.now().millisecondsSinceEpoch);
      final afterReset = SyncClock.elapsedSinceAnchorMs();
      expect(afterReset, lessThan(beforeReset));
      expect(afterReset, lessThan(50));
    });

    test('elapsed increases monotonically over time', () async {
      SyncClock.update(500, DateTime.now().millisecondsSinceEpoch);

      final t1 = SyncClock.elapsedSinceAnchorMs();
      await Future.delayed(const Duration(milliseconds: 50));
      final t2 = SyncClock.elapsedSinceAnchorMs();
      await Future.delayed(const Duration(milliseconds: 50));
      final t3 = SyncClock.elapsedSinceAnchorMs();

      expect(t2, greaterThan(t1));
      expect(t3, greaterThan(t2));
    });

    test('lastUptimeMs and lastWallMs reflect last update', () {
      final wallMs = DateTime.now().millisecondsSinceEpoch;
      SyncClock.update(42000, wallMs);

      expect(SyncClock.lastUptimeMs, 42000);
      expect(SyncClock.lastWallMs, wallMs);
    });

    test('reset clears all state and stops stopwatch', () {
      SyncClock.update(5000, DateTime.now().millisecondsSinceEpoch);
      expect(SyncClock.lastUptimeMs, 5000);

      SyncClock.reset();
      expect(SyncClock.lastUptimeMs, 0);
      expect(SyncClock.lastWallMs, 0);
      expect(SyncClock.elapsedSinceAnchorMs(), 0);
    });

    test('initialElapsedMs seeds elapsed time for warm-restore gap', () {
      // Regression: a persisted anchor restored 90s after capture must
      // report ~90s of elapsed time, not 0s.
      SyncClock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 90000,
      );

      final elapsed = SyncClock.elapsedSinceAnchorMs();
      expect(elapsed, greaterThanOrEqualTo(90000));
      expect(elapsed, lessThan(90100)); // small tolerance for stopwatch tick
    });

    test('initialElapsedMs accumulates with stopwatch over time', () async {
      SyncClock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 5000,
      );

      final t1 = SyncClock.elapsedSinceAnchorMs();
      await Future.delayed(const Duration(milliseconds: 50));
      final t2 = SyncClock.elapsedSinceAnchorMs();

      expect(t1, greaterThanOrEqualTo(5000));
      expect(t2, greaterThan(t1));
      expect(t2 - t1, greaterThanOrEqualTo(40));
    });

    test('subsequent update without initialElapsedMs clears the offset', () {
      // A fresh sync after a warm restore must not carry the stale gap.
      SyncClock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 60000,
      );
      expect(SyncClock.elapsedSinceAnchorMs(), greaterThanOrEqualTo(60000));

      SyncClock.update(2000, DateTime.now().millisecondsSinceEpoch);
      final elapsed = SyncClock.elapsedSinceAnchorMs();
      expect(elapsed, lessThan(100));
    });

    test('reset clears initialElapsedMs offset', () {
      SyncClock.update(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        initialElapsedMs: 30000,
      );
      expect(SyncClock.elapsedSinceAnchorMs(), greaterThanOrEqualTo(30000));

      SyncClock.reset();
      expect(SyncClock.elapsedSinceAnchorMs(), 0);
    });
  });
}
