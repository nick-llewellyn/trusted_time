import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/domain/explorer_shuffle.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';

/// Minimal always-succeeding source, used to assert that caller-supplied
/// sources bypass the inventory partition.
class _StubSource implements TimeSource {
  _StubSource(this.id);
  @override
  final String id;
  @override
  final String groupId = 'g';

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: 1000, endMs: 1100),
    sourceId: id,
    groupId: groupId,
  );
}

/// Real curated inventory, NTS suppressed so the assertions are about
/// the NTP partition alone.
const _liveInventory = TrustedTimeConfig(ntsServers: []);

SyncEngine _engine({
  TrustedTimeConfig config = _liveInventory,
  ExplorerShuffle? shuffle,
  int budget = SyncEngine.defaultExplorerBudget,
  SourceQualityTracker? tracker,
}) => SyncEngine(
  config: config,
  clock: FakeMonotonicClock(),
  qualityTracker: tracker,
  explorerShuffle: shuffle ?? const ExplorerShuffle(99),
  explorerBudget: budget,
);

void main() {
  group('SyncEngine inventory narrowing', () {
    test('a cycle queries the quorum plus the budget, not all 51', () {
      final selected = _engine(budget: 5).selectCycleHostsForTesting();
      expect(selected, hasLength(15));
    });

    test('the budget is what moves the count', () {
      expect(_engine(budget: 0).selectCycleHostsForTesting(), hasLength(10));
      expect(_engine(budget: 41).selectCycleHostsForTesting(), hasLength(51));
    });

    test('every selected id is a real NTP source id', () {
      final selected = _engine().selectCycleHostsForTesting();
      expect(
        selected.every((id) => id.startsWith(TimeSource.prefixNtp)),
        isTrue,
      );
    });

    test('two installs select different explorer sets', () {
      final a = _engine(
        shuffle: const ExplorerShuffle(1),
      ).selectCycleHostsForTesting();
      final b = _engine(
        shuffle: const ExplorerShuffle(2),
      ).selectCycleHostsForTesting();
      expect(a, isNot(equals(b)));
      // The quorum half is shared; only the explorer half diverges.
      expect(a.intersection(b).length, greaterThanOrEqualTo(10));
    });
  });

  group('SyncEngine partition pass-through', () {
    test('caller-supplied sources are never partitioned out', () {
      final extra = _StubSource('custom-1');
      final selected = _engine(
        config: _liveInventory.copyWith(additionalSources: [extra]),
      ).selectCycleHostsForTesting();
      expect(selected, contains('custom-1'));
    });

    test('NTS sources are always eligible', () {
      final selected = _engine(
        config: const TrustedTimeConfig(ntsServers: ['nts.example']),
      ).selectCycleHostsForTesting();
      expect(selected, contains('${TimeSource.prefixNts}nts.example'));
    });

    test('an empty inventory leaves every source eligible', () {
      final selected = _engine(
        config: const TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: [],
        ).copyWith(additionalSources: [_StubSource('a'), _StubSource('b')]),
      ).selectCycleHostsForTesting();
      expect(selected, equals({'a', 'b'}));
    });
  });

  group('SyncEngine explorer rotation', () {
    test('probed explorers give way to unprobed ones', () {
      // Stamp the first cycle's explorers as probed; the next cycle
      // must pick a disjoint set, since 41 candidates >> 2*budget.
      final tracker = SourceQualityTracker();
      final engine = _engine(budget: 5, tracker: tracker);

      final first = engine.selectCycleHostsForTesting();
      for (final id in first) {
        tracker.record(
          sourceId: id,
          uncertaintyMs: 10,
          participatedInConsensus: true,
        );
      }
      final second = engine.selectCycleHostsForTesting();

      // Quorum is queried every cycle, so it repeats by design; the
      // explorer halves must not.
      final firstExplorers = first.difference(second);
      final secondExplorers = second.difference(first);
      expect(firstExplorers, hasLength(5));
      expect(secondExplorers, hasLength(5));
    });
  });

  group('SyncEngine explorer shuffle wiring', () {
    test('defaults to a minted shuffle when none is supplied', () {
      final engine = SyncEngine(
        config: _liveInventory,
        clock: FakeMonotonicClock(),
      );
      expect(ExplorerShuffle.isValidSeed(engine.explorerShuffle.seed), isTrue);
    });

    test('restoreExplorerShuffle changes the walk', () {
      final engine = _engine(shuffle: const ExplorerShuffle(1));
      final before = engine.selectCycleHostsForTesting();
      engine.restoreExplorerShuffle(const ExplorerShuffle(2));
      expect(engine.selectCycleHostsForTesting(), isNot(equals(before)));
    });
  });

  group('loadOrMintExplorerShuffle', () {
    test('mints and persists on first launch', () async {
      final store = InMemoryAnchorStorage();
      final shuffle = await loadOrMintExplorerShuffle(
        load: store.loadExplorerSeed,
        save: store.saveExplorerSeed,
      );
      expect(await store.loadExplorerSeed(), equals(shuffle.seed));
    });

    test('reuses the stored seed on later launches', () async {
      final store = InMemoryAnchorStorage();
      final first = await loadOrMintExplorerShuffle(
        load: store.loadExplorerSeed,
        save: store.saveExplorerSeed,
      );
      final second = await loadOrMintExplorerShuffle(
        load: store.loadExplorerSeed,
        save: store.saveExplorerSeed,
      );
      expect(second.seed, equals(first.seed));
    });

    test('an out-of-range stored seed is treated as absent', () async {
      // A third-party AnchorStorage may hand back a seed the bundled
      // implementations would have rejected. The constructor's range
      // assert is stripped in release, so the helper must not rely on
      // it. Each of these must be replaced, not adopted.
      for (final corrupt in [-1, ExplorerShuffle.seedBound, 1 << 62]) {
        final shuffle = await loadOrMintExplorerShuffle(
          load: () async => corrupt,
          save: (_) async {},
        );
        expect(shuffle.seed, isNot(equals(corrupt)));
        expect(ExplorerShuffle.isValidSeed(shuffle.seed), isTrue);
      }
    });

    test('minting over a corrupt seed repairs the store', () async {
      int? stored = -7;
      final shuffle = await loadOrMintExplorerShuffle(
        load: () async => stored,
        save: (seed) async => stored = seed,
      );
      expect(stored, equals(shuffle.seed));
    });

    test('a failing load still yields a usable shuffle', () async {
      final shuffle = await loadOrMintExplorerShuffle(
        load: () async => throw StateError('unreadable'),
        save: (_) async {},
      );
      expect(ExplorerShuffle.isValidSeed(shuffle.seed), isTrue);
    });

    test('a failing save does not fail the bootstrap', () async {
      final shuffle = await loadOrMintExplorerShuffle(
        load: () async => null,
        save: (_) async => throw StateError('read-only'),
      );
      expect(ExplorerShuffle.isValidSeed(shuffle.seed), isTrue);
    });
  });
}
