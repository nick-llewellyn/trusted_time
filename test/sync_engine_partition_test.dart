import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
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
const _liveInventory = TrustedTimeConfig(disableNts: true);

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

/// A [_FakeNtpSource] that never answers.
///
/// Stands in for a host that is reachable enough to accept the query
/// but slow enough to outlive any timeout the cycle would wait on, so
/// a test can tell "the cycle did not block on it" from "the cycle
/// blocked and it happened to be fast".
class _HangingNtpSource implements TimeSource {
  _HangingNtpSource(String host) : id = '${TimeSource.prefixNtp}$host';
  @override
  final String id;
  @override
  final String groupId = 'as1';

  @override
  Future<TimeSample> getTime() => Completer<TimeSample>().future;
}

/// A [_FakeNtpSource] that tallies how often it was queried.
class _CountingNtpSource implements TimeSource {
  _CountingNtpSource(String host) : id = '${TimeSource.prefixNtp}$host';
  @override
  final String id;
  @override
  final String groupId = 'as1';
  int calls = 0;

  @override
  Future<TimeSample> getTime() async {
    calls++;
    return TimeSample(
      interval: TimeInterval(startMs: 1000, endMs: 1020),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// Builds a fake inventory of [anycast] always-queried hosts plus
/// [unicast] explorer candidates, together with a matching source per
/// host.
///
/// When [hangingUnicast] is set, the unicast sources never answer,
/// which is how the non-blocking assertions separate the two halves.
///
/// Returned as a config with `disableNtpForTesting: true` so the
/// override is the only inventory in play and no live [NtpSource] is
/// ever constructed.
({TrustedTimeConfig config, List<TimeSource> sources}) _fakeInventory({
  required int anycast,
  required int unicast,
  bool hangingUnicast = false,
}) {
  final entries = <NtpServerInfo>[
    for (var i = 0; i < anycast; i++)
      NtpServerInfo(
        host: 'any$i.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      ),
    for (var i = 0; i < unicast; i++)
      NtpServerInfo(
        host: 'uni$i.test',
        tier: TimeServerTier.unicastStratum1,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      ),
  ];
  final sources = [
    for (final e in entries)
      if (hangingUnicast && e.tier != TimeServerTier.anycast)
        _HangingNtpSource(e.host)
      else
        _FakeNtpSource(e.host),
  ];
  return (
    config: TrustedTimeConfig(
      disableNts: true,
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
  int? budget,
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

  // The budget exists to keep a cycle inside the OS execution window,
  // and only iOS enforces one, so the split is two-way rather than
  // per-platform.
  group('default explorer budget platform split', () {
    test('iOS gets the narrow budget its ~30s task window allows', () {
      expect(
        SyncEngine.defaultExplorerBudgetFor(TargetPlatform.iOS),
        SyncEngine.iosExplorerBudget,
      );
    });

    test('Android gets the wider budget its ~9min worker allows', () {
      expect(
        SyncEngine.defaultExplorerBudgetFor(TargetPlatform.android),
        SyncEngine.standardExplorerBudget,
      );
    });

    test('iOS is strictly narrower than the standard budget', () {
      // The point of the split. Without this the two constants could
      // drift to the same value and every test above would still pass.
      expect(
        SyncEngine.iosExplorerBudget,
        lessThan(SyncEngine.standardExplorerBudget),
      );
    });

    test('platforms with no OS deadline reuse the standard budget', () {
      for (final platform in const [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          SyncEngine.defaultExplorerBudgetFor(platform),
          SyncEngine.standardExplorerBudget,
          reason: '$platform has no execution window to fit under',
        );
      }
    });
  });

  group('constructor budget resolution', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('an omitted budget resolves from the host platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final ios = _engine().selectCycleHostsForTesting();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final android = _engine().selectCycleHostsForTesting();

      expect(ios, hasLength(10 + SyncEngine.iosExplorerBudget));
      expect(android, hasLength(10 + SyncEngine.standardExplorerBudget));
    });

    test('an explicit budget overrides the platform default', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        _engine(
          budget: SyncEngine.standardExplorerBudget,
        ).selectCycleHostsForTesting(),
        hasLength(10 + SyncEngine.standardExplorerBudget),
      );
    });
  });

  // The front-load widens foreground cycles for an install's first few
  // days, then decays to the platform steady state. It is armed by
  // count rather than latched to install age so vantage-epoch recovery
  // can re-arm the same primitive on an unrelated trigger.
  group('front-loaded explorer budget', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('an unarmed engine runs at the steady-state budget', () {
      final engine = _engine(budget: 3);
      expect(engine.effectiveExplorerBudget, 3);
      expect(engine.selectCycleHostsForTesting(), hasLength(13));
    });

    test('arming widens the cycle to the boosted budget', () {
      final engine = _engine(budget: SyncEngine.iosExplorerBudget)
        ..armExplorerBoost(SyncEngine.explorerBoostCycles);
      expect(engine.effectiveExplorerBudget, SyncEngine.boostedExplorerBudget);
      expect(
        engine.selectCycleHostsForTesting(),
        hasLength(10 + SyncEngine.boostedExplorerBudget),
      );
    });

    test('the boost only ever widens, never narrows', () {
      // boostedExplorerBudget is the standard width, so a caller who
      // asked for more would otherwise be cut back by a front-load.
      final wide = SyncEngine.boostedExplorerBudget + 5;
      final engine = _engine(budget: wide)..armExplorerBoost(4);
      expect(engine.effectiveExplorerBudget, wide);
    });

    test('arming again replaces the remainder rather than accumulating', () {
      final engine = _engine(budget: 3)
        ..armExplorerBoost(8)
        ..armExplorerBoost(2);
      expect(engine.explorerBoostRemaining, 2);
    });

    test('arming a negative count throws in every build mode', () {
      // The count reaches the engine from persisted storage, so a
      // release build must not clamp a corrupt value silently.
      expect(
        () => _engine(budget: 3).armExplorerBoost(-1),
        throwsA(isA<RangeError>()),
      );
    });

    test('arming zero disarms', () {
      final engine = _engine(budget: 3)
        ..armExplorerBoost(8)
        ..armExplorerBoost(0);
      expect(engine.effectiveExplorerBudget, 3);
    });

    test('the boost decays only on a banked cycle', () async {
      // 2 anycast + 6 unicast against a steady budget of 1: boosted the
      // cycle takes every unicast host (the 8-wide boost exceeds the
      // pool), steady it takes one, so the two widths are
      // distinguishable by host count alone.
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final engine = SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(99),
        explorerBudget: 1,
      )..armExplorerBoost(2);

      expect(engine.selectCycleHostsForTesting(), hasLength(8));
      await engine.sync();
      expect(engine.explorerBoostRemaining, 1);
      await engine.sync();
      expect(engine.explorerBoostRemaining, 0);

      // Decayed to steady state: 2 anycast + 1 explorer.
      expect(engine.effectiveExplorerBudget, 1);
      expect(engine.selectCycleHostsForTesting(), hasLength(3));
    });

    test('decay stops at zero rather than going negative', () async {
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final engine = SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(99),
        explorerBudget: 1,
      )..armExplorerBoost(1);

      await engine.sync();
      await engine.sync();
      expect(engine.explorerBoostRemaining, 0);
    });

    test('a boosted iOS cycle matches a standard steady-state one', () {
      // The indistinguishability claim: a front-loaded iOS cycle emits
      // the same host count as an unboosted Android one, so no single
      // cycle is a distinctive event -- only the aggregate rate over an
      // install's first days differs.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final boostedIos = (_engine()..armExplorerBoost(8))
          .selectCycleHostsForTesting();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final steadyAndroid = _engine().selectCycleHostsForTesting();

      expect(boostedIos, hasLength(steadyAndroid.length));
    });

    test('the boost is a no-op where the steady budget is already wide', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final steady = _engine().selectCycleHostsForTesting();
      final boosted = (_engine()..armExplorerBoost(8))
          .selectCycleHostsForTesting();
      expect(boosted, equals(steady));
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
        config: const TrustedTimeConfig(
          ntsInventoryForTesting: [
            NtsServerInfo(
              host: 'nts.example',
              tier: TimeServerTier.anycast,
              observedStratum: 1,
              leapPolicy: LeapPolicy.documentedStepping,
            ),
          ],
        ),
      ).selectCycleHostsForTesting();
      expect(selected, contains('${TimeSource.prefixNts}nts.example'));
    });

    test('an additionalSource shadowing an inventory host is partitioned', () {
      // The documented exception to the pass-through rule. Eligibility
      // is decided by id, so an additionalSource under `ntp:<host>` for
      // an inventory host is indistinguishable from the inventory-backed
      // source it shadows and is narrowed like one.
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final selected = SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(7),
        explorerBudget: 2,
      ).selectCycleHostsForTesting();

      expect(fake.config.additionalSources, hasLength(8));
      expect(selected, hasLength(4));
      final dropped = {for (final s in fake.sources) s.id}.difference(selected);
      expect(dropped, hasLength(4));
    });

    test('an empty inventory leaves every source eligible', () {
      final selected = _engine(
        config: const TrustedTimeConfig(
          disableNtpForTesting: true,
          disableNts: true,
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

  // Explorers are probed for their RTT, not for their time. They must
  // therefore neither gate the cycle nor reach the consensus that
  // mints the anchor.
  group('non-blocking explorers', () {
    test('the split puts inventory unicast hosts outside the quorum', () {
      final roles = _engine(budget: 5).selectCycleRolesForTesting();
      expect(roles.blocking, hasLength(10));
      expect(roles.explorers, hasLength(5));
      expect(roles.blocking.intersection(roles.explorers), isEmpty);
    });

    test('caller-supplied sources are never demoted to explorers', () {
      final roles = SyncEngine(
        config: TrustedTimeConfig(
          disableNts: true,
          additionalSources: [_StubSource('custom')],
        ),
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(3),
        explorerBudget: 5,
      ).selectCycleRolesForTesting();
      expect(roles.blocking, contains('custom'));
      expect(roles.explorers, isNot(contains('custom')));
    });

    test('a cycle completes while every explorer is still hanging', () async {
      // Only the two anycast hosts answer; all six explorers hang
      // forever. Under the old flattened set the cycle would wait on
      // the full maxLatency before finalizing, so completing at all is
      // the assertion.
      final fake = _fakeInventory(anycast: 2, unicast: 6, hangingUnicast: true);
      final anchor = await SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(7),
        explorerBudget: 6,
      ).sync();
      expect(anchor, isNotNull);
    });

    test('explorer samples stay out of consensus', () async {
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final observer = RecordingObserver();
      await SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        observer: observer,
        explorerShuffle: const ExplorerShuffle(7),
        explorerBudget: 6,
      ).sync();

      // Every unicast host answers instantly here, so a leak would show
      // up as participants the anycast quorum cannot account for.
      expect(observer.consensusReached.single.participantCount, 2);
    });

    test('an explorer probe still refreshes the ranking', () async {
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final tracker = SourceQualityTracker();
      await SyncEngine(
        config: fake.config,
        clock: FakeMonotonicClock(),
        qualityTracker: tracker,
        explorerShuffle: const ExplorerShuffle(7),
        explorerBudget: 6,
      ).sync();
      // Let the probes, which the cycle deliberately did not wait on,
      // land before reading the tracker.
      await Future<void>.delayed(Duration.zero);

      for (var i = 0; i < 6; i++) {
        expect(
          tracker.lastProbedUtcMs('${TimeSource.prefixNtp}uni$i.test'),
          isNotNull,
          reason: 'uni$i.test was probed, so the walk must advance past it',
        );
      }
    });

    test('a probe with no consensus outcome does not claim one', () async {
      // recordProbe must not synthesise a participation observation:
      // an explorer that scored a false non-participation every cycle
      // would sink in the very ranking the probe exists to inform.
      final tracker = SourceQualityTracker();
      tracker.recordProbe(sourceId: 'ntp:uni0.test', delayMs: 10);
      expect(tracker.participationRate('ntp:uni0.test'), isNull);
      expect(tracker.lastProbedUtcMs('ntp:uni0.test'), isNotNull);
    });

    test('explorer probes are deduped by id', () async {
      // An additionalSource can shadow an inventory host, putting two
      // instances under one id in _sources. The blocking path resolves
      // that first-seen; the probe path must agree, or the shadowed
      // host is queried twice and its durable stats updated twice from
      // what the ranking treats as a single source.
      final fake = _fakeInventory(anycast: 2, unicast: 6);
      final first = _CountingNtpSource('uni0.test');
      final second = _CountingNtpSource('uni0.test');
      final shadowed = [
        for (final s in fake.sources)
          if (s.id != first.id) s,
        first,
        second,
      ];
      await SyncEngine(
        config: TrustedTimeConfig(
          disableNts: true,
          disableNtpForTesting: true,
          ntpInventoryForTesting: fake.config.ntpInventoryForTesting,
          additionalSources: shadowed,
          minGroupCount: 1,
        ),
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(7),
        explorerBudget: 6,
      ).sync();
      await Future<void>.delayed(Duration.zero);

      expect(first.calls, 1);
      expect(second.calls, 0);
    });
  });

  group('SyncEngine coverage telemetry', () {
    // These need an inventory the partition actually narrows. Every
    // other offline test empties it, which sends _selectCycleHosts down
    // its "nothing to narrow" branch where the cycle set is the whole
    // pool -- and a denominator bug is invisible when the two agree.

    test('coverage ratios divide by the blocking set, not the pool', () async {
      // 2 anycast + 6 unicast, budget 2: the cycle touches 4 of 8 but
      // only the 2 anycast hosts can reach consensus, so all three
      // candidate denominators (2, 4, 8) are distinct.
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
      expect(engine.selectCycleRolesForTesting().blocking, hasLength(2));
      expect(fake.sources, hasLength(8));
      await engine.sync();

      expect(observer.metricsReported, hasLength(1));
      final metrics = observer.metricsReported.single;
      expect(
        metrics.confidenceBreakdown['depth'],
        closeTo(metrics.participantCount / 2, 1e-9),
      );
      expect(
        metrics.confidenceBreakdown['quorumDepth'],
        closeTo(metrics.quorumDepth / 2, 1e-9),
      );
      // The pool denominator is the bug this replaced; name it so a
      // regression cannot pass by coincidence.
      expect(
        metrics.confidenceBreakdown['depth'],
        isNot(closeTo(metrics.participantCount / 8, 1e-9)),
      );
    });

    test('the explorer budget does not move the ratio', () async {
      // Same 8-host pool, same blocking set either way; only the
      // explorer width differs. Explorers cannot participate in
      // consensus, so counting them would deflate the ratio purely
      // because the front-load was live -- reporting a confidence drop
      // where the time quality is identical.
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
        closeTo(wide.confidenceBreakdown['depth']!, 1e-9),
      );
    });

    // Deliberately untested: that the count is read off _CompletionGuard
    // rather than an engine field. Cycle width is fixed per engine
    // today -- quorum size, budget, and inventory are all constructor
    // state, and the platform default is resolved once at construction
    // -- so overlapping cycles overwrite the field with the value it
    // already held, and no sequential or interleaved test can separate
    // the two. The guard scoping is hardening for the front-loaded
    // foreground budget, where widths differ *within* an engine's life;
    // the test belongs with that change.
  });
}
