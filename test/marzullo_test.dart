import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_nts/src/marzullo.dart';

void main() {
  group('MarzulloEngine', () {
    const engine = MarzulloEngine(minimumQuorum: 2);
    final baseTime = DateTime.utc(2024, 6, 15, 12, 0, 0);
    final baseMs = baseTime.millisecondsSinceEpoch;

    test('returns null when fewer samples than quorum', () {
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
      ]);
      expect(result, isNull);
    });

    test('returns null for empty sample list', () {
      expect(engine.resolve([]), isNull);
    });

    test('resolves consensus from two agreeing sources', () {
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: 30,
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.participantCount, 2);
      final diffMs = (result.utc.millisecondsSinceEpoch - baseMs).abs();
      expect(diffMs, lessThan(50));
    });

    test('resolves consensus from three sources with one outlier', () {
      final engine3 = MarzulloEngine(minimumQuorum: 2);
      final result = engine3.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(milliseconds: 3)),
          roundTripMs: 20,
        ),
        SourceSample(
          sourceId: 'outlier',
          utc: baseTime.add(const Duration(seconds: 60)),
          roundTripMs: 20,
        ),
      ]);

      expect(result, isNotNull);
      final diffFromBase = (result!.utc.millisecondsSinceEpoch - baseMs).abs();
      expect(diffFromBase, lessThan(100));
    });

    test('uncertainty reflects intersection width', () {
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 100),
        SourceSample(sourceId: 'b', utc: baseTime, roundTripMs: 100),
      ]);

      expect(result, isNotNull);
      expect(result!.uncertaintyMs, greaterThanOrEqualTo(0));
      expect(result.uncertaintyMs, lessThanOrEqualTo(100));
    });

    test('returns null when sources are too far apart for quorum', () {
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 10),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(seconds: 120)),
          roundTripMs: 10,
        ),
      ]);

      expect(result, isNull);
    });

    test('closed-interval semantics: touching intervals share endpoint', () {
      // A=[base-10, base+10] (centre base, ±10 ms) and B=[base+10, base+30]
      // (centre base+20, ±10 ms) touch at exactly base+10. Closed-interval
      // semantics requires depth=2 at that point, so consensus is the
      // zero-width interval anchored at the touch.
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
        SourceSample(
          sourceId: 'b',
          utc: DateTime.fromMillisecondsSinceEpoch(baseMs + 20, isUtc: true),
          roundTripMs: 20,
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.participantCount, 2);
      // Midpoint of the zero-width consensus window sits exactly on the
      // shared endpoint.
      expect(result.utc.millisecondsSinceEpoch, baseMs + 10);
      // Zero-width raw interval is floored to 1 ms by the engine.
      expect(result.uncertaintyMs, 1);
    });

    test('participantCount reports unique source IDs, not overlap depth', () {
      // Two samples from the same source overlap heavily. The raw overlap
      // depth at the intersection is 2, but only one authority is present.
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 2)),
          roundTripMs: 20,
        ),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(milliseconds: 1)),
          roundTripMs: 20,
        ),
      ]);

      expect(result, isNotNull);
      // Three samples overlap at the centre but only two unique sources.
      expect(result!.participantCount, 2);
    });

    test('uncertainty is floored at 1 ms when intervals coincide exactly', () {
      // Two samples with identical centres and identical roundTrips collapse
      // to a zero-width consensus interval. `TrustAnchor.uncertaintyMs` is
      // public and consumers reason about confidence bounds against it; a
      // reported `\u00b10 ms` would falsely advertise sub-millisecond consensus
      // precision below any real clock's read jitter, so the engine floors
      // the published value at 1 ms.
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 0),
        SourceSample(sourceId: 'b', utc: baseTime, roundTripMs: 0),
      ]);

      expect(result, isNotNull);
      expect(result!.uncertaintyMs, 1);
    });

    test('participantCount tracks source multiplicity across reopened '
        'intervals', () {
      // Source `a` contributes two intervals; a1 closes well before a2
      // does, but `a` is still active at the moment a new maximum
      // overlap is reached. A naive Set<String> would drop `a` when a1
      // closes (because Set has no notion of multiplicity), causing the
      // snapshot at the best moment to under-count distinct sources.
      //   a1: centre base+2  ms, rtt  4 ms -> [base+0,  base+4 ]
      //   a2: centre base+11 ms, rtt 16 ms -> [base+3,  base+19]
      //   b : centre base+11 ms, rtt  8 ms -> [base+7,  base+15]
      //   c : centre base+9  ms, rtt  2 ms -> [base+8,  base+10]
      // New best=3 at base+8 with three unique sources truly active.
      final result = engine.resolve([
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 2)),
          roundTripMs: 4,
        ),
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 11)),
          roundTripMs: 16,
        ),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(milliseconds: 11)),
          roundTripMs: 8,
        ),
        SourceSample(
          sourceId: 'c',
          utc: baseTime.add(const Duration(milliseconds: 9)),
          roundTripMs: 2,
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.participantCount, 3);
      // Best window is [base+8, base+10]; midpoint at base+9.
      expect(result.utc.millisecondsSinceEpoch, baseMs + 9);
    });

    test('chatty source does not mask later window with more unique '
        'authorities', () {
      // Three samples from `a` plus one from `b` create a window of raw
      // depth 4 but only 2 unique authorities. A later, fully disjoint
      // window of three distinct sources `c`, `d`, `e` has raw depth 3
      // and 3 unique authorities. With quorum=3, the second window is
      // the only valid consensus. A sweep that optimises on raw depth
      // would lock in the first window and the post-sweep gate would
      // reject the result entirely (returning null), even though a
      // valid consensus exists.
      //   a1: centre base+5  ms, rtt 10 ms -> [base+0,  base+10]
      //   a2: centre base+5  ms, rtt  8 ms -> [base+1,  base+9 ]
      //   a3: centre base+5  ms, rtt  6 ms -> [base+2,  base+8 ]
      //   b : centre base+5  ms, rtt  4 ms -> [base+3,  base+7 ]
      //   c : centre base+25 ms, rtt 10 ms -> [base+20, base+30]
      //   d : centre base+25 ms, rtt  8 ms -> [base+21, base+29]
      //   e : centre base+25 ms, rtt  6 ms -> [base+22, base+28]
      const engine3 = MarzulloEngine(minimumQuorum: 3);
      final result = engine3.resolve([
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: 10,
        ),
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: 8,
        ),
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: 6,
        ),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: 4,
        ),
        SourceSample(
          sourceId: 'c',
          utc: baseTime.add(const Duration(milliseconds: 25)),
          roundTripMs: 10,
        ),
        SourceSample(
          sourceId: 'd',
          utc: baseTime.add(const Duration(milliseconds: 25)),
          roundTripMs: 8,
        ),
        SourceSample(
          sourceId: 'e',
          utc: baseTime.add(const Duration(milliseconds: 25)),
          roundTripMs: 6,
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.participantCount, 3);
      // Best window is [base+22, base+28]; midpoint at base+25.
      expect(result.utc.millisecondsSinceEpoch, baseMs + 25);
    });

    test('returns null when raw overlap meets quorum but unique sources '
        'do not', () {
      // Two samples from the same `sourceId` overlap. Raw overlap depth
      // at the intersection is 2 and matches minimumQuorum=2, but only
      // one authority is present. The quorum contract names distinct
      // sources, so this must return null even though the old
      // depth-only gate would have admitted it.
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
        SourceSample(
          sourceId: 'a',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: 20,
        ),
      ]);

      expect(result, isNull);
    });

    test('rejects samples with negative roundTripMs without throwing', () {
      // A custom TrustedTimeSource that violates the non-negative
      // roundTripMs contract would otherwise produce an inverted
      // interval (upper endpoint < lower endpoint), causing the
      // multiset sweep to look up an unseen id and throw on the
      // null-asserted map access. The malformed sample must instead
      // be treated as absent so quorum can fail cleanly.
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
        SourceSample(
          sourceId: 'b',
          utc: baseTime.add(const Duration(milliseconds: 5)),
          roundTripMs: -100,
        ),
      ]);

      // Only one valid sample remains; quorum=2 fails cleanly.
      expect(result, isNull);
    });

    test(
      'ignores negative-RTT samples but still resolves on remaining valid ones',
      () {
        final result = engine.resolve([
          SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 20),
          SourceSample(
            sourceId: 'b',
            utc: baseTime.add(const Duration(milliseconds: 5)),
            roundTripMs: 30,
          ),
          SourceSample(sourceId: 'c', utc: baseTime, roundTripMs: -50),
        ]);

        expect(result, isNotNull);
        expect(result!.participantCount, 2);
      },
    );
  });
}
