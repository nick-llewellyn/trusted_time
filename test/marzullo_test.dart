import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_interval.dart';

void main() {
  group('MarzulloEngine', () {
    const engine = MarzulloEngine(minQuorumRatio: 0.6);
    final baseTime = DateTime.utc(2024, 6, 15, 12, 0, 0);
    final baseMs = baseTime.millisecondsSinceEpoch;

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

    test('returns null when fewer samples than quorum', () {
      final result = engine.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 10),
      ]);
      expect(result, isNull);
    });

    test('returns null for empty sample list', () {
      expect(engine.resolve([]), isNull);
    });

    test('resolves consensus from two agreeing sources', () {
      final result = engine.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 10),
        createSample(
          id: 'b',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          uncertaintyMs: 15,
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.participantCount, 2);
      final diffMs = (result.utc.millisecondsSinceEpoch - baseMs).abs();
      expect(diffMs, lessThan(50));
    });

    test('resolves consensus from three sources with one outlier', () {
      final result = engine.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 10),
        createSample(
          id: 'b',
          utc: baseTime.add(const Duration(milliseconds: 3)),
          uncertaintyMs: 10,
        ),
        createSample(
          id: 'outlier',
          utc: baseTime.add(const Duration(seconds: 60)),
          uncertaintyMs: 10,
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.participantCount, 2); // Outlier excluded from quorum
      final diffFromBase = (result.utc.millisecondsSinceEpoch - baseMs).abs();
      expect(diffFromBase, lessThan(100));
    });

    test('uncertainty reflects intersection width', () {
      final result = engine.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 50),
        createSample(id: 'b', utc: baseTime, uncertaintyMs: 50),
      ]);

      expect(result, isNotNull);
      expect(result!.uncertaintyMs, greaterThanOrEqualTo(1));
      expect(result.uncertaintyMs, lessThanOrEqualTo(50));
    });

    test('returns null when sources are too far apart for quorum', () {
      final result = engine.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 5),
        createSample(
          id: 'b',
          utc: baseTime.add(const Duration(seconds: 120)),
          uncertaintyMs: 5,
        ),
      ]);

      expect(result, isNull);
    });

    group('Tie-breaking at equal timestamps', () {
      test('touching intervals (upper == lower) count as overlap', () {
        final left = baseMs - 10;
        final right = baseMs + 10;

        final result = engine.resolve([
          TimeSample(
            sourceId: 'a',
            groupId: 'a',
            interval: TimeInterval(startMs: left - 10, endMs: baseMs),
          ),
          TimeSample(
            sourceId: 'b',
            groupId: 'b',
            interval: TimeInterval(startMs: baseMs, endMs: right + 10),
          ),
        ]);

        if (result != null) {
          expect(result.utc.millisecondsSinceEpoch, equals(baseMs));
        }
      });
    });

    group('Diversity and Confidence', () {
      test('participantCount equals number of agreeing sources', () {
        final result = engine.resolve([
          createSample(id: 'a', utc: baseTime, uncertaintyMs: 50),
          createSample(id: 'b', utc: baseTime, uncertaintyMs: 50),
          createSample(id: 'c', utc: baseTime, uncertaintyMs: 50),
        ]);
        expect(result, isNotNull);
        expect(result!.participantCount, equals(3));
      });

      test('participantCount excludes outlier sources', () {
        final result = engine.resolve([
          createSample(id: 'a', utc: baseTime, uncertaintyMs: 10),
          createSample(id: 'b', utc: baseTime, uncertaintyMs: 10),
          createSample(
            id: 'outlier',
            utc: baseTime.add(const Duration(seconds: 60)),
            uncertaintyMs: 10,
          ),
        ]);
        expect(result, isNotNull);
        expect(result!.participantCount, equals(2));
      });
    });

    group('Uncertainty minimum floor', () {
      test('uncertaintyMs is at least 1 for minimal non-zero uncertainty', () {
        final result = engine.resolve([
          createSample(id: 'a', utc: baseTime, uncertaintyMs: 1),
          createSample(id: 'b', utc: baseTime, uncertaintyMs: 1),
        ]);
        expect(result, isNotNull);
        expect(result!.uncertaintyMs, greaterThanOrEqualTo(1));
      });

      // Touching intervals should produce at least 1ms uncertainty
      test('uncertaintyMs is at least 1 for touching intervals', () {
        final result = engine.resolve([
          TimeSample(
            sourceId: 'a',
            groupId: 'a',
            interval: TimeInterval(startMs: baseMs - 5, endMs: baseMs + 1),
          ),
          TimeSample(
            sourceId: 'b',
            groupId: 'b',
            interval: TimeInterval(startMs: baseMs, endMs: baseMs + 5),
          ),
        ]);
        expect(result, isNotNull);
        expect(result!.uncertaintyMs, greaterThanOrEqualTo(1));
      });
    });

    group('Unique source tracking', () {
      test('multiple samples from same source count as one participant', () {
        // Multiple samples from same source should count as one unique participant
        final result = engine.resolve([
          createSample(id: 'same', utc: baseTime, uncertaintyMs: 50),
          createSample(
            id: 'same',
            utc: baseTime.add(const Duration(milliseconds: 10)),
            uncertaintyMs: 50,
          ),
          createSample(id: 'other', utc: baseTime, uncertaintyMs: 50),
        ]);
        expect(result, isNotNull);
        // Should count 2 unique sources, not 3 samples
        expect(result!.participantCount, equals(2));
        expect(result.participants.length, equals(2));
      });

      test('sweep optimizes on unique sources not raw depth', () {
        // Window with more unique sources should win over window with fewer unique sources
        final result = engine.resolve([
          // Chatty source (same ID) with 3 overlapping samples
          createSample(
            id: 'chatty',
            utc: baseTime,
            uncertaintyMs: 100,
            groupId: 'group1',
          ),
          createSample(
            id: 'chatty',
            utc: baseTime.add(const Duration(milliseconds: 10)),
            uncertaintyMs: 100,
            groupId: 'group1',
          ),
          createSample(
            id: 'chatty',
            utc: baseTime.add(const Duration(milliseconds: 20)),
            uncertaintyMs: 100,
            groupId: 'group1',
          ),
          // Three different sources
          createSample(
            id: 'src1',
            utc: baseTime.add(const Duration(milliseconds: 50)),
            uncertaintyMs: 50,
            groupId: 'group2',
          ),
          createSample(
            id: 'src2',
            utc: baseTime.add(const Duration(milliseconds: 50)),
            uncertaintyMs: 50,
            groupId: 'group3',
          ),
          createSample(
            id: 'src3',
            utc: baseTime.add(const Duration(milliseconds: 50)),
            uncertaintyMs: 50,
            groupId: 'group4',
          ),
        ]);
        expect(result, isNotNull);
        // Should find the window with 3 unique sources, not 1 chatty source
        expect(result!.participantCount, greaterThanOrEqualTo(3));
        expect(result.groupCount, greaterThanOrEqualTo(3));
      });
    });

    group('Participants set', () {
      test('participants set contains only samples overlapping midpoint', () {
        final result = engine.resolve([
          createSample(id: 'a', utc: baseTime, uncertaintyMs: 50),
          createSample(id: 'b', utc: baseTime, uncertaintyMs: 50),
          createSample(
            id: 'c',
            utc: baseTime.add(const Duration(seconds: 60)),
            uncertaintyMs: 50,
          ),
        ]);
        expect(result, isNotNull);
        // Outlier should not be in participants
        expect(result!.participants.length, equals(2));
        expect(
          result.participants.map((s) => s.sourceId).contains('c'),
          isFalse,
        );
      });

      test('participants set uses object identity not source ID', () {
        // Two different sample objects from same source, plus another source
        final sample1 = createSample(
          id: 'same',
          utc: baseTime,
          uncertaintyMs: 50,
        );
        final sample2 = createSample(
          id: 'same',
          utc: baseTime.add(const Duration(milliseconds: 10)),
          uncertaintyMs: 50,
        );
        final sample3 = createSample(
          id: 'other',
          utc: baseTime,
          uncertaintyMs: 50,
        );
        final result = engine.resolve([sample1, sample2, sample3]);
        if (result == null) {
          fail('Expected non-null result');
        }
        // Should have 2 participants (one per unique source)
        expect(result.participants.length, equals(2));
      });
    });

    test('clamping maxAllowedUncertaintyMs prevents bloated intervals', () {
      const engineClamped = MarzulloEngine(
        minQuorumRatio: 0.6,
        maxAllowedUncertaintyMs: 100,
      );
      final result = engineClamped.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 5000),
        createSample(id: 'b', utc: baseTime, uncertaintyMs: 5000),
      ]);
      // Should be null because both samples exceed maxAllowedUncertaintyMs
      expect(result, isNull);
    });

    /// Regressions for trusted_time-02x.
    ///
    /// The Marzullo half-width was previously computed via truncating
    /// integer division: `uncertaintyMs = (bestEnd - bestStart) ~/ 2`.
    /// When the consensus window `[bestStart, bestEnd]` has odd width
    /// the published interval `[midMs - uncertaintyMs, midMs + uncertaintyMs]`
    /// missed the truncation residual on one side of the engine's
    /// own `result.interval`. The fix ceiling-divides the width:
    /// `uncertaintyMs = ((bestEnd - bestStart) + 1) ~/ 2`, so the
    /// published symmetric `±U` interval always covers the engine's
    /// reported `interval` regardless of width parity.
    ///
    /// These tests construct `TimeSample`s with explicit `TimeInterval`
    /// endpoints (bypassing the symmetric `±uncertaintyMs` helper) so
    /// that the engine's consensus window has an odd width — a case
    /// the helper cannot otherwise produce.
    group('Anchor uncertainty covers engine consensus interval', () {
      TimeSample directSample({
        required String id,
        required int startMs,
        required int endMs,
        String? groupId,
      }) {
        return TimeSample(
          sourceId: id,
          groupId: groupId ?? id,
          interval: TimeInterval(startMs: startMs, endMs: endMs),
        );
      }

      test('odd-width window: published [mid-U, mid+U] covers the engine '
          'consensus interval (regression)', () {
        // A: [baseMs+100, baseMs+105]
        // B: [baseMs+102, baseMs+107]
        // Engine produces consensus window [baseMs+102, baseMs+107] —
        // width 5 (odd). midMs = baseMs+104.
        //
        // Pre-fix: uncertaintyMs = 5 ~/ 2 = 2. Published
        // [baseMs+102, baseMs+106] — missing baseMs+107 at the top.
        // Post-fix: uncertaintyMs = (5 + 1) ~/ 2 = 3. Published
        // [baseMs+101, baseMs+107] — covers the engine's window.
        final result = engine.resolve([
          directSample(id: 'a', startMs: baseMs + 100, endMs: baseMs + 105),
          directSample(id: 'b', startMs: baseMs + 102, endMs: baseMs + 107),
        ]);

        expect(result, isNotNull);
        expect(result!.interval, isNotNull);
        final mid = result.utc.millisecondsSinceEpoch;
        final publishedLower = mid - result.uncertaintyMs;
        final publishedUpper = mid + result.uncertaintyMs;

        expect(publishedLower, lessThanOrEqualTo(result.interval!.startMs));
        expect(publishedUpper, greaterThanOrEqualTo(result.interval!.endMs));
        // Pin the post-fix value so a regression on either direction
        // (truncating again, or over-widening) is caught.
        expect(result.uncertaintyMs, 3);
      });

      test('even-width window: behaviour unchanged across the fix', () {
        // A: [baseMs+100, baseMs+106]
        // B: [baseMs+102, baseMs+108]
        // Engine produces consensus window [baseMs+102, baseMs+108] —
        // width 6 (even). Both pre-fix and post-fix:
        // uncertaintyMs = 6 ~/ 2 = 3. midMs = baseMs+105.
        // Published [baseMs+102, baseMs+108] matches exactly.
        final result = engine.resolve([
          directSample(id: 'a', startMs: baseMs + 100, endMs: baseMs + 106),
          directSample(id: 'b', startMs: baseMs + 102, endMs: baseMs + 108),
        ]);

        expect(result, isNotNull);
        expect(result!.utc.millisecondsSinceEpoch, baseMs + 105);
        expect(result.uncertaintyMs, 3);
        expect(result.interval?.startMs, baseMs + 102);
        expect(result.interval?.endMs, baseMs + 108);
      });

      test('odd-width with overlapping uppers preserves the 1 ms floor', () {
        // A: [baseMs+100, baseMs+102]
        // B: [baseMs+101, baseMs+102]
        // Engine produces consensus window [baseMs+101, baseMs+102] —
        // width 1 (odd, minimum non-zero).
        // Pre-fix: uncertaintyMs = 1 ~/ 2 = 0, then max(1, 0) = 1.
        // Post-fix: uncertaintyMs = (1 + 1) ~/ 2 = 1.
        // Same value — floor preserved as the tight lower bound.
        final result = engine.resolve([
          directSample(id: 'a', startMs: baseMs + 100, endMs: baseMs + 102),
          directSample(id: 'b', startMs: baseMs + 101, endMs: baseMs + 102),
        ]);

        expect(result, isNotNull);
        expect(result!.uncertaintyMs, 1);
      });
    });

    /// Regression for trusted_time-2vl.
    ///
    /// The endpoint sort comparator must satisfy Dart's `Comparator`
    /// contract: `compare(a, b) == 0` when `a` and `b` are equal under
    /// the ordering. Two endpoints sharing both `timeMs` and `type` are
    /// equal under the marzullo ordering (interchanging them does not
    /// change the sweep result), so the comparator must return 0.
    ///
    /// Resolves consensus from three sources whose endpoints share
    /// timestamps with peers of the same type. Behaviour is unchanged
    /// from before the contract repair (consensus midpoint and
    /// uncertainty are identical); the assertion is that the engine
    /// returns a coherent ConsensusResult rather than relying on
    /// TimSort's tolerance for broken comparators.
    test('endpoint sort returns 0 for two same-type same-time endpoints '
        '(Comparator contract)', () {
      // Three sources with identical intervals — every endpoint
      // collides with two peers of the same type at the same time.
      final result = engine.resolve([
        createSample(id: 'a', utc: baseTime, uncertaintyMs: 100),
        createSample(id: 'b', utc: baseTime, uncertaintyMs: 100),
        createSample(id: 'c', utc: baseTime, uncertaintyMs: 100),
      ]);

      expect(result, isNotNull);
      expect(result!.utc.millisecondsSinceEpoch, baseMs);
      expect(result.uncertaintyMs, 100);
      expect(result.participantCount, 3);
      // Sample-identity preserved across the sort.
      expect(result.participants, hasLength(3));
    });

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
  });
}
