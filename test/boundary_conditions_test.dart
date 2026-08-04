import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/trusted_time.dart';

/// Boundary-condition audit for the core interval arithmetic types
/// (bd trusted_time-q7s). These types underpin every Marzullo
/// reduction, so edge-case bugs here corrupt consensus silently
/// rather than crashing. Four cases are locked in:
///
/// 1. Zero-width interval (startMs == endMs) — legal, sensible math.
/// 2. Inverted interval (startMs > endMs) — rejected at construction
///    in ALL build modes (ArgumentError, not assert-only).
/// 3. Single-sample consensus — Marzullo on N=1 must refuse.
/// 4. Equality and hash semantics — TimeInterval is a value type;
///    TimeSample is intentionally identity-based.
void main() {
  group('TimeInterval zero-width', () {
    // A zero-width interval claims perfect precision. The type is a
    // CLOSED interval [startMs, endMs], both bounds inclusive, so
    // startMs == endMs denotes the single-point set {startMs} and
    // must be constructible and arithmetically sensible.
    test('is legal to construct', () {
      final zero = TimeInterval(startMs: 5000, endMs: 5000);
      expect(zero.startMs, 5000);
      expect(zero.endMs, 5000);
    });

    test('has zero width and midpoint at the point', () {
      final zero = TimeInterval(startMs: 5000, endMs: 5000);
      expect(zero.width, 0);
      expect(zero.midpoint, 5000);
    });

    test('yields zero uncertainty on a TimeSample', () {
      final sample = TimeSample(
        interval: TimeInterval(startMs: 5000, endMs: 5000),
        sourceId: 'nts:perfect.example',
        groupId: 'g',
      );
      expect(sample.uncertaintyMs, 0);
    });

    test('survives the Marzullo sweep without corrupting the count', () {
      // Regression guard: an upper-before-lower tie ordering at equal
      // timestamps would process a zero-width interval's own upper
      // endpoint before its lower, decrementing a source count that
      // was never incremented — a null-check crash. The sweep must
      // not blow up, and the zero-width source must count toward the
      // sweep depth.
      const engine = MarzulloEngine(minQuorumRatio: 0.6);
      const baseMs = 1700000000000;
      TimeSample wide(String id) => TimeSample(
        interval: TimeInterval(startMs: baseMs - 100, endMs: baseMs + 100),
        sourceId: id,
        groupId: id,
      );
      final zero = TimeSample(
        interval: TimeInterval(startMs: baseMs, endMs: baseMs),
        sourceId: 'zero',
        groupId: 'zero',
      );

      final result = engine.resolve([wide('a'), wide('b'), zero]);
      expect(result, isNotNull);
      expect(result!.quorumDepth, 3);
    });

    test('participates in consensus on exact containment', () {
      // Winning-set membership is the closed-interval containment
      // test `startMs <= midMs && midMs <= endMs`; a zero-width
      // interval passes only when midMs equals its single point.
      // Construction: a's interval contains baseMs, c's interval
      // ENDS at baseMs (touching), zero sits at baseMs. All three
      // are simultaneously active only at the single point baseMs,
      // so the consensus window is [baseMs, baseMs] and its centre
      // is exactly the zero-width point — which must be counted a
      // participant, not dropped on a strict-< comparison slip.
      const engine = MarzulloEngine(minQuorumRatio: 0.6);
      const baseMs = 1700000000000;
      final result = engine.resolve([
        TimeSample(
          interval: TimeInterval(startMs: baseMs - 100, endMs: baseMs + 100),
          sourceId: 'a',
          groupId: 'a',
        ),
        TimeSample(
          interval: TimeInterval(startMs: baseMs - 100, endMs: baseMs),
          sourceId: 'c',
          groupId: 'c',
        ),
        TimeSample(
          interval: TimeInterval(startMs: baseMs, endMs: baseMs),
          sourceId: 'zero',
          groupId: 'zero',
        ),
      ]);

      expect(result, isNotNull);
      expect(result!.interval, TimeInterval(startMs: baseMs, endMs: baseMs));
      expect(result.participants.map((s) => s.sourceId), contains('zero'));
      expect(result.participantCount, 3);
    });
  });

  group('TimeInterval inverted', () {
    // An inverted interval (start > end) is mathematically
    // meaningless. If admitted it silently corrupts midpoint, width,
    // and every sweep that assumes ordered endpoints — so the
    // invariant is enforced at construction as a runtime
    // ArgumentError, active in release builds where asserts are
    // stripped.
    test('throws ArgumentError at construction', () {
      expect(
        () => TimeInterval(startMs: 1001, endMs: 1000),
        throwsArgumentError,
      );
    });

    test('rejects even a one-millisecond inversion', () {
      expect(() => TimeInterval(startMs: 1, endMs: 0), throwsArgumentError);
    });

    test('error message names both bounds for diagnosis', () {
      expect(
        () => TimeInterval(startMs: 200, endMs: 100),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('200'), contains('100')),
          ),
        ),
      );
    });
  });

  group('Marzullo single-sample consensus (N=1)', () {
    // The engine refuses single-source consensus by design: with one
    // sample there is nothing to cross-check, so resolve must return
    // null rather than anchor to an unverifiable source — regardless
    // of the sample's tier or precision.
    const engine = MarzulloEngine(minQuorumRatio: 0.6);

    TimeSample single({NtsAuthLevel auth = NtsAuthLevel.none}) => TimeSample(
      interval: TimeInterval(startMs: 999, endMs: 1001),
      sourceId: 'solo',
      groupId: 'solo',
      authLevel: auth,
    );

    test('returns null for one unauthenticated sample', () {
      expect(engine.resolve([single()]), isNull);
    });

    test('returns null even for one verified sample', () {
      // A verified N=1 must not form a truth box on its own, and the
      // degraded fallback over the same single sample must also
      // refuse — verifying both tiers of resolve() enforce the
      // two-sample minimum.
      expect(engine.resolve([single(auth: NtsAuthLevel.verified)]), isNull);
    });

    test('returns null for an empty sample list', () {
      expect(engine.resolve([]), isNull);
    });
  });

  // The truth box floors at three *responding* verified hosts, one
  // above the generic two-sample minimum every other reduction uses.
  // Three is the first size that sheds an outlier: at a ratio of 0.6 a
  // 3-sample population needs an overlap of 2. At 2 the required
  // overlap is also 2, so both must agree -- liar detection rather than
  // liar tolerance. See ADR 0007's 2026-08-02 postscript.
  group('Marzullo verified-subset validity floor', () {
    const engine = MarzulloEngine(minQuorumRatio: 0.6, minGroupCount: 1);

    TimeSample verified(String id, int startMs, int endMs) => TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: id,
      authLevel: NtsAuthLevel.verified,
      trustBackend: TrustBackend.webpkiRoots,
    );

    TimeSample plain(String id, int startMs, int endMs) => TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: id,
    );

    test('defaults to three', () {
      expect(const MarzulloEngine().minVerifiedQuorum, 3);
    });

    test('two agreeing verified samples no longer form a truth box', () {
      // The configuration the floor deliberately removes. These two
      // overlap cleanly and would have produced a verified anchor
      // before; now the cycle degrades over the same population.
      final result = engine.resolve([
        verified('nts:a', 1000, 1020),
        verified('nts:b', 1005, 1025),
      ]);

      expect(result, isNotNull);
      expect(result!.degradedTier, isTrue);
      expect(result.authLevel, NtsAuthLevel.none);
    });

    test('three verified samples form a box and shed one outlier', () {
      // The reason the floor is 3 rather than 2: the population is big
      // enough that a required overlap of 2 leaves an outlier
      // outvotable instead of merely detectable.
      final result = engine.resolve([
        verified('nts:a', 1000, 1020),
        verified('nts:b', 1005, 1025),
        verified('nts:liar', 9000, 9020),
      ]);

      expect(result, isNotNull);
      expect(result!.degradedTier, isFalse);
      expect(result.authLevel, NtsAuthLevel.verified);
      expect(
        result.participants.map((s) => s.sourceId),
        isNot(contains('nts:liar')),
      );
    });

    test('the floor counts usable samples, not responses', () {
      // A verified host that answered with an uncertainty the reduction
      // would discard must not fill a slot -- otherwise "three
      // responders" and "three samples the box is built from" diverge.
      const strict = MarzulloEngine(
        minQuorumRatio: 0.6,
        minGroupCount: 1,
        maxAllowedUncertaintyMs: 100,
      );
      final result = strict.resolve([
        verified('nts:a', 1000, 1020),
        verified('nts:b', 1005, 1025),
        verified('nts:noisy', 0, 100000),
      ]);

      expect(result, isNotNull);
      expect(result!.degradedTier, isTrue);
    });

    test('the floor is scoped to the verified subset', () {
      // The degraded fallback reduces over every sample through the
      // same method and keeps the generic two-sample minimum, so a
      // two-source unverified cycle still resolves. Raising the floor
      // must not have leaked into _resolveCore.
      final result = engine.resolve([
        plain('ntp:a', 1000, 1020),
        plain('ntp:b', 1005, 1025),
      ]);

      expect(result, isNotNull);
      expect(result!.degradedTier, isTrue);
      expect(result.authLevel, NtsAuthLevel.none);
    });

    test('a thin verified subset still yields time via the fallback', () {
      // Degradation costs the trust level, not availability: two
      // verified hosts plus lower-tier company publish an anchor, just
      // not a verified one.
      final result = engine.resolve([
        verified('nts:a', 1000, 1020),
        verified('nts:b', 1005, 1025),
        plain('ntp:c', 1002, 1022),
      ]);

      expect(result, isNotNull);
      expect(result!.degradedTier, isTrue);
      expect(result.authLevel, NtsAuthLevel.none);
      expect(result.utc, isA<DateTime>());
    });

    test('a lowered floor restores the two-sample truth box', () {
      // The floor is a field rather than a constant so the boundary is
      // assertable from both sides; this pins that the degradation
      // above is the floor's doing and not some other rejection.
      const lenient = MarzulloEngine(
        minQuorumRatio: 0.6,
        minGroupCount: 1,
        minVerifiedQuorum: 2,
      );
      final result = lenient.resolve([
        verified('nts:a', 1000, 1020),
        verified('nts:b', 1005, 1025),
      ]);

      expect(result, isNotNull);
      expect(result!.degradedTier, isFalse);
      expect(result.authLevel, NtsAuthLevel.verified);
    });

    test('a floor below the reduction\'s own minimum is rejected', () {
      // Two is as low as the field may go. Below it the pass would
      // admit a subset _resolveCore then refuses, so the cycle would
      // degrade for a reason the floor claims to have cleared.
      expect(
        () => MarzulloEngine(minVerifiedQuorum: 1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => MarzulloEngine(minVerifiedQuorum: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('TimeInterval equality and hash semantics', () {
    // TimeInterval is a value type with hand-written ==/hashCode.
    // SyncEngine's stability check compares successive consensus
    // intervals with == (lastStabilityInterval == relativeInterval),
    // so structural equality is load-bearing: identity-only equality
    // would make the stability counter never advance.
    test('equal bounds compare equal and hash equal', () {
      final a = TimeInterval(startMs: 1000, endMs: 1100);
      final b = TimeInterval(startMs: 1000, endMs: 1100);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing either bound breaks equality', () {
      final base = TimeInterval(startMs: 1000, endMs: 1100);
      expect(base == TimeInterval(startMs: 1001, endMs: 1100), isFalse);
      expect(base == TimeInterval(startMs: 1000, endMs: 1101), isFalse);
    });

    test('zero-width intervals obey the same value semantics', () {
      final a = TimeInterval(startMs: 5000, endMs: 5000);
      final b = TimeInterval(startMs: 5000, endMs: 5000);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == TimeInterval(startMs: 5001, endMs: 5001), isFalse);
    });

    test('deduplicates by value in a Set', () {
      final set = {
        TimeInterval(startMs: 1000, endMs: 1100),
        TimeInterval(startMs: 1000, endMs: 1100),
        TimeInterval(startMs: 2000, endMs: 2100),
      };
      expect(set, hasLength(2));
    });
  });

  group('TimeSample equality and hash semantics', () {
    // TimeSample deliberately does NOT override ==/hashCode: it is
    // identity-based. That is safe today because the engine never
    // relies on value-deduplication of samples — participants and
    // representatives are keyed by sourceId in Maps before being
    // collected into Sets. These tests pin the identity semantics so
    // a future value-equality change is a conscious decision (it
    // would alter Set<TimeSample> dedup behaviour) rather than an
    // accidental one.
    TimeSample make() => TimeSample(
      interval: TimeInterval(startMs: 1000, endMs: 1100),
      sourceId: 'nts:time.example',
      groupId: 'g',
    );

    test('field-identical samples are NOT equal (identity semantics)', () {
      expect(make() == make(), isFalse);
    });

    test('a sample equals itself', () {
      final sample = make();
      expect(sample, equals(sample));
    });

    test('field-identical samples occupy distinct Set slots', () {
      expect({make(), make()}, hasLength(2));
    });
  });
}
