import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/explorer_shuffle.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/domain/vantage_baseline.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';

/// A source answering instantly with a caller-controlled round trip.
///
/// [delayMs] is mutable so one engine can be walked across a simulated
/// network move without rebuilding it — which is the point, since the
/// baseline is engine state and a rebuild would reset it.
class _RttSource implements TimeSource {
  _RttSource(String host, this.delayMs) : id = '${TimeSource.prefixNtp}$host';
  @override
  final String id;
  @override
  final String groupId = 'as1';
  int delayMs;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: 1000, endMs: 1020),
    sourceId: id,
    groupId: groupId,
    delayMs: delayMs,
  );
}

/// An [_RttSource] that fails its first query and answers every one
/// after, so the engine blacklists its id long enough for the
/// starvation rescue to become the path that re-admits it.
class _FlakyRttSource extends _RttSource {
  _FlakyRttSource(super.host, super.delayMs);
  var _failed = false;

  @override
  Future<TimeSample> getTime() {
    if (_failed) return super.getTime();
    _failed = true;
    throw StateError('cold');
  }
}

/// Round trip every unicast explorer answers at, held far above any
/// anycast value a test uses: were the explorer half feeding the
/// baseline, its round trip would dominate the median and no anycast
/// move could be read at all.
const _explorerRttMs = 900;

/// Four anycast hosts (above the baseline's responder floor) answering
/// at [rttMs], plus four unicast explorer candidates answering at a
/// fixed [_explorerRttMs] that no test varies.
///
/// Only the anycast half is returned, since it is the only half a test
/// has reason to move.
({TrustedTimeConfig config, List<_RttSource> anycast}) _fixture(int rttMs) {
  final entries = <NtpServerInfo>[
    for (var i = 0; i < 4; i++)
      NtpServerInfo(
        host: 'any$i.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      ),
    for (var i = 0; i < 4; i++)
      NtpServerInfo(
        host: 'uni$i.test',
        tier: TimeServerTier.unicastStratum1,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      ),
  ];
  final anycast = [for (var i = 0; i < 4; i++) _RttSource('any$i.test', rttMs)];
  final unicast = [
    for (var i = 0; i < 4; i++) _RttSource('uni$i.test', _explorerRttMs),
  ];
  return (
    config: TrustedTimeConfig(
      ntsServers: const [],
      disableNtpForTesting: true,
      ntpInventoryForTesting: entries,
      additionalSources: [...anycast, ...unicast],
      minGroupCount: 1,
      // Every anycast host must answer for the RTT population to be
      // the one the test set up; early exit would truncate it.
      earlyExit: false,
    ),
    anycast: anycast,
  );
}

SyncEngine _engine(
  TrustedTimeConfig config, {
  SourceQualityTracker? tracker,
  int budget = 2,
}) => SyncEngine(
  config: config,
  clock: FakeMonotonicClock(),
  qualityTracker: tracker,
  explorerShuffle: const ExplorerShuffle(7),
  explorerBudget: budget,
);

/// Runs [cycles] sync cycles, letting the unawaited explorer probes
/// land between them.
Future<void> run(SyncEngine engine, int cycles) async {
  for (var i = 0; i < cycles; i++) {
    await engine.sync();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('baseline observation', () {
    test('a banked cycle folds the anycast round trips in', () async {
      final fixture = _fixture(25);
      final engine = _engine(fixture.config);
      expect(engine.vantageBaseline.ewmaRttMs, isNull);

      await run(engine, 1);
      expect(engine.vantageBaseline.ewmaRttMs, 25);
      expect(engine.vantageBaseline.observationCount, 1);
    });

    test('unicast explorers are kept out of the baseline', () async {
      // The explorers answer at [_explorerRttMs] against the quorum's
      // 25 ms, so a leak would be visible in the median immediately.
      final fixture = _fixture(25);
      final engine = _engine(fixture.config, budget: 4);
      await run(engine, 1);
      expect(engine.vantageBaseline.ewmaRttMs, 25);
    });

    test('a host backed by two sources answers once', () async {
      // Two anycast hosts, one of them backed by a colliding pair of
      // sources. While both are healthy the engine collapses them and
      // the duplicate is unreachable; the starvation rescue re-admits
      // from the source list directly, so it force-includes each
      // instance and the id is queried twice in one cycle. Arm that by
      // failing the id once, which blacklists it for far longer than
      // the five cycles starvation takes to fire.
      final entries = <NtpServerInfo>[
        for (final host in ['dup.test', 'any.test'])
          NtpServerInfo(
            host: host,
            tier: TimeServerTier.anycast,
            observedStratum: 1,
            observedGroupId: 'as1',
            leapPolicy: LeapPolicy.documentedStepping,
          ),
      ];
      final engine = _engine(
        TrustedTimeConfig(
          ntsServers: const [],
          disableNtpForTesting: true,
          ntpInventoryForTesting: entries,
          additionalSources: [
            _FlakyRttSource('dup.test', 25),
            _RttSource('dup.test', 25),
            _RttSource('any.test', 25),
            // Outside the inventory, so they block unconditionally and
            // carry the consensus while the anycast half stays at two
            // hosts — one below the baseline's responder floor.
            for (var i = 0; i < 3; i++)
              _RttSource('filler$i.test', _explorerRttMs),
          ],
          minGroupCount: 1,
          earlyExit: false,
        ),
      );

      // Six cycles: the first fails `dup.test` and the five after it
      // are what the starvation guard counts before re-admitting.
      await run(engine, 6);
      expect(
        engine.vantageBaseline.ewmaRttMs,
        isNull,
        reason: 'two hosts answered, whatever the sample count',
      );
    });

    test('a restored baseline is what the next cycle measures against', () {
      final engine = _engine(_fixture(25).config)
        ..restoreVantageBaseline(
          const VantageBaseline(ewmaRttMs: 30, observationCount: 5, epoch: 2),
        );
      expect(engine.vantageBaseline.epoch, 2);
      expect(engine.vantageBaseline.ewmaRttMs, 30);
    });
  });

  group('epoch change', () {
    test(
      'a sustained move re-sweeps the inventory and widens the walk',
      () async {
        final fixture = _fixture(25);
        final tracker = SourceQualityTracker();
        final engine = _engine(fixture.config, tracker: tracker);

        await run(engine, 4);
        expect(engine.vantageBaseline.epoch, 0);
        expect(engine.explorerBoostRemaining, 0);
        final probed = tracker.lastProbedUtcMs(
          '${TimeSource.prefixNtp}any0.test',
        );
        expect(probed, isNotNull, reason: 'the quorum was measured from here');

        for (final s in fixture.anycast) {
          s.delayMs = 400;
        }
        await run(engine, 2);

        expect(engine.vantageBaseline.epoch, 1);
        expect(
          tracker.lastProbedUtcMs('${TimeSource.prefixNtp}any0.test'),
          isNull,
          reason: 'every source rejoins the unprobed end of the walk',
        );
        expect(engine.explorerBoostRemaining, SyncEngine.explorerBoostCycles);
      },
    );
  });
}
