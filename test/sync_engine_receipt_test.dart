import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';

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

void main() {
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
          disableNtpForTesting: true,
          disableNts: true,
        ).copyWith(additionalSources: [s1, s2]),
        clock: FakeMonotonicClock(),
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
            disableNtpForTesting: true,
            disableNts: true,
          ).copyWith(additionalSources: [s1, s2]),
          clock: FakeMonotonicClock(),
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
          disableNtpForTesting: true,
          disableNts: true,
        ).copyWith(additionalSources: [s1, s2, s3]),
        clock: FakeMonotonicClock(),
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
          disableNtpForTesting: true,
          disableNts: true,
        ).copyWith(additionalSources: [s1, s2]),
        clock: FakeMonotonicClock(),
      );

      final anchor = await engine.sync();
      // FakeMonotonicClock reads 100000; receipt age is 3500 − 2000.
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
          disableNtpForTesting: true,
          disableNts: true,
        ).copyWith(additionalSources: [s1, s2]),
        clock: FakeMonotonicClock(),
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
          disableNtpForTesting: true,
          disableNts: true,
        ).copyWith(additionalSources: [s1, s2]),
        clock: FakeMonotonicClock.justBooted(),
      );

      final anchor = await engine.sync();
      expect(anchor.uptimeMs, 600);
    });
  });
}
