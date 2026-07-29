// Diagnostic harnesses for open audits against the marzullo engine.
//
// These groups pin *current* behaviour rather than asserting a desired
// contract: each one is a unit-level witness for an empirical signature
// seen on-device, kept so that any future change to the engine is
// observable at review time. They are separated from marzullo_test.dart
// because they answer "what does it do today, and why does that look
// wrong" — not "what must it do".
//
// The enclosing group name and the `createSample` helper mirror
// marzullo_test.dart so test IDs are unchanged by the split.

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_interval.dart';

void main() {
  group('MarzulloEngine', () {
    const engine = MarzulloEngine(minQuorumRatio: 0.6);
    final baseTime = DateTime.utc(2024, 6, 15, 12, 0, 0);

    TimeSample createSample({
      required String id,
      required DateTime utc,
      required int uncertaintyMs,
      String? groupId,
    }) {
      final ms = utc.millisecondsSinceEpoch;
      return TimeSample(
        sourceId: id,
        groupId: groupId ?? id,
        interval: TimeInterval(
          startMs: ms - uncertaintyMs,
          endMs: ms + uncertaintyMs,
        ),
      );
    }

    // Diagnostic harness for trusted_time-skj.1: confirms at unit level that
    // a single high-precision-but-isolated sample (e.g. NTS with a tight
    // RTT/2-derived window) added to a cluster of wider samples (e.g. HTTPS
    // with Date-header-granularity windows) can refuse consensus the cluster
    // alone would reach. Mechanism: requiredQuorum = ceil(N x minQuorumRatio)
    // grows with totalSources, but a sample whose interval does not overlap
    // the densest region cannot contribute to the overlap depth that meets
    // requiredQuorum. The narrow sample raises the bar without helping clear
    // it. No fix is landed under skj.1 because the parent audit
    // (trusted_time-skj) has not yet decided whether the current behaviour
    // is a defect or correct algorithmic refusal; this group pins the
    // current behaviour so any future change is observable.
    group('trusted_time-skj.1 diagnostic: '
        'narrow sample interaction with wider-cluster quorum', () {
      // Mirrors the on-device sample-window envelope from the bd's empirical
      // log (Pixel Tablet, 2026-05-08): NTS half=15ms, HTTPS half=87..149ms,
      // NTP half=23..102ms. Per-source midpoint offsets are speculative
      // (the engine logs window widths but not centers); these values are
      // chosen to land the HTTPS+NTP cluster's densest overlap at exactly
      // four samples, matching the on-device "got 7 eligible samples ...
      // failed to reach quorum" failure shape.
      TimeSample heteroSample(String id, int midOffsetMs, int halfMs) =>
          createSample(
            id: id,
            utc: baseTime.add(Duration(milliseconds: midOffsetMs)),
            uncertaintyMs: halfMs,
          );

      List<TimeSample> heteroPoolWithNts() => [
        heteroSample('nts:cf', 0, 15),
        heteroSample('ntp:goog', -50, 23),
        heteroSample('https:goog', -180, 87),
        heteroSample('ntp:pool', -120, 102),
        heteroSample('https:apple', -100, 134),
        heteroSample('https:msft', 50, 147),
        heteroSample('https:cf', 130, 149),
      ];

      test('witness: 7-sample heterogeneous pool with isolated narrow NTS '
          'refuses consensus (skj.1)', () {
        // requiredQuorum = ceil(7 * 0.6) = 5. Densest overlap region in
        // the HTTPS+NTP cluster contains 4 samples. NTS interval
        // [-15, 15] does not lie inside the cluster's overlap region,
        // so the NTS sample cannot raise the depth there. 4 < 5 -> null.
        final result = engine.resolve(heteroPoolWithNts());
        expect(
          result,
          isNull,
          reason:
              'Narrow NTS sample raises requiredQuorum from 4 to 5 '
              'but contributes 0 to cluster depth; quorum unreachable.',
        );
      });

      test('counterfactual: same pool with NTS removed reaches consensus', () {
        // requiredQuorum drops to ceil(6 * 0.6) = 4. Cluster overlap depth
        // of 4 now satisfies the threshold.
        final samples = heteroPoolWithNts()
          ..removeWhere((s) => s.sourceId == 'nts:cf');
        final result = engine.resolve(samples);
        expect(result, isNotNull);
        expect(result!.participantCount, 4);
      });

      test('mitigation 1: inflating NTS uncertainty to cluster scale (150ms) '
          'restores consensus', () {
        // The narrow NTS interval becomes wide enough to overlap the
        // cluster's densest region, raising depth there to 5 and
        // satisfying requiredQuorum without changing minQuorumRatio.
        final samples = heteroPoolWithNts();
        final ntsIndex = samples.indexWhere((s) => s.sourceId == 'nts:cf');
        expect(
          ntsIndex,
          isNonNegative,
          reason: 'heteroPoolWithNts must include the nts:cf sample',
        );
        samples[ntsIndex] = heteroSample('nts:cf', 0, 150);
        final result = engine.resolve(samples);
        expect(result, isNotNull);
        expect(result!.participantCount, 5);
      });

      test('mitigation 2: relaxing minQuorumRatio from 0.6 to 0.5 restores '
          'consensus on the same pool', () {
        // requiredQuorum = ceil(7 * 0.5) = 4. Cluster depth of 4 now
        // suffices without changing any sample's interval.
        const relaxed = MarzulloEngine(minQuorumRatio: 0.5);
        final result = relaxed.resolve(heteroPoolWithNts());
        expect(result, isNotNull);
        expect(result!.participantCount, 4);
      });
    });

    // Diagnostic harness for trusted_time-skj.3: confirms at unit level
    // that ConsensusResult.participantCount can be lower than
    // quorumDepth when the consensus window is wide and the sample
    // distribution is asymmetric. The bd's empirical signature: a
    // late-arriving sample widens the consensus window past where
    // some early-arriver midpoints sit, so those samples count toward
    // the sweep depth (and groupCount) without being counted as
    // midpoint-containing participants.
    group('trusted_time-skj.3 diagnostic: '
        'quorumDepth (sweep) vs participantCount (midpoint)', () {
      test('witness: asymmetric sample distribution makes quorumDepth '
          'exceed participantCount (skj.3)', () {
        // Construction (verified by hand-traced sweep):
        //   A = [-50, 50] (mid 0,   half 50, sample 'a')
        //   B = [-60,  0] (mid -30, half 30, sample 'b')
        //   C = [ -5, 31] (mid 13,  half 18, sample 'c')
        //
        // Sweep produces bestStart=-5, bestEnd=31 because all three
        // samples are active at t=-5 (densest point). bestUniqueOverlap
        // = 3 there. After end-of-window detection at t=31, the
        // post-sweep window-rebuild step in MarzulloEngine.resolve
        // (the loop that re-populates `bestSamples` with every sample
        // overlapping [bestStart, bestEnd]) re-includes all three
        // because each interval overlaps [-5, 31]. midpoint=(-5+31)
        // ~/ 2 = 13. Sample B's interval [-60, 0] does NOT contain
        // midpoint 13, so participantCount drops to 2 even though
        // quorumDepth stays at 3.
        final result = engine.resolve([
          createSample(id: 'a', utc: baseTime, uncertaintyMs: 50),
          createSample(
            id: 'b',
            utc: baseTime.subtract(const Duration(milliseconds: 30)),
            uncertaintyMs: 30,
          ),
          createSample(
            id: 'c',
            utc: baseTime.add(const Duration(milliseconds: 13)),
            uncertaintyMs: 18,
          ),
        ]);

        expect(result, isNotNull);
        expect(
          result!.quorumDepth,
          3,
          reason:
              'All three samples are active at the densest sweep '
              'point (t=-5), so bestUniqueOverlap = 3.',
        );
        expect(
          result.participantCount,
          2,
          reason:
              'Sample b\'s interval [-60, 0] does not contain the '
              'consensus midpoint 13, so it is excluded from the '
              'midpoint-containment count.',
        );
        expect(result.groupCount, 3);
        expect(
          result.quorumDepth,
          greaterThan(result.participantCount),
          reason:
              'This is the skj.3 divergence the field is meant to '
              'expose; if the assertion ever fails, either the '
              'remediation has been undone or the algorithm has been '
              'changed in a way that collapses the two metrics.',
        );
      });

      test(
        'invariant: quorumDepth >= participantCount across symmetric pool',
        () {
          // Sanity rail: in a symmetric pool where every sample contains
          // the midpoint, the two counts coincide. The >= relation must
          // still hold and the engine must not over-count quorumDepth.
          final result = engine.resolve([
            createSample(id: 'a', utc: baseTime, uncertaintyMs: 100),
            createSample(id: 'b', utc: baseTime, uncertaintyMs: 100),
            createSample(id: 'c', utc: baseTime, uncertaintyMs: 100),
          ]);

          expect(result, isNotNull);
          expect(result!.quorumDepth, equals(result.participantCount));
          expect(result.quorumDepth, 3);
        },
      );
    });
  });
}
