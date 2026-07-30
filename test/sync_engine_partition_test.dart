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
import 'support/fake_observers.dart';

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

/// A [TimeSource] under an `ntp:`-prefixed id, so the partition treats
/// it as inventory-backed rather than caller-supplied.
///
/// The real [NtpSource] would do DNS and UDP; this answers instantly
/// with a fixed interval, letting a cycle complete offline while still
/// being subject to narrowing.
class _FakeNtpSource implements TimeSource {
  _FakeNtpSource(String host) : id = '${TimeSource.prefixNtp}$host';
  @override
  final String id;
  @override
  final String groupId = 'as1';

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: 1000, endMs: 1020),
    sourceId: id,
    groupId: groupId,
  );
}

/// Builds a fake inventory of [anycast] always-queried hosts plus
/// [unicast] explorer candidates, together with a matching source per
/// host.
///
/// Returned as a config with `disableNtpForTesting: true` so the
/// override is the only inventory in play and no live [NtpSource] is
/// ever constructed.
({TrustedTimeConfig config, List<TimeSource> sources}) _fakeInventory({
  required int anycast,
  required int unicast,
}) {
  final entries = <NtpServerInfo>[
    for (var i = 0; i < anycast; i++)
      NtpServerInfo(
        host: 'any$i.test',
        tier: NtpServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      ),
    for (var i = 0; i < unicast; i++)
      NtpServerInfo(
        host: 'uni$i.test',
        tier: NtpServerTier.unicastStratum1,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      ),
  ];
  final sources = [for (final e in entries) _FakeNtpSource(e.host)];
  return (
    config: TrustedTimeConfig(
      ntsServers: const [],
      disableNtpForTesting: true,
      ntpInventoryForTesting: entries,
      additionalSources: sources,
      // One synthetic group across every fake, so consensus turns on
      // participation alone -- these tests are about the denominator,
      // not about diversity.
      minGroupCount: 1,
    ),
    sources: sources,
  );
}

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

  group('SyncEngine coverage telemetry', () {
    // These need an inventory the partition actually narrows. Every
    // other offline test empties it, which sends _selectCycleHosts down
    // its "nothing to narrow" branch where the cycle set is the whole
    // pool -- and a denominator bug is invisible when the two agree.

    test('coverage ratios divide by the cycle, not the pool', () async {
      // 2 anycast + 6 unicast, budget 2: the cycle queries 4 of 8, so
      // the two candidate denominators differ by a factor of two.
      //
      // Asserted against the reported participantCount rather than a
      // hard-coded ratio: early exit can settle consensus before every
      // queried host answers, so the numerator is a property of the
      // cycle, not something the test should predict. What must hold
      // is which denominator it was divided by.
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final observer = RecordingObserver();
      final engine = SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        observer: observer,
        explorerShuffle: const ExplorerShuffle(7),
        explorerBudget: 2,
      );

      expect(engine.selectCycleHostsForTesting(), hasLength(4));
      expect(fake.sources, hasLength(8));
      await engine.sync();

      expect(observer.metricsReported, hasLength(1));
      final metrics = observer.metricsReported.single;
      expect(
        metrics.confidenceBreakdown['depth'],
        closeTo(metrics.participantCount / 4, 1e-9),
      );
      expect(
        metrics.confidenceBreakdown['quorumDepth'],
        closeTo(metrics.quorumDepth / 4, 1e-9),
      );
      // The pool denominator is the bug this replaced; name it so a
      // regression cannot pass by coincidence.
      expect(
        metrics.confidenceBreakdown['depth'],
        isNot(closeTo(metrics.participantCount / 8, 1e-9)),
      );
    });

    test('a wider budget lowers the ratio for equal participation', () async {
      // Same 8-host pool and the same consensus either way; only the
      // cycle width differs. Under a pool denominator both cycles
      // divide by 8 and the ratios match, so divergence here is
      // exactly the property the fix introduced.
      Future<SyncMetrics> syncWithBudget(int budget) async {
        final fake = _fakeInventory(anycast: 2, unicast: 6);
        final observer = RecordingObserver();
        await SyncEngine(
          config: fake.config,
          clock: FakeMonotonicClock(),
          observer: observer,
          explorerShuffle: const ExplorerShuffle(7),
          explorerBudget: budget,
        ).sync();
        return observer.metricsReported.single;
      }

      final narrow = await syncWithBudget(2);
      final wide = await syncWithBudget(6);
      expect(
        narrow.participantCount,
        equals(wide.participantCount),
        reason: 'the numerator must be held fixed for this comparison',
      );
      expect(
        narrow.confidenceBreakdown['depth'],
        greaterThan(wide.confidenceBreakdown['depth']!),
      );
    });

    // Deliberately untested: that the count is read off _CompletionGuard
    // rather than an engine field. Cycle width is fixed per engine
    // today -- quorum size, budget, and inventory are all constructor
    // state -- so overlapping cycles overwrite the field with the value
    // it already held, and no sequential or interleaved test can
    // separate the two. The guard scoping is hardening for slice 3,
    // where a per-cycle budget makes the widths differ; the test
    // belongs with that change.
  });
}
