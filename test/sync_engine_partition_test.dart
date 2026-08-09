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

/// Real curated inventory with both tiers live, for assertions about
/// the two partitions running side by side.
const _liveBothTiers = TrustedTimeConfig();

/// A [TimeSource] under an `nts:`-prefixed id, the NTS counterpart of
/// [_FakeNtpSource].
class _FakeNtsSource implements TimeSource {
  _FakeNtsSource(String host) : id = '${TimeSource.prefixNts}$host';
  @override
  final String id;
  @override
  final String groupId = 'as2';

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: 1000, endMs: 1020),
    sourceId: id,
    groupId: groupId,
  );
}

/// Builds a fake NTS inventory of [anycast] fixed members plus
/// [unicast] promotion/explorer candidates, with a matching source per
/// host.
///
/// NTP is emptied so the assertions are about the NTS partition alone.
///
/// Not usable for warm assertions: the NTS seam substitutes the
/// inventory but still builds a real [NtsSource] per entry, so each of
/// these fakes *shadows* one rather than replacing it, and the engine's
/// first-seen dedup resolves the id to the real source. Warm scoping is
/// asserted over [_fakeNtpInventory], whose seam does suppress
/// construction; the barrier keys off [Warmable], not off the prefix.
({TrustedTimeConfig config, List<TimeSource> sources}) _fakeNtsInventory({
  required int anycast,
  required int unicast,
  int? queryTarget,
}) {
  final entries = <NtsServerInfo>[
    for (var i = 0; i < anycast; i++)
      NtsServerInfo(
        host: 'ntsany$i.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        leapPolicy: LeapPolicy.documentedStepping,
      ),
    for (var i = 0; i < unicast; i++)
      NtsServerInfo(
        host: 'ntsuni$i.test',
        tier: TimeServerTier.unicastStratum1,
        observedStratum: 1,
        leapPolicy: LeapPolicy.documentedStepping,
      ),
  ];
  final sources = [for (final e in entries) _FakeNtsSource(e.host)];
  return (
    config: TrustedTimeConfig(
      disableNtpForTesting: true,
      ntsInventoryForTesting: entries,
      additionalSources: sources,
      ntsQueryTarget: queryTarget ?? TrustedTimeConfig.minNtsQueryTarget,
      minGroupCount: 1,
    ),
    sources: sources,
  );
}

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

/// A [_FakeNtpSource] that records each [warm] call into a shared list.
class _WarmRecordingNtpSource extends _FakeNtpSource implements Warmable {
  _WarmRecordingNtpSource(super.host, this._warmed);

  final List<String> _warmed;

  @override
  Future<void> warm() async => _warmed.add(id);
}

/// A [_FakeNtpSource] that answers, but only after [delay].
///
/// Distinct from [_HangingNtpSource]: this host *does* work, it is
/// merely slower than the quorum it is racing. Under early exit that is
/// the difference between a sample the cycle uses and one it discards.
class _LateNtpSource implements TimeSource {
  _LateNtpSource(String host, this.delay) : id = '${TimeSource.prefixNtp}$host';
  @override
  final String id;
  @override
  final String groupId = 'as1';
  final Duration delay;

  @override
  Future<TimeSample> getTime() async {
    await Future<void>.delayed(delay);
    return TimeSample(
      interval: TimeInterval(startMs: 1000, endMs: 1020),
      sourceId: id,
      groupId: groupId,
    );
  }
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
/// ever constructed. That is also what makes this, rather than
/// [_fakeNtsInventory], the seam warm assertions run on: these fakes
/// are the only instances carrying their ids, so a warm count over
/// them is exact.
///
/// Pass [warmLog] to get [Warmable] sources that append their id to it
/// on each warm; otherwise the sources implement no warming at all, so
/// a cycle's barrier is a no-op over them.
({TrustedTimeConfig config, List<TimeSource> sources}) _fakeInventory({
  required int anycast,
  required int unicast,
  bool hangingUnicast = false,
  List<String>? warmLog,
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
      else if (warmLog != null)
        _WarmRecordingNtpSource(e.host, warmLog)
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

    test('an anycast NTS host is a fixed member every cycle', () {
      // Anycast hosts are members by identity, so a sole anycast host
      // is selected without needing any ranking to exist.
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

  // The NTS tier adds a promotion step above the plain tier split: the
  // anycast hosts are fixed members, the blocking set is filled to
  // ntsQueryTarget from the unicast ranking, and the rest is walked.
  // See ADR 0007's 2026-08-02 postscript.
  group('SyncEngine NTS inventory narrowing', () {
    test('the 57-host inventory is a pool, not a tier', () {
      // The regression this partition exists to prevent: before it,
      // every curated NTS host was classified blocking every cycle.
      final roles = _engine(
        config: _liveBothTiers,
        budget: 5,
      ).selectCycleRolesForTesting();
      final ntsBlocking = roles.blocking.where(
        (id) => id.startsWith(TimeSource.prefixNts),
      );
      expect(ntsBlocking, hasLength(_liveBothTiers.ntsQueryTarget));
      expect(ntsBlocking.length, lessThan(_liveBothTiers.ntsInventory.length));
    });

    test('a cycle opens single-digit NTS handshakes', () {
      // The cost claim on the dartdoc: query target plus explorer
      // budget, against one handshake per inventory host before.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final selected = _engine(config: _liveBothTiers, budget: 5)
          .selectCycleHostsForTesting()
          .where((id) => id.startsWith(TimeSource.prefixNts));
      expect(
        selected,
        hasLength(
          _liveBothTiers.ntsQueryTarget + SyncEngine.standardNtsExplorerBudget,
        ),
      );
      expect(selected.length, lessThan(10));
    });

    test('the two tiers are partitioned on separate budgets', () {
      // One shuffle orders both walks, but an NTS probe costs a TLS
      // handshake an NTP probe does not, so neither budget is derivable
      // from the other.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final roles = _engine(
        config: _liveBothTiers,
        budget: 5,
      ).selectCycleRolesForTesting();
      final ntpExplorers = roles.explorers.where(
        (id) => id.startsWith(TimeSource.prefixNtp),
      );
      final ntsExplorers = roles.explorers.where(
        (id) => id.startsWith(TimeSource.prefixNts),
      );
      expect(ntpExplorers, hasLength(5));
      expect(ntsExplorers, hasLength(SyncEngine.standardNtsExplorerBudget));
    });

    test('anycast hosts are never displaced by promotion', () {
      final fake = _fakeNtsInventory(anycast: 3, unicast: 8);
      final roles = _engine(config: fake.config).selectCycleRolesForTesting();
      for (var i = 0; i < 3; i++) {
        expect(
          roles.blocking,
          contains('${TimeSource.prefixNts}ntsany$i.test'),
        );
      }
    });

    test('promotion fills the blocking set up to the query target', () {
      // Two anycast against a target of 5: three unicast hosts are
      // promoted to close the gap.
      final fake = _fakeNtsInventory(anycast: 2, unicast: 8, queryTarget: 5);
      final roles = _engine(config: fake.config).selectCycleRolesForTesting();
      expect(roles.blocking, hasLength(5));
      expect(roles.blocking.intersection(roles.explorers), isEmpty);
    });

    test('promotion comes out of the explorer budget, not on top', () {
      // Reallocation within the cycle rather than a wider cycle: the
      // handshake count is target + budget whatever the anycast/unicast
      // mix happens to be.
      final wide = _fakeNtsInventory(anycast: 3, unicast: 20, queryTarget: 5);
      final thin = _fakeNtsInventory(anycast: 1, unicast: 22, queryTarget: 5);
      final a = _engine(config: wide.config, budget: 0);
      final b = _engine(config: thin.config, budget: 0);
      expect(
        a.selectCycleHostsForTesting(),
        hasLength(b.selectCycleHostsForTesting().length),
      );
    });

    test('a target above the promotable population fills what it can', () {
      // Fewer unicast candidates than slots: the quorum is simply
      // smaller, the same as one whose promotions are unranked.
      final fake = _fakeNtsInventory(anycast: 1, unicast: 1, queryTarget: 5);
      final roles = _engine(config: fake.config).selectCycleRolesForTesting();
      expect(roles.blocking, hasLength(2));
    });

    test('a ranked host with a recorded success is promoted', () {
      final tracker = SourceQualityTracker();
      final fake = _fakeNtsInventory(anycast: 2, unicast: 8, queryTarget: 3);
      // One host has answered; it must take the single open slot.
      tracker.recordProbe(
        sourceId: '${TimeSource.prefixNts}ntsuni5.test',
        delayMs: 5,
      );
      final roles = _engine(
        config: fake.config,
        tracker: tracker,
      ).selectCycleRolesForTesting();
      expect(roles.blocking, contains('${TimeSource.prefixNts}ntsuni5.test'));
    });

    test('a host known only from a failure is not promoted', () {
      // The admission test. recordFailure leaves a decayed but positive
      // success rate, and ranked() scores an unmeasured source
      // neutrally, so without hasSucceeded the failed host could
      // outrank a never-tried one and fill a headroom slot with an
      // expected failure.
      final tracker = SourceQualityTracker();
      final fake = _fakeNtsInventory(anycast: 2, unicast: 8, queryTarget: 3);
      tracker.recordFailure('${TimeSource.prefixNts}ntsuni5.test');
      final roles = _engine(
        config: fake.config,
        tracker: tracker,
      ).selectCycleRolesForTesting();
      expect(
        roles.blocking,
        isNot(contains('${TimeSource.prefixNts}ntsuni5.test')),
      );
      // The slot is still filled -- by the cold-start path, since no
      // ranked host qualifies.
      expect(roles.blocking, hasLength(3));
    });

    test('cold start fills from the head of the walk', () {
      // With no ranking at all the target is still met, and from the
      // prefix of a traversal the cycle computes anyway rather than a
      // separate selection rule.
      final fake = _fakeNtsInventory(anycast: 2, unicast: 8, queryTarget: 5);
      final engine = _engine(config: fake.config);
      final roles = engine.selectCycleRolesForTesting();
      expect(roles.blocking, hasLength(5));
      // Same shuffle, so the promoted hosts are the walk prefix the
      // explorer list would otherwise have started with.
      final all = engine.selectCycleHostsForTesting();
      expect(roles.blocking.union(roles.explorers), equals(all));
    });

    test('the fill declines hosts known only from failures', () {
      // The fill is a cold-start allowance, not a standing exemption.
      // On a network where every unicast candidate has failed, taking
      // the head of the walk unconditionally would seat the oldest
      // failure -- routing around hasSucceeded on exactly the
      // population that rule exists for, and leaving the target's
      // failure headroom nominal for as long as the outage lasts.
      //
      // Three anycast members, matching the production floor: the
      // claim is that declining costs width rather than trust, and a
      // partition that shrank below the verified quorum would be a
      // trust cost. With two the assertion would hold for a partition
      // that necessarily degrades authentication.
      final tracker = SourceQualityTracker();
      final fake = _fakeNtsInventory(anycast: 3, unicast: 8, queryTarget: 5);
      for (var i = 0; i < 8; i++) {
        tracker.recordFailure('${TimeSource.prefixNts}ntsuni$i.test');
      }
      final roles = _engine(
        config: fake.config,
        tracker: tracker,
      ).selectCycleRolesForTesting();

      // The fixed members alone. They still meet the verified floor, so
      // shrinking to them costs width rather than trust.
      expect(roles.blocking, hasLength(TrustedTimeConfig.minNtsQueryTarget));
      expect(
        roles.blocking.every((id) => id.contains('ntsany')),
        isTrue,
        reason: 'a failed unicast host must not reach the quorum',
      );
    });

    test('a declined host stays an explorer for retry', () {
      // Declining is not exclusion: the fill decides only whether this
      // cycle may build an anchor on the host, not whether it is
      // contacted. Every declined host must still be probed, or the
      // outage that disqualified it could never be observed to end and
      // the decline would be permanent.
      //
      // Sized so the whole unicast half fits in one explorer budget,
      // which makes the assertion exact rather than a non-emptiness
      // check: anything the fill took would be missing from this set.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final tracker = SourceQualityTracker();
      final failed = {
        for (var i = 0; i < SyncEngine.standardNtsExplorerBudget; i++)
          '${TimeSource.prefixNts}ntsuni$i.test',
      };
      final fake = _fakeNtsInventory(
        anycast: 2,
        unicast: SyncEngine.standardNtsExplorerBudget,
        queryTarget: 5,
      );
      for (final id in failed) {
        tracker.recordFailure(id);
      }
      final roles = _engine(
        config: fake.config,
        tracker: tracker,
      ).selectCycleRolesForTesting();
      expect(roles.explorers, equals(failed));
    });

    test('the declined slots are not spent widening the walk', () {
      // The walk is computed at budget + shortfall so the fill has a
      // surplus to draw from. What the fill declines has to go back: a
      // cycle that promotes nothing must not silently query the target
      // as explorers instead, which would keep the handshake count at
      // its ceiling on precisely the degraded network the decline is
      // protecting.
      final tracker = SourceQualityTracker();
      final fake = _fakeNtsInventory(anycast: 2, unicast: 20, queryTarget: 5);
      for (var i = 0; i < 20; i++) {
        tracker.recordFailure('${TimeSource.prefixNts}ntsuni$i.test');
      }
      final engine = _engine(config: fake.config, tracker: tracker);
      expect(
        engine.selectCycleRolesForTesting().explorers,
        hasLength(engine.effectiveNtsExplorerBudget),
      );
    });

    test('two installs promote different cold-start hosts', () {
      // The fill inherits the per-install shuffle rather than
      // introducing a shared constant order.
      final fake = _fakeNtsInventory(anycast: 1, unicast: 20, queryTarget: 5);
      final a = _engine(
        config: fake.config,
        shuffle: const ExplorerShuffle(1),
      ).selectCycleRolesForTesting();
      final b = _engine(
        config: fake.config,
        shuffle: const ExplorerShuffle(2),
      ).selectCycleRolesForTesting();
      expect(a.blocking, isNot(equals(b.blocking)));
    });

    test('the NTS explorer walk rotates', () {
      final tracker = SourceQualityTracker();
      final fake = _fakeNtsInventory(anycast: 3, unicast: 20, queryTarget: 3);
      final engine = _engine(config: fake.config, tracker: tracker);

      final first = engine.selectCycleRolesForTesting().explorers;
      for (final id in first) {
        tracker.record(
          sourceId: id,
          uncertaintyMs: 10,
          participatedInConsensus: false,
        );
      }
      final second = engine.selectCycleRolesForTesting().explorers;
      expect(first.intersection(second), isEmpty);
    });

    test('NTS explorers are outside the blocking set', () {
      // Explorers feed the ranking only. Asserted on the split rather
      // than by running a cycle: the NTS test seam deliberately builds a
      // real NtsSource per entry (see ntsInventoryForTesting), so an
      // offline sync cannot produce NTS samples to count. That the
      // explorer half stays out of consensus is protocol-agnostic --
      // sync() keys off this record, not off the id prefix -- and is
      // covered by 'explorer samples stay out of consensus'.
      final fake = _fakeNtsInventory(anycast: 3, unicast: 8, queryTarget: 3);
      final roles = _engine(config: fake.config).selectCycleRolesForTesting();
      expect(roles.blocking, hasLength(3));
      expect(roles.explorers, isNotEmpty);
      expect(roles.blocking.intersection(roles.explorers), isEmpty);
    });

    test('an empty NTS inventory does not re-flatten the NTP one', () {
      // The early return is keyed on both inventories being empty.
      // Keyed on either alone, disableNts would send the NTP tier down
      // the "nothing to narrow" branch and query all 51.
      final selected = _engine(
        config: _liveInventory,
        budget: 5,
      ).selectCycleHostsForTesting();
      expect(selected, hasLength(15));
    });

    test('an empty NTP inventory does not re-flatten the NTS one', () {
      final fake = _fakeNtsInventory(anycast: 3, unicast: 20, queryTarget: 3);
      final selected = _engine(
        config: fake.config,
      ).selectCycleHostsForTesting();
      expect(selected.length, lessThan(23));
    });
  });

  group('default NTS explorer budget platform split', () {
    test('iOS gets the narrow budget its ~30s task window allows', () {
      expect(
        SyncEngine.defaultNtsExplorerBudgetFor(TargetPlatform.iOS),
        SyncEngine.iosNtsExplorerBudget,
      );
    });

    test('iOS is strictly narrower than the standard budget', () {
      expect(
        SyncEngine.iosNtsExplorerBudget,
        lessThan(SyncEngine.standardNtsExplorerBudget),
      );
    });

    test('each NTS budget is narrower than its NTP counterpart', () {
      // The cost asymmetry that justifies separate constants: an NTS
      // probe is TCP + TLS + key exchange where an NTP probe is one UDP
      // round trip. If these ever converge the split stops meaning
      // anything.
      expect(
        SyncEngine.iosNtsExplorerBudget,
        lessThan(SyncEngine.iosExplorerBudget),
      );
      expect(
        SyncEngine.standardNtsExplorerBudget,
        lessThan(SyncEngine.standardExplorerBudget),
      );
    });

    test('platforms with no OS deadline reuse the standard budget', () {
      for (final platform in const [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.android,
      ]) {
        expect(
          SyncEngine.defaultNtsExplorerBudgetFor(platform),
          SyncEngine.standardNtsExplorerBudget,
          reason: '$platform has no execution window to fit under',
        );
      }
    });

    test('the front-load widens the NTS walk too', () {
      // Matters more here than on NTP: the NTS quorum pins 3 fixed
      // members against a floor of 3, so promotion supplies the whole
      // failure headroom and runs at zero headroom until the tracker
      // has rank.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final engine = _engine(config: _liveBothTiers)
        ..armExplorerBoost(SyncEngine.explorerBoostCycles);
      expect(
        engine.effectiveNtsExplorerBudget,
        SyncEngine.standardNtsExplorerBudget,
      );
    });

    test('the NTS boost only ever widens', () {
      final wide = SyncEngine.standardNtsExplorerBudget + 3;
      final engine = SyncEngine(
        config: _liveBothTiers,
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(99),
        ntsExplorerBudget: wide,
      )..armExplorerBoost(4);
      expect(engine.effectiveNtsExplorerBudget, wide);
    });

    test('a negative budget is a quorum-only cycle, not a throw', () {
      // partitionInventory already reads a non-positive budget as
      // quorum-only, but the NTS path takes its own trim after the
      // promotion fill -- an untrimmed negative reaches take() and
      // throws, so a cycle that could have run on its fixed members
      // fails outright. Asserted on both tiers: the NTP one degrades
      // today and pins that it keeps doing so.
      final nts = SyncEngine(
        config: _liveBothTiers,
        clock: FakeMonotonicClock(),
        explorerShuffle: const ExplorerShuffle(99),
        ntsExplorerBudget: -1,
      );
      expect(nts.effectiveNtsExplorerBudget, 0);
      expect(nts.selectCycleHostsForTesting, returnsNormally);

      final ntp = _engine(budget: -1);
      expect(ntp.effectiveExplorerBudget, 0);
      expect(ntp.selectCycleHostsForTesting(), hasLength(10));
    });
  });

  // An NTS warm is TCP + TLS + key exchange, so warming hosts the cycle
  // then narrows away is the cost the partition exists to avoid.
  group('warmAllSources cycle scoping', () {
    test('only the cycle-selected sources are warmed', () async {
      // Asserted on the warms themselves, not on completion: a
      // warmAllSources() that fanned out across all 22 hosts would
      // complete just as happily, so the narrowing has to be observed
      // where the cost is actually paid.
      final warmed = <String>[];
      final fake = _fakeInventory(anycast: 2, unicast: 20, warmLog: warmed);
      final engine = _engine(config: fake.config, budget: 4);
      final selected = engine.selectCycleHostsForTesting();

      expect(
        selected.length,
        lessThan(fake.sources.length),
        reason: 'the partition must narrow, or this asserts nothing',
      );

      await engine.warmAllSources();

      expect(warmed.toSet(), equals(selected));
      expect(
        warmed,
        hasLength(selected.length),
        reason: 'each selected source is warmed exactly once',
      );
    });

    test("a cycle's barrier warms that cycle's set", () async {
      // sync() warms the roles it already computed rather than deriving
      // a second selection. The two agree today -- nothing awaits
      // between the two points -- so this pins the agreement rather
      // than catching a live divergence. What it does catch is the
      // barrier reverting to the whole pool, and it is the anchor for
      // the property should an await ever appear in that span: an
      // explorer probe landing in the tracker mid-span would re-rank
      // the inventory and leave the barrier priming hosts the cycle is
      // not querying.
      final warmed = <String>[];
      final fake = _fakeInventory(anycast: 2, unicast: 20, warmLog: warmed);
      final engine = _engine(config: fake.config, budget: 4);
      final roles = engine.selectCycleRolesForTesting();

      await engine.sync();

      expect(warmed.toSet(), equals(roles.blocking.union(roles.explorers)));
      expect(
        warmed.toSet().length,
        lessThan(fake.sources.length),
        reason: 'the barrier must narrow, or this asserts nothing',
      );
    });

    test('a shadowed host is warmed once, not once per instance', () async {
      // The blocking path and the explorer probes both resolve a
      // colliding id first-seen, so a shadowing additionalSources entry
      // is queried once. Warming both instances would prime a jar
      // nothing reads and, for NTS, pay a second NTS-KE handshake for
      // it -- inside the barrier, where the cost is start latency.
      final warmed = <String>[];
      final fake = _fakeInventory(anycast: 2, unicast: 20, warmLog: warmed);
      final shadow = _WarmRecordingNtpSource('any0.test', warmed);
      final engine = _engine(
        config: fake.config.copyWith(
          additionalSources: [...fake.sources, shadow],
        ),
        budget: 4,
      );
      final selected = engine.selectCycleHostsForTesting();
      expect(
        selected,
        contains(shadow.id),
        reason: 'the shadowed host must be in the cycle for this to bite',
      );

      await engine.warmAllSources();

      expect(warmed, hasLength(warmed.toSet().length));
      expect(warmed.where((id) => id == shadow.id), hasLength(1));
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

  group('success latch under early exit', () {
    test('a host that answers after the exit still latches', () async {
      // The promotion admission rule reads a latch that the end-of-cycle
      // bookkeeping cannot set on its own: _completeSync folds in the
      // samples it collected, and under early exit a late one is
      // discarded before it gets there. A host that answers every cycle
      // but always a little behind the quorum would then stay
      // unpromotable forever -- the filter excluding exactly the
      // reachable hosts it exists to find.
      //
      // Four anycast answer instantly and settle consensus; the fifth
      // is late enough that the cycle is long gone when it returns.
      final tracker = SourceQualityTracker();
      final hosts = const [
        'any0.test',
        'any1.test',
        'any2.test',
        'any3.test',
        'late.test',
      ];
      final entries = <NtpServerInfo>[
        for (final host in hosts)
          NtpServerInfo(
            host: host,
            tier: TimeServerTier.anycast,
            observedStratum: 1,
            observedGroupId: 'as1',
            leapPolicy: LeapPolicy.documentedStepping,
          ),
      ];
      final sources = <TimeSource>[
        for (final host in hosts)
          if (host == 'late.test')
            _LateNtpSource(host, const Duration(milliseconds: 400))
          else
            _FakeNtpSource(host),
      ];
      final engine = SyncEngine(
        config: TrustedTimeConfig(
          disableNts: true,
          disableNtpForTesting: true,
          ntpInventoryForTesting: entries,
          additionalSources: sources,
          minGroupCount: 1,
        ),
        clock: FakeMonotonicClock(),
        qualityTracker: tracker,
        explorerShuffle: const ExplorerShuffle(99),
      );

      await engine.sync();
      expect(
        tracker.hasSucceeded('${TimeSource.prefixNtp}late.test'),
        isFalse,
        reason: 'the late host has not answered yet, so nothing to latch',
      );

      // Let the straggler land. Its sample is discarded; the fact that
      // it answered is not.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(tracker.hasSucceeded('${TimeSource.prefixNtp}late.test'), isTrue);
    });
  });
}
