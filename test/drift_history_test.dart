import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/domain/explorer_shuffle.dart';
import 'package:trusted_time/src/drift_history.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('InMemoryAnchorStorage explorer seed', () {
    test('starts absent, round-trips, and clears with clear()', () async {
      final storage = InMemoryAnchorStorage();
      expect(await storage.loadExplorerSeed(), isNull);

      await storage.saveExplorerSeed(987654321);
      expect(await storage.loadExplorerSeed(), 987654321);

      await storage.clear();
      expect(await storage.loadExplorerSeed(), isNull);
    });

    test('accepts the range boundaries', () async {
      final storage = InMemoryAnchorStorage();

      await storage.saveExplorerSeed(0);
      expect(await storage.loadExplorerSeed(), 0);

      await storage.saveExplorerSeed(ExplorerShuffle.seedBound - 1);
      expect(await storage.loadExplorerSeed(), ExplorerShuffle.seedBound - 1);
    });

    test('asserts on an out-of-range seed', () async {
      // The store would discard such a seed on the next read, so the
      // caller would see a walk order that silently resets on every
      // launch. Failing at the write makes that a caller bug.
      final storage = InMemoryAnchorStorage();
      expect(
        () => storage.saveExplorerSeed(-1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => storage.saveExplorerSeed(ExplorerShuffle.seedBound),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('InMemoryAnchorStorage explorer boost', () {
    test('starts absent, round-trips, and clears with clear()', () async {
      final storage = InMemoryAnchorStorage();
      // Absent is "arm a fresh boost", not "boost exhausted" -- an
      // exhausted boost is a stored zero.
      expect(await storage.loadExplorerBoostRemaining(), isNull);

      await storage.saveExplorerBoostRemaining(5);
      expect(await storage.loadExplorerBoostRemaining(), 5);

      await storage.clear();
      expect(await storage.loadExplorerBoostRemaining(), isNull);
    });

    test('a stored zero is distinct from absence', () async {
      final storage = InMemoryAnchorStorage();
      await storage.saveExplorerBoostRemaining(0);
      expect(await storage.loadExplorerBoostRemaining(), 0);
    });

    test('asserts on a negative count', () async {
      // A negative count reads back as corrupt, so the caller would
      // silently re-arm a spent boost on every launch.
      final storage = InMemoryAnchorStorage();
      expect(
        () => storage.saveExplorerBoostRemaining(-1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('AnchorStore source stats (mocked secure storage)', () {
    const storageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    // Match the AnchorStore stats key by stable prefix rather than the
    // exact versioned literal (currently tt_source_stats_v1) so a key
    // version bump does not silently break these tests. No other store
    // key shares the tt_source_stats_ prefix.
    const statsKeyPrefix = 'tt_source_stats_';

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, null);
    });

    test('loadSourceStats decodes stored JSON and skips malformed '
        'entries', () async {
      final payload = jsonEncode({
        'ntp:good': {
          'ewmaRttMs': 42.5,
          'ewmaJitterMs': 3.0,
          'successRate': 0.9,
          'lastProbedUtcMs': 1700000000000,
          'stratum': 2,
        },
        // Malformed: successRate is not a number, so fromJson returns
        // null and the entry must be skipped without discarding the
        // rest of the map.
        'ntp:bad': {'successRate': 'corrupt', 'lastProbedUtcMs': 1},
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'read') {
              final key = (call.arguments as Map)['key'] as String?;
              if (key?.startsWith(statsKeyPrefix) ?? false) return payload;
            }
            return null;
          });

      final loaded = await AnchorStore().loadSourceStats();

      expect(loaded.keys, ['ntp:good']);
      final stats = loaded['ntp:good']!;
      expect(stats.ewmaRttMs, 42.5);
      expect(stats.ewmaJitterMs, 3.0);
      expect(stats.successRate, 0.9);
      expect(stats.lastProbedUtcMs, 1700000000000);
      expect(stats.stratum, 2);
    });

    test('clear() deletes the persisted source stats', () async {
      final deletedKeys = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'delete') {
              deletedKeys.add((call.arguments as Map)['key'] as String);
            }
            return null;
          });

      await AnchorStore().clear();

      expect(
        deletedKeys.where((k) => k.startsWith(statsKeyPrefix)),
        hasLength(1),
      );
    });
  });

  group('AnchorStore explorer seed (mocked secure storage)', () {
    const storageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    // Prefix-matched for the same reason as the stats key above: a
    // version bump should not silently break these tests.
    const seedKeyPrefix = 'tt_explorer_seed_';

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, null);
    });

    void mockRead(String? stored, {List<String>? deletedKeys}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            final key = (call.arguments as Map)['key'] as String?;
            if (call.method == 'delete') {
              if (key != null) deletedKeys?.add(key);
              return null;
            }
            if (call.method == 'read' &&
                (key?.startsWith(seedKeyPrefix) ?? false)) {
              return stored;
            }
            return null;
          });
    }

    test('loadExplorerSeed returns null when nothing is stored', () async {
      mockRead(null);
      expect(await AnchorStore().loadExplorerSeed(), isNull);
    });

    test('loadExplorerSeed decodes a stored seed', () async {
      mockRead('987654321');
      expect(await AnchorStore().loadExplorerSeed(), 987654321);
    });

    test('a corrupt seed is treated as absent and deleted', () async {
      // Corruption must cost an install its walk order, never a
      // bootstrap: the caller reads null and mints a fresh seed.
      final deletedKeys = <String>[];
      mockRead('not-an-int', deletedKeys: deletedKeys);

      expect(await AnchorStore().loadExplorerSeed(), isNull);
      expect(
        deletedKeys.where((k) => k.startsWith(seedKeyPrefix)),
        hasLength(1),
      );
    });

    test('an out-of-range seed is treated as absent and deleted', () async {
      // Parseable but outside the generated range. Random does not
      // specify how it reduces such a seed, so accepting it would make
      // the walk order differ between the VM and the web for one
      // install. Rejecting costs that install its walk order once.
      for (final raw in ['-1', '${ExplorerShuffle.seedBound}']) {
        final deletedKeys = <String>[];
        mockRead(raw, deletedKeys: deletedKeys);

        expect(await AnchorStore().loadExplorerSeed(), isNull, reason: raw);
        expect(
          deletedKeys.where((k) => k.startsWith(seedKeyPrefix)),
          hasLength(1),
          reason: raw,
        );
      }
    });

    test('accepts a seed at the edges of the generated range', () async {
      mockRead('0');
      expect(await AnchorStore().loadExplorerSeed(), 0);

      mockRead('${ExplorerShuffle.seedBound - 1}');
      expect(
        await AnchorStore().loadExplorerSeed(),
        ExplorerShuffle.seedBound - 1,
      );
    });

    test('saveExplorerSeed writes the seed under the seed key', () async {
      final written = <String, String?>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'write') {
              final args = call.arguments as Map;
              written[args['key'] as String] = args['value'] as String?;
            }
            return null;
          });

      await AnchorStore().saveExplorerSeed(13579);

      expect(
        written.entries
            .singleWhere((e) => e.key.startsWith(seedKeyPrefix))
            .value,
        '13579',
      );
    });

    test('saveExplorerSeed asserts on an out-of-range seed', () async {
      // Symmetric with the in-memory double: a seed the loader would
      // reject must never reach storage in the first place.
      expect(
        () => AnchorStore().saveExplorerSeed(-1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => AnchorStore().saveExplorerSeed(ExplorerShuffle.seedBound),
        throwsA(isA<AssertionError>()),
      );
    });

    test('clear() deletes the persisted explorer seed', () async {
      final deletedKeys = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'delete') {
              deletedKeys.add((call.arguments as Map)['key'] as String);
            }
            return null;
          });

      await AnchorStore().clear();

      expect(
        deletedKeys.where((k) => k.startsWith(seedKeyPrefix)),
        hasLength(1),
      );
    });
  });

  group('AnchorStore explorer boost (mocked secure storage)', () {
    const storageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    const boostKeyPrefix = 'tt_explorer_boost_';

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, null);
    });

    void mockRead(String? stored, {List<String>? deletedKeys}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            final key = (call.arguments as Map)['key'] as String?;
            if (call.method == 'delete') {
              if (key != null) deletedKeys?.add(key);
              return null;
            }
            if (call.method == 'read' &&
                (key?.startsWith(boostKeyPrefix) ?? false)) {
              return stored;
            }
            return null;
          });
    }

    test('returns null when nothing is stored', () async {
      mockRead(null);
      expect(await AnchorStore().loadExplorerBoostRemaining(), isNull);
    });

    test('decodes a stored count, including zero', () async {
      mockRead('5');
      expect(await AnchorStore().loadExplorerBoostRemaining(), 5);

      // Zero is a spent boost, not an absent one -- it must survive the
      // round trip or every launch would re-arm.
      mockRead('0');
      expect(await AnchorStore().loadExplorerBoostRemaining(), 0);
    });

    test(
      'a corrupt or negative count is treated as absent and deleted',
      () async {
        // Absence arms a fresh boost, so corruption costs an install a
        // handful of extra explorer probes, never a bootstrap.
        for (final raw in ['not-an-int', '-1']) {
          final deletedKeys = <String>[];
          mockRead(raw, deletedKeys: deletedKeys);

          expect(
            await AnchorStore().loadExplorerBoostRemaining(),
            isNull,
            reason: raw,
          );
          expect(
            deletedKeys.where((k) => k.startsWith(boostKeyPrefix)),
            hasLength(1),
            reason: raw,
          );
        }
      },
    );

    test('writes the count under the boost key', () async {
      final written = <String, String?>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'write') {
              final args = call.arguments as Map;
              written[args['key'] as String] = args['value'] as String?;
            }
            return null;
          });

      await AnchorStore().saveExplorerBoostRemaining(3);

      expect(
        written.entries
            .singleWhere((e) => e.key.startsWith(boostKeyPrefix))
            .value,
        '3',
      );
    });

    test('asserts on a negative count', () async {
      expect(
        () => AnchorStore().saveExplorerBoostRemaining(-1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('clear() deletes the persisted boost count', () async {
      final deletedKeys = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'delete') {
              deletedKeys.add((call.arguments as Map)['key'] as String);
            }
            return null;
          });

      await AnchorStore().clear();

      expect(
        deletedKeys.where((k) => k.startsWith(boostKeyPrefix)),
        hasLength(1),
      );
    });
  });
}
