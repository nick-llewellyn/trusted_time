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
      // Symmetric case: both samples contain the midpoint, so the
      // strict midpoint-containment count equals the sweep depth.
      expect(result.quorumDepth, equals(result.participantCount));
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

    /// Regressions for trusted_time-02x, updated for trusted_time-pnf.
    ///
    /// The published symmetric `±uncertaintyMs` envelope must always
    /// cover the engine's own consensus `interval` (`[bestStart, bestEnd]`),
    /// so a consumer reading `utc ± uncertaintyMs` never gets an interval
    /// narrower than the Marzullo intersection on either side.
    ///
    /// Under pnf the published centre [utc] is the root-distance-weighted
    /// estimate, which can sit off the geometric midpoint of the window.
    /// `uncertaintyMs` is therefore the larger distance from [utc] to
    /// either window edge (`max(utc - bestStart, bestEnd - utc)`); this
    /// preserves coverage across both width parity and an off-centre
    /// weighted estimate, and reduces to the old ceiling half-width when
    /// the estimate lands on the geometric centre.
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

      test('odd-width window: published [utc-U, utc+U] covers the engine '
          'consensus interval (regression)', () {
        // A: [baseMs+100, baseMs+105] (mid +102), B: [baseMs+102, baseMs+107]
        // (mid +104). Engine consensus window [baseMs+102, baseMs+107] —
        // width 5 (odd); geometric centre +104. Both samples are best-tier
        // with equal root distance, so the weighted centre is the mean of
        // the sample midpoints: utc = baseMs+103.
        //
        // uncertaintyMs = max(103-102, 107-103) = 4, so the published
        // envelope [baseMs+99, baseMs+107] covers the engine's window.
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
        // Pin the coverage-preserving half-width so a regression in either
        // direction (under-covering, or over-widening) is caught.
        expect(result.uncertaintyMs, 4);
      });

      test('even-width window: weighted centre and coverage half-width', () {
        // A: [baseMs+100, baseMs+106] (mid +103), B: [baseMs+102, baseMs+108]
        // (mid +105). Engine consensus window [baseMs+102, baseMs+108] —
        // width 6 (even); geometric centre +105. Equal-root-distance
        // best-tier samples, so the weighted centre is the mean of the
        // sample midpoints: utc = baseMs+104.
        // uncertaintyMs = max(104-102, 108-104) = 4; published envelope
        // [baseMs+100, baseMs+108] covers the window.
        final result = engine.resolve([
          directSample(id: 'a', startMs: baseMs + 100, endMs: baseMs + 106),
          directSample(id: 'b', startMs: baseMs + 102, endMs: baseMs + 108),
        ]);

        expect(result, isNotNull);
        expect(result!.utc.millisecondsSinceEpoch, baseMs + 104);
        expect(result.uncertaintyMs, 4);
        expect(result.interval?.startMs, baseMs + 102);
        expect(result.interval?.endMs, baseMs + 108);
      });

      test('odd-width with overlapping uppers preserves the 1 ms floor', () {
        // A: [baseMs+100, baseMs+102] (mid +101), B: [baseMs+101, baseMs+102]
        // (mid +101). Engine consensus window [baseMs+101, baseMs+102] —
        // width 1 (odd, minimum non-zero). Weighted centre utc = baseMs+101.
        // uncertaintyMs = max(101-101, 102-101) = 1, which also meets the
        // 1 ms minimum floor — the tight lower bound is preserved.
        final result = engine.resolve([
          directSample(id: 'a', startMs: baseMs + 100, endMs: baseMs + 102),
          directSample(id: 'b', startMs: baseMs + 101, endMs: baseMs + 102),
        ]);

        expect(result, isNotNull);
        expect(result!.uncertaintyMs, 1);
      });
    });

    /// trusted_time-pnf: the published centre is the root-distance-weighted
    /// estimate over the survivors, not the geometric midpoint of the
    /// consensus window. A survivor with a tighter RTT (smaller delayMs →
    /// lower root distance) pulls the centre toward its own midpoint, while
    /// the symmetric envelope is widened so it still covers the window.
    group('Root-distance-weighted combine (pnf)', () {
      test('weighted centre is pulled toward the low-root-distance cluster '
          'and the envelope still covers the window', () {
        // A, B: wide intervals (half 20) centred at baseMs, but tight RTT
        //   (delayMs 4 → root distance 2).
        // C: overlapping interval centred at baseMs+30 with a large RTT
        //   (delayMs 200 → root distance 100).
        // Sweep window is [baseMs, baseMs+20]; geometric centre baseMs+10.
        // A/B dominate the weighted average (weight ~1/2 each) over C
        // (weight ~1/100), so the centre is pulled to the A/B cluster at 0.
        final result = engine.resolve([
          TimeSample(
            sourceId: 'a',
            groupId: 'a',
            interval: TimeInterval(startMs: baseMs - 20, endMs: baseMs + 20),
            delayMs: 4,
          ),
          TimeSample(
            sourceId: 'b',
            groupId: 'b',
            interval: TimeInterval(startMs: baseMs - 20, endMs: baseMs + 20),
            delayMs: 4,
          ),
          TimeSample(
            sourceId: 'c',
            groupId: 'c',
            interval: TimeInterval(startMs: baseMs, endMs: baseMs + 60),
            delayMs: 200,
          ),
        ]);

        expect(result, isNotNull);
        final centre = result!.utc.millisecondsSinceEpoch - baseMs;
        // Strictly below the geometric centre (+10), hugging the tight
        // A/B cluster near 0.
        expect(centre, lessThan(10));
        expect(centre, inInclusiveRange(0, 3));

        // Coverage invariant holds even with the off-centre estimate.
        expect(result.interval, isNotNull);
        final lo = result.utc.millisecondsSinceEpoch - result.uncertaintyMs;
        final hi = result.utc.millisecondsSinceEpoch + result.uncertaintyMs;
        expect(lo, lessThanOrEqualTo(result.interval!.startMs));
        expect(hi, greaterThanOrEqualTo(result.interval!.endMs));
      });

      test('symmetric equal-root-distance survivors keep the geometric '
          'centre', () {
        // Two equal-width samples symmetric about baseMs with equal root
        // distance: the weighted centre coincides with the geometric
        // midpoint, so the combine is a no-op for the balanced case.
        final result = engine.resolve([
          createSample(
            id: 'a',
            utc: baseTime.subtract(const Duration(milliseconds: 10)),
            uncertaintyMs: 20,
          ),
          createSample(
            id: 'b',
            utc: baseTime.add(const Duration(milliseconds: 10)),
            uncertaintyMs: 20,
          ),
        ]);

        expect(result, isNotNull);
        expect(result!.utc.millisecondsSinceEpoch, baseMs);
      });

      test('a chatty source gets a single vote in the weighted centre', () {
        // One vote per source: source "b" emits five identical samples but
        // must not out-vote source "a" in the weighted combine — the sweep
        // already counts "b" once for quorum/participants, so the published
        // centre must treat it as one survivor too.
        //
        // a: midpoint baseMs-30, half-width 100 (root distance 100).
        // b (x5): midpoint baseMs+30, half-width 100 (root distance 100).
        // Equal root distance + tier, so per-source the weighted centre is
        // the geometric midpoint baseMs. Without dedup, b's five votes drag
        // the centre to (-30 + 5*30) / 6 = +20.
        //
        // requiredQuorum derives from distinct responders, so the ratio
        // applies at the default: two sources need a quorum of two, which
        // a and b satisfy. This used to need a lowered ratio to pass,
        // because the denominator counted samples while the overlap it was
        // compared against counted sources — so b's repetition raised a bar
        // it could not help clear.
        const chattyEngine = MarzulloEngine();
        final result = chattyEngine.resolve([
          createSample(
            id: 'a',
            utc: baseTime.subtract(const Duration(milliseconds: 30)),
            uncertaintyMs: 100,
          ),
          for (var i = 0; i < 5; i++)
            createSample(
              id: 'b',
              utc: baseTime.add(const Duration(milliseconds: 30)),
              uncertaintyMs: 100,
            ),
        ]);

        expect(result, isNotNull);
        // Chatty "b" counted once: centre stays at the geometric midpoint,
        // well clear of the +20 a non-deduped combine would produce.
        final centre = result!.utc.millisecondsSinceEpoch - baseMs;
        expect(centre, inInclusiveRange(-2, 2));
        expect(centre, lessThan(10));
        // And it is one unique participant, not five.
        expect(result.participantCount, 2);
        expect(result.quorumDepth, 2);
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
  });
}
