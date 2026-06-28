import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/infra/sync_observer.dart';
import 'package:trusted_time/src/integrity_event.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sources/nts_auth_level.dart';
import 'package:trusted_time/src/sync_engine.dart';

class _MockClock implements MonotonicClock {
  @override
  Future<int> uptimeMs() async => 100000;
}

/// A [TimeSource] whose sample interval, auth level, and trust backend are
/// fully specified so tier classification can be exercised deterministically.
class _TierSource implements TimeSource {
  _TierSource({
    required this.id,
    required this.groupId,
    required this.startMs,
    required this.endMs,
    this.authLevel = NtsAuthLevel.none,
    this.trustBackend,
  });

  @override
  final String id;
  @override
  final String groupId;
  final int startMs;
  final int endMs;
  final NtsAuthLevel authLevel;
  final nts.TrustBackend? trustBackend;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: startMs, endMs: endMs),
    sourceId: id,
    groupId: groupId,
    authLevel: authLevel,
    trustBackend: trustBackend,
  );
}

/// A [TimeSource] whose [getTime] always throws, to exercise the
/// freshness-probe query-failure path.
class _FailingNtsSource implements TimeSource {
  @override
  final String id = 'nts:fail';
  @override
  final String groupId = 'gfail';

  @override
  Future<TimeSample> getTime() async => throw StateError('probe boom');
}

class _RecordingObserver implements SyncObserver {
  final List<ConsensusResult> consensus = [];
  final List<({String sourceId, Object error})> failures = [];

  @override
  void onConsensusReached(ConsensusResult result) => consensus.add(result);
  @override
  void onSourceFailed(String sourceId, Object error) =>
      failures.add((sourceId: sourceId, error: error));
  @override
  void onSampleReceived(TimeSample sample) {}
  @override
  void onSyncStarted() {}
  @override
  void onSyncFailed(Object error) {}
  @override
  void onMetricsReported(SyncMetrics metrics) {}
}

SyncEngine _engineFor(
  List<TimeSource> sources, {
  required _RecordingObserver observer,
  required List<IntegrityEvent> events,
}) {
  return SyncEngine(
    config: const TrustedTimeConfig(
      minimumQuorum: 2,
      minGroupCount: 1,
      // Wait for every source each cycle so admission is deterministic and
      // does not depend on which sample wins the early-exit race.
      earlyExit: false,
      ntpServers: [],
      httpsSources: [],
      ntsServers: [],
    ).copyWith(additionalSources: sources),
    clock: _MockClock(),
    observer: observer,
    onIntegrityEvent: events.add,
  );
}

void main() {
  group('SyncEngine tier-aware admission', () {
    test('Tier 1 quorum forms the truth box and admits only intersecting '
        'lower-tier samples', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      // Two verified samples overlap at [1005, 1020] — the truth box.
      final engine = _engineFor(
        [
          _TierSource(
            id: 'nts:v1',
            groupId: 'g1',
            startMs: 1000,
            endMs: 1020,
            authLevel: NtsAuthLevel.verified,
            trustBackend: nts.TrustBackend.webpkiRoots,
          ),
          _TierSource(
            id: 'nts:v2',
            groupId: 'g2',
            startMs: 1005,
            endMs: 1025,
            authLevel: NtsAuthLevel.verified,
            trustBackend: nts.TrustBackend.webpkiRoots,
          ),
          // Platform-mediated NTS (Tier 2) inside the truth box.
          _TierSource(
            id: 'nts:in',
            groupId: 'g3',
            startMs: 1010,
            endMs: 1015,
            trustBackend: nts.TrustBackend.platform,
          ),
          // Platform-mediated NTS (Tier 2) outside the truth box.
          _TierSource(
            id: 'nts:out',
            groupId: 'g4',
            startMs: 1100,
            endMs: 1120,
            trustBackend: nts.TrustBackend.platform,
          ),
        ],
        observer: observer,
        events: events,
      );

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      final result = observer.consensus.single;
      expect(result.degradedTier, isFalse);
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
      expect(participantIds, contains('nts:in'));
      expect(participantIds, isNot(contains('nts:out')));
      expect(
        result.droppedOutsideTruthBox.map((s) => s.sourceId),
        contains('nts:out'),
      );
      expect(
        observer.failures.any(
          (f) =>
              f.sourceId == 'nts:out' && f.error == 'tier2: outside truth box',
        ),
        isTrue,
      );
      expect(events, isEmpty);
    });

    test('Tier 1 quorum fails: legacy single-tier reduction with a '
        'degradedTier integrity event', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      // No verified samples. Three lower-tier samples (one platform-mediated
      // NTS, two plain) agree at [1005, 1020].
      final engine = _engineFor(
        [
          _TierSource(
            id: 'nts:a',
            groupId: 'g1',
            startMs: 1000,
            endMs: 1020,
            trustBackend: nts.TrustBackend.platform,
          ),
          _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
          _TierSource(id: 'ntp:c', groupId: 'g3', startMs: 1000, endMs: 1020),
        ],
        observer: observer,
        events: events,
      );

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.none);
      final result = observer.consensus.single;
      expect(result.degradedTier, isTrue);
      expect(result.authLevel, NtsAuthLevel.none);
      expect(result.droppedOutsideTruthBox, isEmpty);
      // All three samples are admitted under the legacy reduction.
      expect(
        result.participants.map((s) => s.sourceId),
        containsAll(<String>['nts:a', 'ntp:b', 'ntp:c']),
      );
      expect(events, hasLength(1));
      expect(events.single.reason, TamperReason.degradedTier);
    });

    test('coordinated lower-tier cluster outside the truth box cannot move '
        'the consensus', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      // Two verified samples agree near T (~10012). Three coordinated
      // lower-tier samples cluster at T+10s, well outside the truth box.
      final engine = _engineFor(
        [
          _TierSource(
            id: 'nts:v1',
            groupId: 'g1',
            startMs: 10000,
            endMs: 10020,
            authLevel: NtsAuthLevel.verified,
            trustBackend: nts.TrustBackend.webpkiRoots,
          ),
          _TierSource(
            id: 'nts:v2',
            groupId: 'g2',
            startMs: 10005,
            endMs: 10025,
            authLevel: NtsAuthLevel.verified,
            trustBackend: nts.TrustBackend.webpkiRoots,
          ),
          _TierSource(
            id: 'nts:x',
            groupId: 'g3',
            startMs: 20005,
            endMs: 20025,
            trustBackend: nts.TrustBackend.platform,
          ),
          _TierSource(id: 'ntp:y', groupId: 'g4', startMs: 20000, endMs: 20020),
          _TierSource(id: 'ntp:z', groupId: 'g5', startMs: 20005, endMs: 20025),
        ],
        observer: observer,
        events: events,
      );

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      final result = observer.consensus.single;
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
      expect(events, isEmpty);
    });
  });

  group('SyncEngine.validate() freshness probe (ADR 0006)', () {
    test('returns the sample from the top-ranked NTS source', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      final engine = _engineFor(
        [
          _TierSource(
            id: 'nts:probe',
            groupId: 'g1',
            startMs: 1000,
            endMs: 1020,
            authLevel: NtsAuthLevel.verified,
            trustBackend: nts.TrustBackend.webpkiRoots,
          ),
        ],
        observer: observer,
        events: events,
      );

      final sample = await engine.validate();

      expect(sample.sourceId, 'nts:probe');
      expect(sample.interval.midpoint, 1010);
    });

    test('throws TrustedTimeFreshnessProbeException when no NTS source '
        'is configured', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      final engine = _engineFor(
        [
          _TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          _TierSource(id: 'https:b', groupId: 'g2', startMs: 1000, endMs: 1020),
        ],
        observer: observer,
        events: events,
      );

      await expectLater(
        engine.validate(),
        throwsA(isA<TrustedTimeFreshnessProbeException>()),
      );
    });

    test('throws TrustedTimeFreshnessProbeException when the probe query '
        'fails', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      final engine = _engineFor(
        [_FailingNtsSource()],
        observer: observer,
        events: events,
      );

      await expectLater(
        engine.validate(),
        throwsA(isA<TrustedTimeFreshnessProbeException>()),
      );
      expect(observer.failures.any((f) => f.sourceId == 'nts:fail'), isTrue);
    });
  });
}
