import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

/// An NTS [TimeSource] that returns a scripted sequence of round-trip
/// delays across successive [getTime] calls, so the validate-tier
/// burst's lowest-RTT selection can be exercised deterministically. A
/// `null` entry makes that call throw, exercising partial-failure
/// tolerance.
class _BurstNtsSource implements TimeSource {
  _BurstNtsSource(this._delaysMs);

  final List<int?> _delaysMs;
  static const int midpointMs = 1000;
  int calls = 0;

  @override
  final String id = 'nts:burst';
  @override
  final String groupId = 'gburst';

  @override
  Future<TimeSample> getTime() async {
    final i = calls++;
    final d = i < _delaysMs.length ? _delaysMs[i] : _delaysMs.last;
    if (d == null) throw StateError('burst attempt $i failed');
    final half = d ~/ 2;
    return TimeSample(
      interval: TimeInterval(
        startMs: midpointMs - half,
        endMs: midpointMs + half,
      ),
      sourceId: id,
      groupId: groupId,
      delayMs: d,
    );
  }
}

/// An NTS [TimeSource] whose [warm] never completes, to exercise the
/// warm-await bound on the validate path: a hung handshake must not
/// stall the freshness probe past [SyncEngine.warmBarrierCap].
class _HungWarmNtsSource implements TimeSource, Warmable {
  @override
  final String id = 'nts:hung-warm';
  @override
  final String groupId = 'ghung';

  @override
  Future<void> warm() => Completer<void>().future;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: const TimeInterval(startMs: 990, endMs: 1010),
    sourceId: id,
    groupId: groupId,
    delayMs: 20,
  );
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
  int? validateBurstCount,
}) {
  return SyncEngine(
    config:
        const TrustedTimeConfig(
          minimumQuorum: 2,
          minGroupCount: 1,
          // Wait for every source each cycle so admission is deterministic and
          // does not depend on which sample wins the early-exit race.
          earlyExit: false,
          ntpServers: [],
          httpsSources: [],
          ntsServers: [],
        ).copyWith(
          additionalSources: sources,
          validateBurstCount: validateBurstCount,
        ),
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

    test('bursts the source and returns the lowest-RTT sample', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      // Default burst is 4; the second attempt has the smallest delay.
      final source = _BurstNtsSource([80, 20, 50, 60]);
      final engine = _engineFor([source], observer: observer, events: events);

      final sample = await engine.validate();

      expect(source.calls, 4);
      expect(sample.delayMs, 20);
      expect(sample.uncertaintyMs, 10);
    });

    test('tolerates partial failures and returns the best success', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      // Two of four attempts fail; the best successful delay is 10.
      final source = _BurstNtsSource([null, 30, null, 10]);
      final engine = _engineFor([source], observer: observer, events: events);

      final sample = await engine.validate();

      expect(source.calls, 4);
      expect(sample.delayMs, 10);
      // Each failed attempt is reported to the observer.
      expect(
        observer.failures.where((f) => f.sourceId == 'nts:burst').length,
        2,
      );
    });

    test('honors a configured validateBurstCount', () async {
      final observer = _RecordingObserver();
      final events = <IntegrityEvent>[];
      final source = _BurstNtsSource([50, 10, 5, 1]);
      final engine = _engineFor(
        [source],
        observer: observer,
        events: events,
        validateBurstCount: 2,
      );

      final sample = await engine.validate();

      // Only the first two attempts run; min(50, 10) = 10.
      expect(source.calls, 2);
      expect(sample.delayMs, 10);
    });

    test('a hung warm() cannot stall the probe past warmBarrierCap', () {
      // Pins the Phase A warm-await bound: validate() has no outer
      // safety timeout (unlike sync()), so without the cap a warm()
      // that never completes would hang the probe — and any headless
      // OS budget above it — indefinitely.
      fakeAsync((async) {
        final observer = _RecordingObserver();
        final events = <IntegrityEvent>[];
        final engine = _engineFor(
          [_HungWarmNtsSource()],
          observer: observer,
          events: events,
        );

        TimeSample? sample;
        unawaited(engine.validate().then((s) => sample = s));

        // Just before the cap: still blocked on the hung warm.
        async.elapse(SyncEngine.warmBarrierCap - const Duration(seconds: 1));
        expect(sample, isNull);

        // Past the cap: the probe abandons the warm await, runs the
        // burst, and completes. The timed-out warm is reported to the
        // observer as a warm-phase failure.
        async.elapse(const Duration(seconds: 2));
        expect(sample, isNotNull);
        expect(sample!.sourceId, 'nts:hung-warm');
        expect(
          observer.failures.any(
            (f) =>
                f.sourceId == 'nts:hung-warm' && '${f.error}'.contains('warm'),
          ),
          isTrue,
        );
      });
    });
  });
}
