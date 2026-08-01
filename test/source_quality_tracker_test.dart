import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/source_quality_tracker.dart';

void main() {
  group('SourceQualityTracker', () {
    late SourceQualityTracker tracker;

    setUp(() => tracker = SourceQualityTracker());

    test('ranked returns all provided source IDs', () {
      final ids = ['a', 'b', 'c'];
      final result = tracker.ranked(ids);
      expect(result, unorderedEquals(ids));
    });

    test('ranked deduplicates colliding source IDs', () {
      // A caller passing the same id more than once (e.g. two sources
      // sharing an id) must not cause that id to be ranked — and so
      // queried — twice in a single cycle.
      final ranked = tracker.ranked(['a', 'b', 'a', 'b', 'a']);
      expect(ranked, unorderedEquals(['a', 'b']));
      expect(ranked.length, equals(2));
    });

    test('higher consensus participation ranks higher', () {
      // 'good' participates in consensus every cycle; 'bad' never does.
      for (var i = 0; i < 8; i++) {
        tracker.record(
          sourceId: 'good',
          uncertaintyMs: 100,
          participatedInConsensus: true,
        );
        tracker.record(
          sourceId: 'bad',
          uncertaintyMs: 100,
          participatedInConsensus: false,
        );
        tracker.advanceCycle();
      }

      final ranked = tracker.ranked(['good', 'bad']);
      expect(ranked.first, equals('good'));
    });

    test('lower uncertainty ranks higher when participation is equal', () {
      for (var i = 0; i < 8; i++) {
        tracker.record(
          sourceId: 'fast',
          uncertaintyMs: 20,
          participatedInConsensus: true,
        );
        tracker.record(
          sourceId: 'slow',
          uncertaintyMs: 500,
          participatedInConsensus: true,
        );
        tracker.advanceCycle();
      }

      final ranked = tracker.ranked(['fast', 'slow']);
      expect(ranked.first, equals('fast'));
    });

    test('lower NTP stratum ranks higher', () {
      for (var i = 0; i < 8; i++) {
        tracker.record(
          sourceId: 'tier1',
          uncertaintyMs: 100,
          participatedInConsensus: true,
        );
        tracker.record(
          sourceId: 'tier3',
          uncertaintyMs: 100,
          participatedInConsensus: true,
        );
        tracker.advanceCycle();
      }
      tracker.setStratum('tier1', 1);
      tracker.setStratum('tier3', 3);

      final ranked = tracker.ranked(['tier1', 'tier3']);
      expect(ranked.first, equals('tier1'));
    });

    group('Starvation guard', () {
      test('newly seen source is considered starved', () {
        expect(tracker.isStarved('never_queried'), isTrue);
      });

      test('recently queried source is not starved', () {
        tracker.record(
          sourceId: 'fresh',
          uncertaintyMs: 50,
          participatedInConsensus: true,
        );
        expect(tracker.isStarved('fresh'), isFalse);
      });

      test(
        'source becomes starved after _kStarvationCycles without a query',
        () {
          tracker.record(
            sourceId: 'stale',
            uncertaintyMs: 50,
            participatedInConsensus: true,
          );
          // Advance 5 cycles without recording the source again.
          for (var i = 0; i < 5; i++) {
            tracker.advanceCycle();
          }
          expect(tracker.isStarved('stale'), isTrue);
        },
      );

      test('failure resets starvation clock', () {
        tracker.record(
          sourceId: 'src',
          uncertaintyMs: 50,
          participatedInConsensus: false,
        );
        for (var i = 0; i < 3; i++) {
          tracker.advanceCycle();
        }
        tracker.recordFailure('src');
        expect(tracker.isStarved('src'), isFalse);
      });
    });

    test('ranked does not duplicate starvation-forced sources', () {
      // All sources are known (not starved). ranked() should return each
      // source exactly once.
      const ids = ['a', 'b', 'c'];
      for (final id in ids) {
        tracker.record(
          sourceId: id,
          uncertaintyMs: 50,
          participatedInConsensus: true,
        );
      }
      tracker.advanceCycle();

      final ranked = tracker.ranked(ids);
      expect(ranked.length, equals(ids.length));
      expect(ranked.toSet().length, equals(ids.length));
    });

    test('invalid stratum values are ignored', () {
      tracker.setStratum('a', 0); // Too low
      tracker.setStratum('b', 16); // Too high
      // Should not throw and should score neutrally.
      expect(() => tracker.ranked(['a', 'b']), returnsNormally);
    });

    group('durable stats', () {
      test('lower measured RTT ranks higher when other signals equal', () {
        for (var i = 0; i < 8; i++) {
          tracker.record(
            sourceId: 'near',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 20,
          );
          tracker.record(
            sourceId: 'far',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 900,
          );
          tracker.advanceCycle();
        }

        final ranked = tracker.ranked(['near', 'far']);
        expect(ranked.first, equals('near'));
      });

      test('lower burst jitter ranks higher when other signals equal', () {
        for (var i = 0; i < 8; i++) {
          tracker.record(
            sourceId: 'stable',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 100,
            jitterMs: 2,
          );
          tracker.record(
            sourceId: 'noisy',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 100,
            jitterMs: 400,
          );
          tracker.advanceCycle();
        }

        final ranked = tracker.ranked(['stable', 'noisy']);
        expect(ranked.first, equals('stable'));
      });

      test('failures decay ranking without permanently dropping a source', () {
        // Both sources start with identical successful history.
        for (var i = 0; i < 4; i++) {
          for (final id in ['flaky', 'solid']) {
            tracker.record(
              sourceId: id,
              uncertaintyMs: 100,
              participatedInConsensus: true,
              delayMs: 100,
            );
          }
          tracker.advanceCycle();
        }
        // 'flaky' then times out repeatedly.
        for (var i = 0; i < 4; i++) {
          tracker.recordFailure('flaky');
          tracker.record(
            sourceId: 'solid',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 100,
          );
          tracker.advanceCycle();
        }

        final ranked = tracker.ranked(['flaky', 'solid']);
        expect(ranked.first, equals('solid'));
        // Deferred, never dropped: the source is still ranked and a
        // success recovers its rate.
        expect(ranked, contains('flaky'));
        final before = tracker.snapshot()['flaky']!.successRate;
        tracker.record(
          sourceId: 'flaky',
          uncertaintyMs: 100,
          participatedInConsensus: true,
          delayMs: 100,
        );
        expect(tracker.snapshot()['flaky']!.successRate, greaterThan(before));
      });

      test('snapshot captures EWMA stats and restore seeds ranking', () {
        var wall = 1000000;
        final first = SourceQualityTracker(wallClock: () => wall);
        for (var i = 0; i < 8; i++) {
          first.record(
            sourceId: 'near',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 20,
            jitterMs: 3,
          );
          first.record(
            sourceId: 'far',
            uncertaintyMs: 100,
            participatedInConsensus: true,
            delayMs: 900,
            jitterMs: 3,
          );
          first.advanceCycle();
          wall += 1000;
        }
        first.setStratum('near', 2);

        final snap = first.snapshot();
        expect(snap['near']!.ewmaRttMs, closeTo(20, 1));
        expect(snap['near']!.ewmaJitterMs, closeTo(3, 1));
        expect(snap['near']!.successRate, equals(1.0));
        expect(snap['near']!.stratum, equals(2));

        // A fresh tracker (new process) seeded with the snapshot ranks
        // on the restored RTT despite having no observation history.
        final second = SourceQualityTracker(wallClock: () => wall)
          ..restore(snap);
        final ranked = second.ranked(['near', 'far']);
        expect(ranked.first, equals('near'));
      });

      test('restore discards stale entries', () {
        const monthMs = 30 * 24 * 60 * 60 * 1000;
        final now = DateTime.utc(2026, 7, 1).millisecondsSinceEpoch;
        final restored = SourceQualityTracker(wallClock: () => now)
          ..restore({
            'stale': SourceQualityStats(
              ewmaRttMs: 10,
              successRate: 1.0,
              lastProbedUtcMs: now - monthMs - 1,
            ),
            'fresh': SourceQualityStats(
              ewmaRttMs: 10,
              successRate: 1.0,
              lastProbedUtcMs: now - 1000,
            ),
          });
        final snap = restored.snapshot();
        expect(snap, contains('fresh'));
        expect(snap, isNot(contains('stale')));
      });

      test('restore clamps future-dated timestamps so they age out '
          'normally', () {
        // Recorded while the wall clock was a day ahead, then corrected:
        // unclamped, the entry would outrank genuinely recent sources in
        // snapshot() ordering and dodge the staleness cutoff forever.
        const dayMs = 24 * 60 * 60 * 1000;
        final now = DateTime.utc(2026, 7, 1).millisecondsSinceEpoch;
        final tracker = SourceQualityTracker(wallClock: () => now)
          ..restore({
            'future': SourceQualityStats(
              ewmaRttMs: 10,
              successRate: 1.0,
              lastProbedUtcMs: now + dayMs,
            ),
          });
        expect(tracker.snapshot()['future']!.lastProbedUtcMs, equals(now));
      });

      test('snapshot prunes to the most recently probed sources', () {
        var wall = 0;
        final busy = SourceQualityTracker(wallClock: () => wall);
        for (var i = 0; i < 40; i++) {
          wall = i;
          busy.record(
            sourceId: 'src$i',
            uncertaintyMs: 100,
            participatedInConsensus: true,
          );
        }
        final snap = busy.snapshot();
        expect(snap.length, equals(32));
        // The 8 oldest (src0..src7) are pruned; the newest survive.
        expect(snap, isNot(contains('src0')));
        expect(snap, contains('src39'));
      });
    });

    group('vantage staleness', () {
      /// Gives [id] a settled, high-quality history at [delayMs].
      void settle(SourceQualityTracker t, String id, int delayMs) {
        for (var i = 0; i < 8; i++) {
          t.record(
            sourceId: id,
            uncertaintyMs: 10,
            participatedInConsensus: true,
            delayMs: delayMs,
            jitterMs: 2,
          );
          t.advanceCycle();
        }
      }

      test('marking retains the metrics rather than deleting them', () {
        var wall = 1000;
        final t = SourceQualityTracker(wallClock: () => wall);
        settle(t, 'near', 20);
        wall = 2000;

        t.markVantageStale();

        final snap = t.snapshot();
        expect(snap['near']!.ewmaRttMs, closeTo(20, 1));
        expect(
          snap['near']!.lastProbedUtcMs,
          equals(1000),
          reason: 'the underlying timestamp still governs age-based pruning',
        );
      });

      test('a marked source rejoins the unprobed end of the walk', () {
        // partitionInventory reads lastProbedUtcMs and sorts null
        // first, so reporting null is what re-sweeps the inventory.
        final t = SourceQualityTracker(wallClock: () => 1000);
        settle(t, 'near', 20);
        expect(t.lastProbedUtcMs('near'), equals(1000));

        t.markVantageStale();
        expect(t.lastProbedUtcMs('near'), isNull);
      });

      test('stale data still breaks ties against a never-seen source', () {
        final t = SourceQualityTracker(wallClock: () => 1000);
        settle(t, 'near', 20);
        settle(t, 'far', 900);
        t.markVantageStale();

        expect(
          t.ranked(['far', 'unknown', 'near']),
          equals(['near', 'far', 'unknown']),
          reason: 'old metrics are wrong about the new vantage, not absent',
        );
      });

      test('a fresh measurement outranks a better stale one', () {
        final t = SourceQualityTracker(wallClock: () => 1000);
        settle(t, 'wasFast', 20);
        settle(t, 'wasSlow', 400);
        t.markVantageStale();

        // wasSlow is re-measured from the new vantage; wasFast is not.
        // The attenuation has to be strong enough that a 20 ms stale
        // reading cannot hold its lead over a 400 ms fresh one.
        t.recordProbe(sourceId: 'wasSlow', delayMs: 400, jitterMs: 2);

        expect(t.ranked(['wasFast', 'wasSlow']).first, equals('wasSlow'));
      });

      test('a probe clears the mark for that source alone', () {
        var wall = 1000;
        final t = SourceQualityTracker(wallClock: () => wall);
        settle(t, 'a', 20);
        settle(t, 'b', 20);
        t.markVantageStale();
        wall = 2000;

        t.recordProbe(sourceId: 'a', delayMs: 25);

        expect(t.isVantageStale('a'), isFalse);
        expect(t.lastProbedUtcMs('a'), equals(2000));
        expect(
          t.isVantageStale('b'),
          isTrue,
          reason: 'recovery is per source, as each is re-measured',
        );
      });

      test('a failed probe clears the mark too', () {
        // Otherwise an unreachable host stays null-cursored and is
        // re-offered at the head of the walk every cycle, crowding out
        // the re-exploration the vantage change asked for.
        final t = SourceQualityTracker(wallClock: () => 1000);
        settle(t, 'dead', 20);
        t.markVantageStale();

        t.recordFailure('dead');

        expect(t.isVantageStale('dead'), isFalse);
        expect(t.lastProbedUtcMs('dead'), equals(1000));
      });

      test('marking an empty tracker is a no-op', () {
        final t = SourceQualityTracker()..markVantageStale();
        expect(t.isVantageStale('never'), isFalse);
        expect(t.lastProbedUtcMs('never'), isNull);
        expect(t.ranked(['never']), equals(['never']));
      });

      test('a source first seen after the mark is not stale', () {
        final t = SourceQualityTracker(wallClock: () => 1000)
          ..markVantageStale();
        t.recordProbe(sourceId: 'new', delayMs: 20);
        expect(t.isVantageStale('new'), isFalse);
      });
    });

    group('SourceQualityStats JSON', () {
      test('round-trips all fields', () {
        const stats = SourceQualityStats(
          ewmaRttMs: 42.5,
          ewmaJitterMs: 3.25,
          successRate: 0.875,
          lastProbedUtcMs: 1700000000000,
          stratum: 2,
        );
        final decoded = SourceQualityStats.fromJson(stats.toJson());
        expect(decoded, isNotNull);
        expect(decoded!.ewmaRttMs, equals(42.5));
        expect(decoded.ewmaJitterMs, equals(3.25));
        expect(decoded.successRate, equals(0.875));
        expect(decoded.lastProbedUtcMs, equals(1700000000000));
        expect(decoded.stratum, equals(2));
      });

      test('round-trips with optional fields absent', () {
        const stats = SourceQualityStats(
          successRate: 1.0,
          lastProbedUtcMs: 1700000000000,
        );
        final json = stats.toJson();
        expect(json, isNot(contains('ewmaRttMs')));
        expect(json, isNot(contains('ewmaJitterMs')));
        expect(json, isNot(contains('stratum')));
        final decoded = SourceQualityStats.fromJson(json);
        expect(decoded, isNotNull);
        expect(decoded!.ewmaRttMs, isNull);
        expect(decoded.ewmaJitterMs, isNull);
        expect(decoded.stratum, isNull);
      });

      test('fromJson rejects malformed entries and sanitizes fields', () {
        expect(SourceQualityStats.fromJson(null), isNull);
        expect(SourceQualityStats.fromJson('nope'), isNull);
        expect(SourceQualityStats.fromJson(<String, dynamic>{}), isNull);
        expect(
          SourceQualityStats.fromJson({
            'successRate': 'high',
            'lastProbedUtcMs': 1,
          }),
          isNull,
        );
        final sanitized = SourceQualityStats.fromJson({
          'successRate': 7.0, // Out of range → clamped.
          'lastProbedUtcMs': 1,
          'ewmaRttMs': 'fast', // Wrong type → dropped.
          'stratum': 99, // Out of range → dropped.
        });
        expect(sanitized, isNotNull);
        expect(sanitized!.successRate, equals(1.0));
        expect(sanitized.ewmaRttMs, isNull);
        expect(sanitized.stratum, isNull);
      });
    });
  });
}
