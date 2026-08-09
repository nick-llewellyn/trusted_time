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
      Duration? maxLatency,
    }) => SyncEngine(
      config: TrustedTimeConfig(
        minimumQuorum: 2,
        minGroupCount: 1,
        // The setting under test: the race only exists when the cycle
        // may complete before every source has answered.
        disableNtpForTesting: true,
        disableNts: true,
        maxLatency: maxLatency ?? const Duration(seconds: 4),
      ).copyWith(additionalSources: sources),
      clock: FakeMonotonicClock(),
      observer: observer,
    );

    // Runs a cycle that must finish without one of its sources, and
    // proves it did so by the clock rather than by the outcome.
    //
    // A never-released gate is not enough on its own: the per-source
    // query budget is maxLatency, so a held cycle publishes the very
    // same anchor once that expires, and an assertion on the anchor
    // passes either way. Raising the budget well past the deadline
    // below makes the two outcomes distinguishable -- a cycle that
    // waits cannot finish inside it.
    Future<TrustAnchor> syncWithoutWaiting(SyncEngine engine) =>
        engine.sync().timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError(
            'cycle did not complete without the withheld source',
          ),
        );

    // Orders sources' replies by how many samples have already reached
    // the engine. A wall-clock delay would decide the race by how busy
    // the event loop is, which passes or fails on what ran before it;
    // releasing on a sample count makes the ordering the test's own.
    //
    // One sequencer per cycle rather than one gate: several of these
    // cases need more than one source held, at different points, and
    // two independent counters over the same stream would each see the
    // other's releases.
    _Sequencer sequencerFor(RecordingObserver recorder) => _Sequencer(recorder);

    // A gate that is never opened. Pins that a cycle completed without
    // the source behind it: a hold that engaged there would show up as
    // the deadline in [syncWithoutWaiting], not as a later anchor.
    Future<void> never() => Completer<void>().future;

    // Freezes the receipt timeline for every case in this group.
    //
    // Stability compares consecutive resolves relative to the latest
    // receipt stamp, so a reference that advances between them shifts
    // the interval by the delta and resets the counter. NTS samples
    // carry real stamps, which puts "did this cycle reach stability"
    // at the mercy of whether two replies landed in the same
    // millisecond -- an ordering these cases do not own, and the reason
    // one of them passed in-file and failed run alone. A constant
    // reader makes every sample's stamp identical, so normalization is
    // the identity and the counter moves only with the consensus.
    setUp(
      () => TimeSample.debugSetReceiptReader(
        MonotonicReader(read: () => 0, isSleepAware: true),
      ),
    );
    tearDown(() => TimeSample.debugSetReceiptReader(null));

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
      final seq = sequencerFor(recorder);
      final engine = engineFor([
        verifiedNtsSource(host: 'fast1.a.example', startMs: 1000, endMs: 1020),
        verifiedNtsSource(host: 'fast2.b.example', startMs: 1005, endMs: 1025),
        TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
        verifiedNtsSource(
          host: 'slow.c.example',
          startMs: 1002,
          endMs: 1022,
          gate: seq.after(4),
        ),
      ], observer: seq);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(recorder.consensusReached.last.degradedTier, isFalse);
    });

    test(
      'a degraded result waits for a platform-with-fallback query',
      () async {
        // Same race as above, with the outstanding host under the trust
        // mode NtsSource itself defaults to -- what a consumer-supplied
        // source carries through additionalSources. platformWithFallback
        // reaches webpkiRoots when the native verifier is unavailable, so
        // it can still lift the cycle and the hold has to count it.
        final recorder = RecordingObserver();
        final seq = sequencerFor(recorder);
        final engine = engineFor([
          verifiedNtsSource(
            host: 'fast1.a.example',
            startMs: 1000,
            endMs: 1020,
          ),
          verifiedNtsSource(
            host: 'fast2.b.example',
            startMs: 1005,
            endMs: 1025,
          ),
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
          verifiedNtsSource(
            host: 'slow.c.example',
            startMs: 1002,
            endMs: 1022,
            gate: seq.after(4),
            trustMode: nts.TrustMode.platformWithFallback,
          ),
        ], observer: seq);

        final anchor = await engine.sync();

        expect(anchor.authLevel, NtsAuthLevel.verified);
        expect(recorder.consensusReached.last.degradedTier, isFalse);
      },
    );

    test('a degraded result waits for an opted-in custom source', () async {
      // The engine admits any sample carrying NtsAuthLevel.verified,
      // whatever produced it, so a custom source can be the third host
      // a truth box needs. Declaring VerifiedCapable is what makes the
      // hold count it -- without that the cycle would publish the
      // degraded anchor while the reply that closes the box is still in
      // flight, which is the asymmetry the interface exists to remove.
      final recorder = RecordingObserver();
      final seq = sequencerFor(recorder);
      final engine = engineFor([
        verifiedNtsSource(host: 'fast1.a.example', startMs: 1000, endMs: 1020),
        verifiedNtsSource(host: 'fast2.b.example', startMs: 1005, endMs: 1025),
        TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
        TierSource(
          id: 'custom:slow.c',
          groupId: 'gc',
          startMs: 1002,
          endMs: 1022,
          authLevel: NtsAuthLevel.verified,
          trustBackend: nts.TrustBackend.webpkiRoots,
          canProduceVerified: true,
          gate: seq.after(4),
        ),
      ], observer: seq);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(recorder.consensusReached.last.degradedTier, isFalse);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        contains('custom:slow.c'),
      );
    });

    test('a custom source that has not opted in is not waited for', () async {
      // The other side of the opt-in: capability is declared, not
      // inferred. This source would qualify for the box on arrival --
      // same interval and auth level as the case above -- but says
      // nothing about being able to produce one, so the cycle does not
      // spend its latency budget discovering that. Silence reads as
      // incapable rather than as capable-by-default, which keeps a
      // consumer's source from holding the early exit open on a promise
      // it never made.
      final recorder = RecordingObserver();
      final engine = engineFor(
        [
          verifiedNtsSource(
            host: 'fast1.a.example',
            startMs: 1000,
            endMs: 1020,
          ),
          verifiedNtsSource(
            host: 'fast2.b.example',
            startMs: 1000,
            endMs: 1020,
          ),
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(
            id: 'custom:silent.c',
            groupId: 'gc',
            startMs: 1000,
            endMs: 1020,
            authLevel: NtsAuthLevel.verified,
            trustBackend: nts.TrustBackend.webpkiRoots,
            gate: never,
          ),
        ],
        observer: recorder,
        maxLatency: const Duration(seconds: 30),
      );

      final anchor = await syncWithoutWaiting(engine);

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('custom:silent.c')),
      );
    });

    test('a platform-store reply is waited for and then refused the '
        'box', () async {
      // The two halves of platformWithFallback held apart. Capability
      // schedules the wait; the TrustBackend the handshake resolved
      // decides the label. This source is counted, so the cycle holds
      // for it -- and answers TrustBackend.platform, where an
      // inspection CA in the platform store could have terminated the
      // handshake off-device, so it classifies none and cannot help
      // form the box.
      //
      // Two verified hosts and this one is three replies against a
      // floor of three: the count alone would clear it. Only the
      // classification keeps the anchor degraded, which is what makes
      // this fail if capability ever leaks into the trust label.
      final recorder = RecordingObserver();
      final seq = sequencerFor(recorder);
      final engine = engineFor([
        verifiedNtsSource(host: 'fast1.a.example', startMs: 1000, endMs: 1020),
        verifiedNtsSource(host: 'fast2.b.example', startMs: 1005, endMs: 1025),
        TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
        platformNtsSource(
          host: 'inspected.c.example',
          startMs: 1002,
          endMs: 1022,
          gate: seq.after(4),
        ),
      ], observer: seq);

      final anchor = await engine.sync();

      // Held: the gate opens only on the fourth sample, so this reply
      // lands after the cycle is stable. A source not counted as
      // capable is not waited for, and its sample arrives too late to
      // be a contributor -- which is how the cases above pin a cycle
      // that completed without one.
      expect(
        anchor.contributors.map((c) => c.sourceId),
        contains('nts:inspected.c.example'),
      );
      // Refused: three replies, floor of three, still degraded.
      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
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

    test('a cycle that can no longer reach the floor is not held', () async {
      // An outstanding verified-capable query is not on its own
      // evidence that the wait can pay off. One verified host is
      // configured against a floor of three, so no arrival order can
      // ever produce a truth box -- and holding for it would spend up
      // to the full maxLatency arriving at the same degraded anchor.
      final recorder = RecordingObserver();
      final engine = engineFor(
        [
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:p3', groupId: 'g3', startMs: 1000, endMs: 1020),
          verifiedNtsSource(
            host: 'never.a.example',
            startMs: 1000,
            endMs: 1020,
            gate: never,
          ),
        ],
        observer: recorder,
        maxLatency: const Duration(seconds: 30),
      );

      final anchor = await syncWithoutWaiting(engine);

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('nts:never.a.example')),
      );
    });

    test('a platformOnly query is not waited for', () async {
      // The only mode canProduceVerified excludes, and so the only one
      // that must not hold a cycle. platformOnly refuses the webpki
      // fallback by construction: every outcome it has is
      // platform-mediated, classifies none, and cannot enter a box.
      //
      // Reachability cannot be what releases this cycle. Two verified
      // hosts are banked and this is a third responder, so counting it
      // would put the floor of three in reach and hold for the full
      // maxLatency -- arriving at the degraded anchor it already had.
      // Only incapability keeps the cycle moving, which is what makes
      // this fail if the excluded arm is ever admitted.
      final recorder = RecordingObserver();
      final engine = engineFor(
        [
          verifiedNtsSource(
            host: 'fast1.a.example',
            startMs: 1000,
            endMs: 1020,
          ),
          verifiedNtsSource(
            host: 'fast2.b.example',
            startMs: 1000,
            endMs: 1020,
          ),
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          platformNtsSource(
            host: 'platform.c.example',
            startMs: 1000,
            endMs: 1020,
            gate: never,
            trustMode: nts.TrustMode.platformOnly,
          ),
        ],
        observer: recorder,
        maxLatency: const Duration(seconds: 30),
      );

      final anchor = await syncWithoutWaiting(engine);

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('nts:platform.c.example')),
      );
    });

    test('two instances of one host are one host for reachability', () async {
      // Reachability is over hosts, so the queries still in flight have
      // to be collapsed by id the same way the floor collapses banked
      // samples. A cycle can query one id twice: while both instances
      // are healthy the engine collapses them, but the starvation
      // rescue re-admits from the source list directly, so a
      // cooled-down id backed by two instances is force-included once
      // per instance.
      //
      // One verified host banked and one verified id outstanding cannot
      // reach a floor of three. Counting query objects instead makes
      // that look like 1 + 2 and holds the cycle for the full latency
      // budget on a box that cannot form.
      final recorder = RecordingObserver();
      // The id's first query fails, which arms the cooldown ladder and
      // makes the rescue the only way back in. Every call after that
      // hangs, so both rescued instances are in flight when the cycle
      // turns stable. Shared across the instances because the cooldown
      // belongs to the id, not to either of them -- and while both are
      // healthy the engine collapses them, so only one query is issued
      // and only one failure is available to arm it.
      var failed = false;
      Future<void> dupGate() {
        if (failed) return Completer<void>().future;
        failed = true;
        throw StateError('cold');
      }

      final engine = engineFor(
        [
          verifiedNtsSource(host: 'a.example', startMs: 1000, endMs: 1020),
          // Three lower-tier hosts on one interval, not two: the cycle
          // has to reach stability while the duplicated id is still in
          // flight, and stability needs two resolves that agree.
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:p3', groupId: 'g3', startMs: 1000, endMs: 1020),
          for (var i = 0; i < 2; i++)
            verifiedNtsSource(
              host: 'dup.example',
              startMs: 1000,
              endMs: 1020,
              gate: dupGate,
            ),
        ],
        observer: recorder,
        maxLatency: const Duration(seconds: 30),
      );

      // The first cycle fails the id; the five after it are what the
      // starvation guard counts before re-admitting both instances.
      for (var i = 0; i < 5; i++) {
        await syncWithoutWaiting(engine);
      }
      final anchor = await syncWithoutWaiting(engine);

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('nts:dup.example')),
      );
    });

    test('a held cycle outlives one instance of a duplicated verified '
        'host failing', () async {
      // The other half of the multiset. Collapsing by id is what keeps
      // reachability honest; keeping a count per id is what keeps the
      // hold alive while any instance of that id is still in flight.
      // Dropping the id on the first outcome instead would release a
      // degraded anchor here, discarding the box the second instance
      // goes on to close -- the same trade the reachability case makes
      // in the other direction, and the expensive one.
      //
      // Two verified hosts bank, one short of the floor, and the
      // duplicated id supplies the third: its first instance fails
      // after the cycle is held, its second then answers.
      final recorder = RecordingObserver();
      final seq = sequencerFor(recorder);

      // The rescue is the only way to get two instances of one id
      // queried together, and a failure is the only way into it: while
      // both instances are healthy the engine collapses them. So the
      // id's first query fails outright to arm the cooldown, and the
      // instance's second query -- in the rescue cycle -- is the one
      // held back until the cycle is stable.
      var dupQueries = 0;
      final firstInstanceFailed = Completer<void>();
      Future<void> failingGate() async {
        dupQueries++;
        if (dupQueries == 1) return;
        await seq.after(3)();
        if (!firstInstanceFailed.isCompleted) firstInstanceFailed.complete();
      }

      // Ordered behind the failure reaching the engine's listener, not
      // merely behind the throw: the release path runs there, so a
      // sample that overtook it would close the box before the hold was
      // ever asked to survive the failure -- and would pass against a
      // plain set just the same.
      Future<void> liftingGate() async {
        await firstInstanceFailed.future;
        await pumpEventQueue();
      }

      final engine = engineFor(
        [
          verifiedNtsSource(host: 'a.example', startMs: 1000, endMs: 1020),
          verifiedNtsSource(host: 'b.example', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          failingVerifiedNtsSource(host: 'dup.example', gate: failingGate),
          verifiedNtsSource(
            host: 'dup.example',
            startMs: 1000,
            endMs: 1020,
            gate: liftingGate,
          ),
          // Keeps _finalizeSync out of it: with a query still
          // outstanding, the only route to an anchor is the early exit,
          // so what the cycle publishes is what the hold decided.
          _GatedTierSource(
            id: 'ntp:never',
            groupId: 'g2',
            startMs: 1000,
            endMs: 1020,
            gate: never,
          ),
        ],
        observer: seq,
        maxLatency: const Duration(seconds: 30),
      );

      // The first cycle fails the id; the four after it are what the
      // starvation guard counts before re-admitting both instances.
      for (var i = 0; i < 5; i++) {
        await syncWithoutWaiting(engine);
      }
      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(recorder.consensusReached.last.degradedTier, isFalse);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        contains('nts:dup.example'),
      );
    });

    test('a verified failure releases a hold it was the last reason '
        'for', () async {
      // The hold has to end on the terminal outcome of the query it was
      // waiting on, not on whatever else the cycle happens to be doing.
      // A failed query yields no sample, so it reaches none of the
      // resolution path, and the only other source outstanding here
      // never answers -- so nothing but re-examining the hold on the
      // failure itself can finish this cycle inside the deadline.
      //
      // Two verified hosts answer, one short of the floor, and the
      // third fails only after the cycle is stable and therefore
      // already held.
      final recorder = RecordingObserver();
      final seq = sequencerFor(recorder);
      final engine = engineFor(
        [
          verifiedNtsSource(
            host: 'fast1.a.example',
            startMs: 1000,
            endMs: 1020,
          ),
          verifiedNtsSource(
            host: 'fast2.b.example',
            startMs: 1000,
            endMs: 1020,
          ),
          TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
          failingVerifiedNtsSource(host: 'down.c.example', gate: seq.after(3)),
          _GatedTierSource(
            id: 'ntp:never',
            groupId: 'g2',
            startMs: 1000,
            endMs: 1020,
            gate: never,
          ),
        ],
        observer: seq,
        maxLatency: const Duration(seconds: 30),
      );

      final anchor = await syncWithoutWaiting(engine);

      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(recorder.consensusReached.last.degradedTier, isTrue);
      expect(
        anchor.contributors.map((c) => c.sourceId),
        isNot(contains('ntp:never')),
      );
    });

    test('the sample that lifts a held cycle is not overruled by the '
        'snapshot', () async {
      // A held snapshot describes the population it was reduced from,
      // and the arrival that ends the hold is often the one that moves
      // that population. Here the third verified host closes the box on
      // a tighter interval than the degraded consensus, so the
      // stability counter resets and the block that would replace the
      // snapshot does not run -- while the same arrival drops the
      // pending balance to zero and so ends the hold. Publishing the
      // snapshot there would discard the verified result the wait was
      // for, turning the hold into a way of losing the box it exists to
      // protect.
      final recorder = RecordingObserver();
      final seq = sequencerFor(recorder);
      final engine = engineFor([
        verifiedNtsSource(host: 'fast1.a.example', startMs: 1000, endMs: 1020),
        verifiedNtsSource(host: 'fast2.b.example', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p1', groupId: 'g1', startMs: 1000, endMs: 1020),
        TierSource(id: 'ntp:p2', groupId: 'g2', startMs: 1000, endMs: 1020),
        verifiedNtsSource(
          host: 'slow.c.example',
          startMs: 1008,
          endMs: 1014,
          gate: seq.after(4),
        ),
      ], observer: seq);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(recorder.consensusReached.last.degradedTier, isFalse);
      // The snapshot's population was the four samples banked before
      // the box formed, so publishing it would show up here as a
      // missing contributor even though the source answered.
      expect(
        anchor.contributors.map((c) => c.sourceId),
        contains('nts:slow.c.example'),
      );
    });

    test('an all-NTP cycle still exits early', () async {
      // Every cycle here is legitimately degraded and no source could
      // ever lift it, so the hold must not engage -- otherwise it
      // becomes a blanket early-exit disable for NTP-only installs.
      // The gated source would never be released, so the cycle can only
      // finish by exiting early on the first three.
      final recorder = RecordingObserver();
      final engine = engineFor(
        [
          TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1000, endMs: 1020),
          TierSource(id: 'ntp:c', groupId: 'g3', startMs: 1000, endMs: 1020),
          _GatedTierSource(
            id: 'ntp:slow',
            groupId: 'g4',
            startMs: 1002,
            endMs: 1022,
            gate: never,
          ),
        ],
        observer: recorder,
        maxLatency: const Duration(seconds: 30),
      );

      final anchor = await syncWithoutWaiting(engine);

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

/// Forwards to [inner] while releasing gates handed out by [after] once
/// the engine's listener has consumed a given number of samples.
///
/// Lets a test order sources' replies behind a known number of others
/// without a wall-clock delay, which would settle the race on
/// event-loop timing rather than on the behaviour under test. One
/// instance serves a whole cycle, so several gates share a single
/// count of what the engine has actually seen.
class _Sequencer implements SyncObserver {
  _Sequencer(this.inner);

  final RecordingObserver inner;
  final _pending = <int, Completer<void>>{};
  int _seen = 0;

  /// A gate that opens once [samples] samples of the current cycle have
  /// reached the engine.
  ///
  /// The count is per cycle, so the closure resolves its completer on
  /// each call rather than capturing the one registered here: a test
  /// that runs several cycles would otherwise find every gate already
  /// open from the replies of the first.
  Future<void> Function() after(int samples) {
    _pending.putIfAbsent(samples, Completer<void>.new);
    return () {
      final gate = _pending.putIfAbsent(samples, Completer<void>.new);
      if (_seen >= samples && !gate.isCompleted) gate.complete();
      return gate.future;
    };
  }

  @override
  void onSampleReceived(TimeSample sample) {
    inner.onSampleReceived(sample);
    _seen++;
    for (final entry in _pending.entries) {
      if (_seen >= entry.key && !entry.value.isCompleted) {
        entry.value.complete();
      }
    }
  }

  @override
  void onSourceFailed(String sourceId, Object error) =>
      inner.onSourceFailed(sourceId, error);

  @override
  void onSyncStarted() {
    // A gate counts this cycle's replies only. Cycles are sequential
    // here, and onSyncStarted precedes every query in one, so clearing
    // both here leaves a multi-cycle test ordering each cycle the same
    // way the single-cycle cases order theirs.
    _seen = 0;
    _pending.clear();
    inner.onSyncStarted();
  }

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
