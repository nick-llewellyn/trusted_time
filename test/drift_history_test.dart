import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/drift_history.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';

void main() {
  group('DriftBootRecord', () {
    test('observedDriftRate is signed (dUptime - dNet) / dNet', () {
      // Uptime advanced 3_600_360 ms while network UTC advanced
      // 3_600_000 ms: the device clock runs fast by 100 ppm.
      const record = DriftBootRecord(
        bootId: 'boot-A',
        firstUptimeMs: 0,
        firstNetworkUtcMs: 1000000,
        lastUptimeMs: 3600360,
        lastNetworkUtcMs: 4600000,
        anchorCount: 2,
      );
      expect(record.observedDriftRate, closeTo(0.0001, 1e-9));
      expect(record.span, const Duration(hours: 1));
    });

    test('observedDriftRate is negative for a slow oscillator', () {
      const record = DriftBootRecord(
        bootId: 'boot-A',
        firstUptimeMs: 0,
        firstNetworkUtcMs: 0,
        lastUptimeMs: 3599640,
        lastNetworkUtcMs: 3600000,
        anchorCount: 2,
      );
      expect(record.observedDriftRate, closeTo(-0.0001, 1e-9));
    });

    test('observedDriftRate is null on a single-anchor record', () {
      const record = DriftBootRecord(
        bootId: 'boot-A',
        firstUptimeMs: 500,
        firstNetworkUtcMs: 1000,
        lastUptimeMs: 500,
        lastNetworkUtcMs: 1000,
        anchorCount: 1,
      );
      expect(record.observedDriftRate, isNull);
      expect(record.span, Duration.zero);
    });

    test('span clamps to zero when the network-UTC delta is negative', () {
      // A record whose latest observation sits *before* the first on the
      // network-UTC timeline (semantically-corrupt persisted data, or
      // consensus UTC stepping backwards) must not surface a negative
      // "span"; the rate is likewise unavailable.
      const record = DriftBootRecord(
        bootId: 'boot-A',
        firstUptimeMs: 0,
        firstNetworkUtcMs: 2000,
        lastUptimeMs: 500,
        lastNetworkUtcMs: 1000,
        anchorCount: 2,
      );
      expect(record.span, Duration.zero);
      expect(record.observedDriftRate, isNull);
    });

    test('JSON round-trip preserves every field', () {
      const record = DriftBootRecord(
        bootId: 'boot-A',
        firstUptimeMs: 1,
        firstNetworkUtcMs: 2,
        lastUptimeMs: 3,
        lastNetworkUtcMs: 4,
        anchorCount: 5,
      );
      expect(DriftBootRecord.fromJson(record.toJson()), record);
    });

    test('fromJson throws FormatException on malformed input', () {
      expect(
        () => DriftBootRecord.fromJson(const {'bootId': 'boot-A'}),
        throwsFormatException,
      );
      expect(
        () => DriftBootRecord.fromJson(const {
          'bootId': 'boot-A',
          'firstUptimeMs': 'not-an-int',
          'firstNetworkUtcMs': 2,
          'lastUptimeMs': 3,
          'lastNetworkUtcMs': 4,
          'anchorCount': 5,
        }),
        throwsFormatException,
      );
    });
  });

  group('DriftHistoryRecorder', () {
    test('first anchor of a boot opens a record with first == last', () {
      final recorder = DriftHistoryRecorder();
      final changed = recorder.recordAnchor(
        uptimeMs: 100,
        networkUtcMs: 5000,
        bootId: 'boot-A',
      );
      expect(changed, isTrue);
      expect(recorder.records, hasLength(1));
      final record = recorder.records.single;
      expect(record.firstUptimeMs, 100);
      expect(record.lastUptimeMs, 100);
      expect(record.anchorCount, 1);
    });

    test('a later anchor in the same boot updates last and count, '
        'keeping first', () {
      final recorder = DriftHistoryRecorder();
      recorder.recordAnchor(uptimeMs: 100, networkUtcMs: 5000, bootId: 'A');
      final changed = recorder.recordAnchor(
        uptimeMs: 3600100,
        networkUtcMs: 3605000,
        bootId: 'A',
      );
      expect(changed, isTrue);
      final record = recorder.records.single;
      expect(record.firstUptimeMs, 100);
      expect(record.lastUptimeMs, 3600100);
      expect(record.anchorCount, 2);
    });

    test('an identical reading is deduped (warm-restore re-apply)', () {
      final recorder = DriftHistoryRecorder();
      recorder.recordAnchor(uptimeMs: 100, networkUtcMs: 5000, bootId: 'A');
      final changed = recorder.recordAnchor(
        uptimeMs: 100,
        networkUtcMs: 5000,
        bootId: 'A',
      );
      expect(changed, isFalse);
      expect(recorder.records.single.anchorCount, 1);
    });

    test('a new bootId opens a new record', () {
      final recorder = DriftHistoryRecorder();
      recorder.recordAnchor(uptimeMs: 100, networkUtcMs: 5000, bootId: 'A');
      recorder.recordAnchor(uptimeMs: 50, networkUtcMs: 9000, bootId: 'B');
      expect(recorder.records, hasLength(2));
      expect(recorder.records.first.bootId, 'A');
      expect(recorder.records.last.bootId, 'B');
    });

    test('a null bootId records nothing', () {
      final recorder = DriftHistoryRecorder();
      final changed = recorder.recordAnchor(
        uptimeMs: 100,
        networkUtcMs: 5000,
        bootId: null,
      );
      expect(changed, isFalse);
      expect(recorder.records, isEmpty);
    });

    test('the ring buffer evicts the oldest boot beyond the cap', () {
      final recorder = DriftHistoryRecorder();
      for (var i = 0; i < kMaxDriftHistoryBoots + 3; i++) {
        recorder.recordAnchor(
          uptimeMs: 100,
          networkUtcMs: 5000 + i,
          bootId: 'boot-$i',
        );
      }
      expect(recorder.records, hasLength(kMaxDriftHistoryBoots));
      expect(recorder.records.first.bootId, 'boot-3');
      expect(recorder.records.last.bootId, 'boot-${kMaxDriftHistoryBoots + 2}');
    });

    test('restore replaces state and trims to the newest entries', () {
      final recorder = DriftHistoryRecorder();
      recorder.recordAnchor(uptimeMs: 1, networkUtcMs: 1, bootId: 'stale');
      final loaded = [
        for (var i = 0; i < kMaxDriftHistoryBoots + 2; i++)
          DriftBootRecord(
            bootId: 'boot-$i',
            firstUptimeMs: 0,
            firstNetworkUtcMs: i,
            lastUptimeMs: 0,
            lastNetworkUtcMs: i,
            anchorCount: 1,
          ),
      ];
      recorder.restore(loaded);
      expect(recorder.records, hasLength(kMaxDriftHistoryBoots));
      expect(recorder.records.first.bootId, 'boot-2');
      expect(recorder.records.any((r) => r.bootId == 'stale'), isFalse);
    });

    test('restore then recordAnchor dedups against the restored latest '
        'pair (warm restore)', () {
      final recorder = DriftHistoryRecorder();
      recorder.restore(const [
        DriftBootRecord(
          bootId: 'A',
          firstUptimeMs: 100,
          firstNetworkUtcMs: 5000,
          lastUptimeMs: 200,
          lastNetworkUtcMs: 5100,
          anchorCount: 2,
        ),
      ]);
      final changed = recorder.recordAnchor(
        uptimeMs: 200,
        networkUtcMs: 5100,
        bootId: 'A',
      );
      expect(changed, isFalse);
      expect(recorder.records.single.anchorCount, 2);
    });
  });

  group('InMemoryAnchorStorage drift history', () {
    test('round-trips records and clears with clear()', () async {
      final storage = InMemoryAnchorStorage();
      expect(await storage.loadDriftHistory(), isEmpty);

      const records = [
        DriftBootRecord(
          bootId: 'A',
          firstUptimeMs: 1,
          firstNetworkUtcMs: 2,
          lastUptimeMs: 3,
          lastNetworkUtcMs: 4,
          anchorCount: 2,
        ),
      ];
      await storage.saveDriftHistory(records);
      expect(await storage.loadDriftHistory(), records);

      await storage.clear();
      expect(await storage.loadDriftHistory(), isEmpty);
    });
  });

  group('InMemoryAnchorStorage source stats', () {
    test('round-trips stats and clears with clear()', () async {
      final storage = InMemoryAnchorStorage();
      expect(await storage.loadSourceStats(), isEmpty);

      const stats = {
        'ntp:pool.ntp.org': SourceQualityStats(
          ewmaRttMs: 42.5,
          ewmaJitterMs: 3.0,
          successRate: 0.9,
          lastProbedUtcMs: 1700000000000,
          stratum: 2,
        ),
      };
      await storage.saveSourceStats(stats);
      final loaded = await storage.loadSourceStats();
      expect(loaded.keys, equals(stats.keys));
      expect(loaded['ntp:pool.ntp.org']!.ewmaRttMs, equals(42.5));

      await storage.clear();
      expect(await storage.loadSourceStats(), isEmpty);
    });
  });
}
