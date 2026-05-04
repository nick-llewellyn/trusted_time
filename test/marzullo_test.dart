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
      // to a zero-width consensus interval. The 1 ms floor prevents
      // downstream divide-by-zero and honestly signals best-case precision.
      final result = engine.resolve([
        SourceSample(sourceId: 'a', utc: baseTime, roundTripMs: 0),
        SourceSample(sourceId: 'b', utc: baseTime, roundTripMs: 0),
      ]);

      expect(result, isNotNull);
      expect(result!.uncertaintyMs, 1);
    });
  });
}
