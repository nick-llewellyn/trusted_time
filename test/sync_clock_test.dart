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

  group('SyncClock with injected reader', () {
    MonotonicReader fakeReader(
      int Function() read, {
      bool isSleepAware = true,
    }) => MonotonicReader(read: read, isSleepAware: isSleepAware);

    test('projects elapsed time from reader deltas, sleep included', () {
      // A sleep-aware reader keeps advancing during suspend; simulate a
      // 2-hour jump between readings that a Stopwatch would never show.
      var nowMicros = 5000000;
      final injected = SyncClock(
        readerFactory: () => fakeReader(() => nowMicros),
      );
      addTearDown(injected.dispose);

      injected.update(1000, 0);
      expect(injected.elapsedSinceAnchorMs(), 0);

      nowMicros += const Duration(hours: 2).inMicroseconds;
      expect(
        injected.elapsedSinceAnchorMs(),
        const Duration(hours: 2).inMilliseconds,
      );
    });

    test('re-resolves the reader on every update', () {
      var resolutions = 0;
      const nowMicros = 0;
      final injected = SyncClock(
        readerFactory: () {
          resolutions++;
          return fakeReader(() => nowMicros);
        },
      );
      addTearDown(injected.dispose);

      injected.update(1000, 0);
      injected.update(2000, 0);
      expect(resolutions, 2);
    });

    test('anchor reading and reader are captured together on update', () {
      var nowMicros = 42000000;
      final injected = SyncClock(
        readerFactory: () => fakeReader(() => nowMicros),
      );
      addTearDown(injected.dispose);

      injected.update(1000, 0);
      nowMicros += 7000000;
      injected.update(2000, 0);
      // Re-anchored at the advanced reading: elapsed restarts from zero.
      expect(injected.elapsedSinceAnchorMs(), 0);
    });

    test('initialElapsedMs stacks on top of reader deltas', () {
      var nowMicros = 0;
      final injected = SyncClock(
        readerFactory: () => fakeReader(() => nowMicros),
      );
      addTearDown(injected.dispose);

      injected.update(1000, 0, initialElapsedMs: 90000);
      nowMicros += 1500000;
      expect(injected.elapsedSinceAnchorMs(), 91500);
    });

    test('isSleepAware reports the captured reader after update', () {
      final injected = SyncClock(
        readerFactory: () => fakeReader(() => 0, isSleepAware: false),
      );
      addTearDown(injected.dispose);

      injected.update(1000, 0);
      expect(injected.isSleepAware, isFalse);
    });

    test('isSleepAware probes the factory before any anchor', () {
      var probes = 0;
      final injected = SyncClock(
        readerFactory: () {
          probes++;
          return fakeReader(() => 0);
        },
      );
      addTearDown(injected.dispose);

      expect(injected.isSleepAware, isTrue);
      expect(probes, 1, reason: 'pre-anchor query resolves the factory');

      injected.update(1000, 0);
      expect(injected.isSleepAware, isTrue);
      expect(probes, 2, reason: 'post-anchor query uses the captured reader');
    });

    test('default resolution falls back to a non-sleep-aware reader '
        'in a plain test isolate (no nts bridge)', () {
      final unbridged = SyncClock();
      addTearDown(unbridged.dispose);
      expect(unbridged.isSleepAware, isFalse);
    });
  });

  group('resolveMonotonicReader fallback', () {
    // Plain test isolate: nts bridge never initialized, so resolution
    // deterministically lands on the Stopwatch fallback.

    test('fallback reader still measures elapsed time correctly', () async {
      final reader = resolveMonotonicReader();
      expect(reader.isSleepAware, isFalse);

      final first = reader.read();
      await Future.delayed(const Duration(milliseconds: 50));
      final second = reader.read();
      expect(second - first, greaterThanOrEqualTo(20000));
    });

    test('fallback epoch anchors at first read, not resolution', () async {
      // The lazy Stopwatch means resolution-to-first-read latency does
      // not count as elapsed time; the first read defines the epoch.
      final reader = resolveMonotonicReader();
      await Future.delayed(const Duration(milliseconds: 50));
      final first = reader.read();
      expect(first, lessThan(20000));
    });
  });
}
