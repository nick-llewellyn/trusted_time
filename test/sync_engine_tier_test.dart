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

class _MockClock implements MonotonicClock {
  _MockClock({this.bootId = 'boot-test'});

  final String? bootId;

  @override
  Future<int> uptimeMs() async => 100000;
  @override
  Future<String?> getBootId() async => bootId;
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
/// per-source failure logging path.
class _FailingNtsSource implements TimeSource {
  @override
  final String id = 'nts:fail';
  @override
  final String groupId = 'gfail';

  @override
  Future<TimeSample> getTime() async => throw StateError('source boom');
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
  MonotonicClock? clock,
}) {
  return SyncEngine(
    config: const TrustedTimeConfig(
      minimumQuorum: 2,
      minGroupCount: 1,
      // Wait for every source each cycle so admission is deterministic and
      // does not depend on which sample wins the early-exit race.
      earlyExit: false,
      ntpServers: [],
      ntsServers: [],
    ).copyWith(additionalSources: sources),
    clock: clock ?? _MockClock(),
    observer: observer,
  );
}

void main() {
  group('SyncEngine tier-aware admission', () {
    test('Tier 1 quorum forms the truth box and admits only intersecting '
        'lower-tier samples', () async {
      final observer = _RecordingObserver();
      // Two verified samples overlap at [1005, 1020] — the truth box.
      final engine = _engineFor([
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
      ], observer: observer);

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
    });

    test('Tier 1 quorum fails: legacy single-tier reduction flagged '
        'degradedTier', () async {
      final observer = _RecordingObserver();
      // No verified samples. Three lower-tier samples (one platform-mediated
      // NTS, two plain) agree at [1005, 1020].
      final engine = _engineFor([
        _TierSource(
          id: 'nts:a',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          trustBackend: nts.TrustBackend.platform,
        ),
        _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        _TierSource(id: 'ntp:c', groupId: 'g3', startMs: 1000, endMs: 1020),
      ], observer: observer);

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
    });

    test('coordinated lower-tier cluster outside the truth box cannot move '
        'the consensus', () async {
      final observer = _RecordingObserver();
      // Two verified samples agree near T (~10012). Three coordinated
      // lower-tier samples cluster at T+10s, well outside the truth box.
      final engine = _engineFor([
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
      ], observer: observer);

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
      final observer = _RecordingObserver();
      final engine = _engineFor([
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
        _TierSource(id: 'ntp:in', groupId: 'g3', startMs: 1010, endMs: 1015),
        _TierSource(id: 'ntp:out', groupId: 'g4', startMs: 1100, endMs: 1120),
        _FailingNtsSource(),
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
      final observer = _RecordingObserver();
      final engine = _engineFor([
        _TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
        _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
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
      final observer = _RecordingObserver();
      final engine = _engineFor([
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
      final observer = _RecordingObserver();
      final engine = _engineFor(
        [
          _TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        ],
        observer: observer,
        clock: _MockClock(bootId: 'boot-uuid-42'),
      );

      final anchor = await engine.sync();

      expect(anchor.bootId, 'boot-uuid-42');
    });

    test('sync() leaves the anchor bootId null when the platform provides '
        'none (fails closed on later warm restore)', () async {
      final observer = _RecordingObserver();
      final engine = _engineFor(
        [
          _TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        ],
        observer: observer,
        clock: _MockClock(bootId: null),
      );

      final anchor = await engine.sync();

      expect(anchor.bootId, isNull);
    });
  });
}
