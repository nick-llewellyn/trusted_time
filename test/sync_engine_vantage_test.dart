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

/// Four anycast hosts (above the baseline's responder floor) and four
/// unicast explorer candidates, all answering at [rttMs].
({TrustedTimeConfig config, List<_RttSource> anycast}) _fixture(int rttMs) {
  final entries = <NtpServerInfo>[
    for (var i = 0; i < 4; i++)
      NtpServerInfo(
        host: 'any$i.test',
        tier: NtpServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      ),
    for (var i = 0; i < 4; i++)
      NtpServerInfo(
        host: 'uni$i.test',
        tier: NtpServerTier.unicastStratum1,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      ),
  ];
  final anycast = [for (var i = 0; i < 4; i++) _RttSource('any$i.test', rttMs)];
  final unicast = [
    // Deliberately far slower than the anycast hosts: were the unicast
    // half feeding the baseline, its round trip would dominate the
    // median and no anycast move could be read at all.
    for (var i = 0; i < 4; i++) _RttSource('uni$i.test', 900),
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
      // The explorers answer at 900 ms against the quorum's 25 ms, so
      // a leak would be visible in the median immediately.
      final fixture = _fixture(25);
      final engine = _engine(fixture.config, budget: 4);
      await run(engine, 1);
      expect(engine.vantageBaseline.ewmaRttMs, 25);
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
