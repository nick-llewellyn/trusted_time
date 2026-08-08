import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/infra/sync_observer.dart';
import 'package:trusted_time/src/infra/trusted_time_log.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sources/nts_auth_level.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';
import 'support/fake_observers.dart';
import 'support/fake_sources.dart';

SyncEngine _engineFor(
  List<TimeSource> sources, {
  required RecordingObserver observer,
  MonotonicClock? clock,
}) {
  return SyncEngine(
    config: const TrustedTimeConfig(
      minimumQuorum: 2,
      minGroupCount: 1,
      // Wait for every source each cycle so admission is deterministic and
      // does not depend on which sample wins the early-exit race.
      earlyExit: false,
      disableNtpForTesting: true,
      disableNts: true,
    ).copyWith(additionalSources: sources),
    clock: clock ?? FakeMonotonicClock(),
    observer: observer,
  );
}

void main() {
  group('SyncEngine tier-aware admission', () {
    test('Tier 1 quorum forms the truth box and admits only intersecting '
        'lower-tier samples', () async {
      final observer = RecordingObserver();
      // Three verified samples overlap at [1005, 1020] — the truth box.
      // Three because minVerifiedQuorum floors the truth-box pass there;
      // below it the cycle degrades regardless of how well the verified
      // samples agree.
      final engine = _engineFor([
        TierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 1005,
          endMs: 1025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v3',
          groupId: 'g5',
          startMs: 1002,
          endMs: 1022,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        // Platform-mediated NTS (Tier 2) inside the truth box.
        TierSource(
          id: 'nts:in',
          groupId: 'g3',
          startMs: 1010,
          endMs: 1015,
          trustBackend: nts.TrustBackend.platform,
        ),
        // Platform-mediated NTS (Tier 2) outside the truth box.
        TierSource(
          id: 'nts:out',
          groupId: 'g4',
          startMs: 1100,
          endMs: 1120,
          trustBackend: nts.TrustBackend.platform,
        ),
      ], observer: observer);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      final result = observer.consensusReached.single;
      expect(result.degradedTier, isFalse);
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
      expect(participantIds, contains('nts:in'));
      expect(participantIds, isNot(contains('nts:out')));
      expect(
        result.droppedOutsideTruthBox.map((s) => s.sourceId),
        contains('nts:out'),
      );
      expect(
        observer.sourceFailures.any(
          (f) =>
              f.sourceId == 'nts:out' && f.error == 'tier2: outside truth box',
        ),
        isTrue,
      );
    });

    test('Tier 1 quorum fails: legacy single-tier reduction flagged '
        'degradedTier', () async {
      final observer = RecordingObserver();
      // No verified samples. Three lower-tier samples (one platform-mediated
      // NTS, two plain) agree at [1005, 1020].
      final engine = _engineFor([
        TierSource(
          id: 'nts:a',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          trustBackend: nts.TrustBackend.platform,
        ),
        TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        TierSource(id: 'ntp:c', groupId: 'g3', startMs: 1000, endMs: 1020),
      ], observer: observer);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.none);
      final result = observer.consensusReached.single;
      expect(result.degradedTier, isTrue);
      expect(result.authLevel, NtsAuthLevel.none);
      expect(result.droppedOutsideTruthBox, isEmpty);
      // All three samples are admitted under the legacy reduction.
      expect(
        result.participants.map((s) => s.sourceId),
        containsAll(<String>['nts:a', 'ntp:b', 'ntp:c']),
      );
    });

    test('coordinated lower-tier cluster outside the truth box cannot move '
        'the consensus', () async {
      final observer = RecordingObserver();
      // Three verified samples agree near T (~10012), meeting the
      // truth-box floor. Three coordinated lower-tier samples cluster at
      // T+10s, well outside the box.
      final engine = _engineFor([
        TierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 10000,
          endMs: 10020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 10005,
          endMs: 10025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v3',
          groupId: 'g6',
          startMs: 10002,
          endMs: 10022,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:x',
          groupId: 'g3',
          startMs: 20005,
          endMs: 20025,
          trustBackend: nts.TrustBackend.platform,
        ),
        TierSource(id: 'ntp:y', groupId: 'g4', startMs: 20000, endMs: 20020),
        TierSource(id: 'ntp:z', groupId: 'g5', startMs: 20005, endMs: 20025),
      ], observer: observer);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      final result = observer.consensusReached.single;
      expect(result.degradedTier, isFalse);
      // Consensus stays anchored at T, not the T+10s lower-tier cluster.
      expect(result.utc.millisecondsSinceEpoch, inInclusiveRange(10005, 10020));
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
      expect(participantIds, containsAll(<String>['nts:v1', 'nts:v2']));
      expect(
        participantIds,
        isNot(anyElement(isIn(<String>['nts:x', 'ntp:y', 'ntp:z']))),
      );
      expect(
        result.droppedOutsideTruthBox.map((s) => s.sourceId),
        containsAll(<String>['nts:x', 'ntp:y', 'ntp:z']),
      );
    });
  });

  group('SyncEngine observability logging', () {
    final lines = <(TrustedTimeLogLevel, String)>[];

    setUp(() {
      lines.clear();
      TrustedTimeLog.sink = (level, message) => lines.add((level, message));
    });

    tearDown(() => TrustedTimeLog.sink = null);

    test('every queried source gets one sample line, symmetric across '
        'kinds, and the consensus line names won and rejected '
        'sources', () async {
      final observer = RecordingObserver();
      final engine = _engineFor([
        TierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 1005,
          endMs: 1025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v3',
          groupId: 'g5',
          startMs: 1002,
          endMs: 1022,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(id: 'ntp:in', groupId: 'g3', startMs: 1010, endMs: 1015),
        TierSource(id: 'ntp:out', groupId: 'g4', startMs: 1100, endMs: 1120),
        FailingNtsSource(),
      ], observer: observer);

      await engine.sync();

      final sampleLines = lines
          .map((l) => l.$2)
          .where((m) => m.contains('] sample '))
          .toList();
      // One ok line per succeeding source regardless of kind — NTP
      // included, which was previously silent.
      for (final id in ['nts:v1', 'nts:v2', 'ntp:in', 'ntp:out']) {
        expect(
          sampleLines.where((m) => m.contains('sample $id ok')),
          hasLength(1),
          reason: 'expected exactly one ok line for $id',
        );
      }
      // The failure path gets a line too.
      expect(
        sampleLines.where((m) => m.contains('sample nts:fail fail reason=')),
        hasLength(1),
      );
      // ok lines carry rtt/offset/authLevel fields.
      final okLine = sampleLines.firstWhere(
        (m) => m.contains('sample nts:v1 ok'),
      );
      expect(okLine, contains('rtt='));
      expect(okLine, contains('offset='));
      expect(okLine, contains('authLevel=verified'));

      // Consensus attribution names identities, not just counts.
      final consensusLine = lines
          .map((l) => l.$2)
          .singleWhere((m) => m.contains('] consensus '));
      expect(consensusLine, contains('won=['));
      expect(consensusLine, contains('nts:v1'));
      expect(consensusLine, contains('nts:v2'));
      expect(consensusLine, contains('ntp:in'));
      expect(consensusLine, contains('ntp:out (outside truth box)'));
      expect(consensusLine, contains('authLevel=verified'));
      expect(consensusLine, isNot(contains('won=[nts:fail')));
    });

    test('a degraded cycle emits an explicit warning naming the '
        'assessment consequence', () async {
      final observer = RecordingObserver();
      final engine = _engineFor([
        TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
      ], observer: observer);

      await engine.sync();

      final degraded = lines.singleWhere(
        (l) => l.$2.contains('anchor DEGRADED'),
      );
      expect(degraded.$1, TrustedTimeLogLevel.warning);
      expect(degraded.$2, contains('authLevel=none'));
      expect(degraded.$2, contains('TrustStatusReason.degraded'));
    });

    test('a healthy verified cycle emits no DEGRADED warning', () async {
      final observer = RecordingObserver();
      final engine = _engineFor([
        TierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        TierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 1005,
          endMs: 1025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
        // Third verified host: the truth-box floor, so this cycle is
        // healthy rather than degraded-for-being-thin.
        TierSource(
          id: 'nts:v3',
          groupId: 'g3',
          startMs: 1002,
          endMs: 1022,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
        ),
      ], observer: observer);

      await engine.sync();

      expect(lines.where((l) => l.$2.contains('anchor DEGRADED')), isEmpty);
    });
  });

  group('SyncEngine anchor boot-ID stamping (R5)', () {
    // The warm-restore reboot check compares a persisted anchor's bootId
    // against the device's current boot ID, so the engine must stamp the
    // clock's identity onto every freshly synced anchor. A regression
    // here would silently produce null-bootId anchors: everything still
    // passes, but every warm restore fails closed and forces a needless
    // network sync.
    test('sync() stamps the clock boot ID onto the anchor', () async {
      final observer = RecordingObserver();
      final engine = _engineFor(
        [
          TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        ],
        observer: observer,
        clock: FakeMonotonicClock(bootId: 'boot-uuid-42'),
      );

      final anchor = await engine.sync();

      expect(anchor.bootId, 'boot-uuid-42');
    });

    test('sync() leaves the anchor bootId null when the platform provides '
        'none (fails closed on later warm restore)', () async {
      final observer = RecordingObserver();
      final engine = _engineFor(
        [
          TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        ],
        observer: observer,
        clock: FakeMonotonicClock(bootId: null),
      );

      final anchor = await engine.sync();

      expect(anchor.bootId, isNull);
    });
  });

  // The early exit publishes on a stable consensus, and a degraded
  // consensus is a consensus. With the truth box floored at three
  // verified hosts, the first two verified replies no longer form a
  // box, so the stability counter can complete a cycle at
  // NtsAuthLevel.none while the third verified query is still in
  // flight -- a cycle whose verified hosts all answer degrading on
  // response order alone. These pin the hold that prevents it, and its
  // scope.
  group('SyncEngine verified-floor early exit', () {
    SyncEngine engineFor(
      List<TimeSource> sources, {
      required SyncObserver observer,
    }) => SyncEngine(
      config: const TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        // The setting under test: the race only exists when the cycle
        // may complete before every source has answered.
        disableNtpForTesting: true,
        disableNts: true,
      ).copyWith(additionalSources: sources),
      clock: FakeMonotonicClock(),
      observer: observer,
    );

    // Holds one source's reply until the others have landed. A
    // wall-clock delay would decide the race by how busy the event loop
    // is, which passes or fails on what ran before it; releasing on a
    // sample count makes the ordering the test's own.
    ({Future<void> Function() gate, SyncObserver observer}) gateAfter(
      int samples,
      RecordingObserver recorder,
    ) {
      final released = Completer<void>();
      final counter = _ReleasingObserver(
        inner: recorder,
        releaseAfter: samples,
        release: released,
      );
      return (gate: () => released.future, observer: counter);
    }

    test('a degraded result waits for a verified query still in '
        'flight', () async {
      final recorder = RecordingObserver();
      // The race in full. Two verified hosts answer first, which under
      // the floor is one short of a truth box, so resolve returns the
      // degraded fallback. Two lower-tier replies agreeing on the same
      // interval then carry the stability counter to its threshold
      // while the third verified host is still in flight. Without the
      // hold the cycle publishes NtsAuthLevel.none there, even though
      // every verified host answers in the end.
      final gated = gateAfter(4, recorder);
      final engine = engineFor([
        verifiedNtsSource(host: 'fast1.a.example', startMs: 1000, endMs: 1020),
        verifiedNtsSource(host: 'fast2.b.example', startMs: 1005, endMs: 1025),
        TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
        verifiedNtsSource(
          host: 'slow.c.example',
          startMs: 1002,
          endMs: 1022,
          gate: gated.gate,
        ),
      ], observer: gated.observer);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(recorder.consensusReached.last.degradedTier, isFalse);
    });

    test('the hold does not outlive the queries it waits on', () async {
      // Availability is not traded for the wait: when the third
      // verified host never answers, the cycle still publishes the
      // degraded anchor once nothing is left in flight.
      final recorder = RecordingObserver();
      final engine = engineFor([
        verifiedNtsSource(host: 'fast1.a.example', startMs: 1000, endMs: 1020),
        verifiedNtsSource(host: 'fast2.b.example', startMs: 1005, endMs: 1025),
        TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
        failingVerifiedNtsSource(host: 'down.c.example'),
      ], observer: recorder);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
    });

    test('an all-NTP cycle still exits early', () async {
      // Every cycle here is legitimately degraded and no source could
      // ever lift it, so the hold must not engage -- otherwise it
      // becomes a blanket early-exit disable for NTP-only installs.
      // The gated source would never be released, so the cycle can only
      // finish by exiting early on the first three.
      final recorder = RecordingObserver();
      final gated = gateAfter(3, recorder);
      final engine = engineFor([
        TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:c', groupId: 'g3', startMs: 1000, endMs: 1020),
        _GatedTierSource(
          id: 'ntp:slow',
          groupId: 'g4',
          startMs: 1002,
          endMs: 1022,
          gate: gated.gate,
        ),
      ], observer: gated.observer);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
      // The point of the case: the cycle finished on the first three
      // rather than waiting out the fourth. A hold that engaged on any
      // degraded result would still publish this anchor, just later, so
      // the outcome alone cannot tell the two apart -- the absent
      // contributor is what does.
      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('ntp:slow')),
      );
    });
  });

  group('SyncEngine anchor contributor telemetry', () {
    // Every collected sample must yield one contributor record —
    // winners and losers alike — because the excluded sources are
    // exactly the signal source-quality refinement needs. Telemetry
    // is diagnostic: its absence or shape must never affect the
    // trust fields, which the other groups already pin down.
    test('sync() records winners and losers with wonConsensus '
        'attribution', () async {
      final observer = RecordingObserver();
      final engine = _engineFor([
        TierSource(id: 'ntp:in1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:in2', groupId: 'g2', startMs: 1005, endMs: 1025),
        // Disjoint interval: answers, but loses the intersection.
        TierSource(id: 'ntp:out', groupId: 'g3', startMs: 1100, endMs: 1120),
      ], observer: observer);

      final anchor = await engine.sync();

      expect(anchor.contributors, hasLength(3));
      final byId = {for (final c in anchor.contributors) c.sourceId: c};
      expect(byId['ntp:in1']!.wonConsensus, isTrue);
      expect(byId['ntp:in2']!.wonConsensus, isTrue);
      expect(byId['ntp:out']!.wonConsensus, isFalse);
      // _TierSource samples carry no measured delay: rtt falls back to
      // the interval width (2 × uncertainty = 20ms here).
      expect(byId['ntp:in1']!.rttMs, 20);
      expect(byId['ntp:in1']!.groupId, 'g1');
      expect(byId['ntp:in1']!.authLevel, NtsAuthLevel.none);
      // No stratum/jitter concept on these fixtures.
      expect(byId['ntp:in1']!.stratum, isNull);
      expect(byId['ntp:in1']!.jitterMs, isNull);
    });

    test('a failed source produces no contributor record', () async {
      final observer = RecordingObserver();
      final engine = _engineFor([
        TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        FailingNtsSource(),
      ], observer: observer);

      final anchor = await engine.sync();

      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('nts:fail')),
      );
      expect(anchor.contributors, hasLength(2));
    });
  });
}

/// Forwards to [inner] while completing [release] once [releaseAfter]
/// samples have reached the engine's listener.
///
/// Lets a test order one source's reply behind a known number of
/// others without a wall-clock delay, which would settle the race on
/// event-loop timing rather than on the behaviour under test.
class _ReleasingObserver implements SyncObserver {
  _ReleasingObserver({
    required this.inner,
    required this.releaseAfter,
    required this.release,
  });

  final RecordingObserver inner;
  final int releaseAfter;
  final Completer<void> release;
  int _seen = 0;

  @override
  void onSampleReceived(TimeSample sample) {
    inner.onSampleReceived(sample);
    if (++_seen >= releaseAfter && !release.isCompleted) release.complete();
  }

  @override
  void onSourceFailed(String sourceId, Object error) =>
      inner.onSourceFailed(sourceId, error);

  @override
  void onSyncStarted() => inner.onSyncStarted();

  @override
  void onConsensusReached(ConsensusResult result) =>
      inner.onConsensusReached(result);

  @override
  void onSyncFailed(Object error) => inner.onSyncFailed(error);

  @override
  void onMetricsReported(SyncMetrics metrics) =>
      inner.onMetricsReported(metrics);
}

/// A [TierSource] whose reply waits on a gate, so a lower-tier source
/// can be held back the same way [verifiedNtsSource] holds a verified
/// one.
class _GatedTierSource implements TimeSource {
  _GatedTierSource({
    required this.id,
    required this.groupId,
    required this.startMs,
    required this.endMs,
    required this.gate,
  });

  @override
  final String id;
  @override
  final String groupId;
  final int startMs;
  final int endMs;
  final Future<void> Function() gate;

  @override
  Future<TimeSample> getTime() async {
    await gate();
    return TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: groupId,
    );
  }
}
