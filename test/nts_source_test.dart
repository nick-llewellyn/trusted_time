import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/sources/nts_auth_level.dart';
import 'package:trusted_time/src/sources/nts_source.dart';

/// Fixture: a raw query result with the given RTT (µs) and timestamp.
nts.NtsTimeSample rawSample({
  required int roundTripMicros,
  int utcUnixMicros = 1000000000000,
  int serverStratum = 2,
}) {
  return nts.NtsTimeSample(
    utcUnixMicros: utcUnixMicros,
    roundTripMicros: roundTripMicros,
    serverStratum: serverStratum,
    aeadId: 15,
    freshCookies: 2,
    phaseTimings: const nts.PhaseTimings(
      dnsMicros: 0,
      connectMicros: 0,
      tlsHandshakeMicros: 0,
      keRecordIoMicros: 0,
    ),
    trustBackend: nts.TrustBackend.webpkiRoots,
  );
}

/// Fixture: a [TimeSample] with the given [delayMs] (nullable) and
/// half-width [uncertaintyMs].
TimeSample sampleWith({int? delayMs, int uncertaintyMs = 25, String? id}) {
  return TimeSample(
    interval: TimeInterval(
      startMs: 1000000 - uncertaintyMs,
      endMs: 1000000 + uncertaintyMs,
    ),
    sourceId: id ?? 'nts:test',
    groupId: 'g',
    delayMs: delayMs,
  );
}

void main() {
  group('authLevelForTrustBackend mapping table', () {
    // Each row pins one TrustBackend value (plus the defensive null
    // case) to the NtsAuthLevel the engine must record. `verified` is
    // reserved for library-controlled trust stores (bundled webpki
    // roots, caller-supplied custom roots); platform-mediated paths
    // degrade to `none` because a corporate-injected or MDM-installed
    // CA can reach them. See tiered-trust-implementation.md §3.2.
    const cases = <(nts.TrustBackend?, NtsAuthLevel)>[
      (nts.TrustBackend.webpkiRoots, NtsAuthLevel.verified),
      (nts.TrustBackend.custom, NtsAuthLevel.verified),
      (nts.TrustBackend.platform, NtsAuthLevel.none),
      (nts.TrustBackend.platformWithHybridFallback, NtsAuthLevel.none),
      (null, NtsAuthLevel.none),
    ];

    for (final (backend, expected) in cases) {
      test('${backend?.name ?? 'null'} -> ${expected.name}', () {
        expect(authLevelForTrustBackend(backend), expected);
      });
    }

    test('covers every TrustBackend variant (exhaustiveness guard)', () {
      // The switch in authLevelForTrustBackend is compile-time
      // exhaustive, but the five rows above are this test's source of
      // truth. If package:nts adds a TrustBackend variant, this fails
      // until that variant is added to `cases` with an explicit
      // expectation, forcing a conscious classification decision.
      final unmapped = {for (final b in nts.TrustBackend.values) b}
        ..removeAll(cases.map((c) => c.$1).whereType<nts.TrustBackend>());
      expect(
        unmapped,
        isEmpty,
        reason: 'unmapped TrustBackend variants: $unmapped',
      );
    });

    test('only bundled/custom roots map to verified', () {
      for (final backend in nts.TrustBackend.values) {
        final isLibraryControlled =
            backend == nts.TrustBackend.webpkiRoots ||
            backend == nts.TrustBackend.custom;
        expect(
          authLevelForTrustBackend(backend) == NtsAuthLevel.verified,
          isLibraryControlled,
          reason:
              '${backend.name} should '
              '${isLibraryControlled ? '' : 'not '}map to verified',
        );
      }
    });
  });

  group('lowestRttReducer', () {
    test('single sample is returned unchanged (identity)', () {
      final s = sampleWith(delayMs: 40);
      expect(identical(lowestRttReducer([s]), s), isTrue);
    });

    test('picks the sample with the smallest measured delayMs', () {
      final fast = sampleWith(delayMs: 18, id: 'fast');
      final mid = sampleWith(delayMs: 42, id: 'mid');
      final slow = sampleWith(delayMs: 95, id: 'slow');
      expect(identical(lowestRttReducer([mid, slow, fast]), fast), isTrue);
    });

    test('null delayMs falls back to 2x uncertainty (RTT units)', () {
      // Unmeasured δ: key = 2×25 = 50 — worse than the measured 40,
      // better than the measured 60. The reducer must slot it between
      // them, proving the fallback key lives in RTT units.
      final measured40 = sampleWith(delayMs: 40, id: 'm40');
      final unmeasured = sampleWith(delayMs: null, uncertaintyMs: 25);
      final measured60 = sampleWith(delayMs: 60, id: 'm60');
      expect(
        identical(
          lowestRttReducer([unmeasured, measured60, measured40]),
          measured40,
        ),
        isTrue,
      );
      expect(
        identical(lowestRttReducer([unmeasured, measured60]), unmeasured),
        isTrue,
      );
    });

    test('first sample wins RTT ties (stable)', () {
      final a = sampleWith(delayMs: 30, id: 'a');
      final b = sampleWith(delayMs: 30, id: 'b');
      expect(identical(lowestRttReducer([a, b]), a), isTrue);
    });
  });

  group('NtsSource burst orchestration (via debugQueryOverride)', () {
    test('burst issues burstCount queries and returns the lowest-RTT '
        'sample', () async {
      final rtts = <int>[80000, 20000, 55000, 41000];
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 4,
        debugQueryOverride: () async =>
            rawSample(roundTripMicros: rtts[call++]),
      );

      final sample = await source.getTime();
      expect(call, 4, reason: 'all burst attempts should have fired');
      // Lowest RTT is 20000µs -> delayMs 20.
      expect(sample.delayMs, 20);
      expect(sample.receivedAtMs, isNotNull);
    });

    test('burstCount=1 preserves single-query behaviour', () async {
      var call = 0;
      final source = NtsSource(
        'test.example',
        debugQueryOverride: () async {
          call++;
          return rawSample(roundTripMicros: 30000);
        },
      );

      final sample = await source.getTime();
      expect(call, 1);
      expect(sample.delayMs, 30);
    });

    test('partial failure succeeds when at least one attempt lands', () async {
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 3,
        debugQueryOverride: () async {
          final attempt = call++;
          if (attempt < 2) {
            throw const nts.NtsError.timeout(phase: nts.TimeoutPhase.ntp);
          }
          return rawSample(roundTripMicros: 47000);
        },
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 47);
    });

    test('all-fail with a hard failure propagates the non-transient '
        'error even when transient siblings exist', () async {
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 3,
        debugQueryOverride: () async {
          final attempt = call++;
          if (attempt == 1) {
            throw const nts.NtsError.timeout(phase: nts.TimeoutPhase.connect);
          }
          throw const nts.NtsError.timeout(
            phase: nts.TimeoutPhase.dnsSaturation,
          );
        },
      );

      await expectLater(
        source.getTime(),
        throwsA(
          isA<nts.NtsErrorTimeout>().having(
            (e) => e.phase,
            'phase',
            nts.TimeoutPhase.connect,
          ),
        ),
      );
    });

    test('all-fail all-transient throws TransientSourceError', () async {
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        debugQueryOverride: () async {
          throw const nts.NtsError.timeout(
            phase: nts.TimeoutPhase.dnsSaturation,
          );
        },
      );

      await expectLater(source.getTime(), throwsA(isA<TransientSourceError>()));
    });

    test('per-attempt receivedAtMs is captured at each completion', () async {
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        debugQueryOverride: () async {
          final attempt = call++;
          // Second attempt completes ~80ms later than the first.
          await Future.delayed(Duration(milliseconds: attempt * 80));
          // Give the second attempt the lower RTT so it wins and its
          // (later) receipt stamp is the one surfaced.
          return rawSample(roundTripMicros: attempt == 1 ? 10000 : 90000);
        },
      );

      final before = DateTime.now().millisecondsSinceEpoch;
      final sample = await source.getTime();
      expect(sample.delayMs, 10);
      expect(
        sample.receivedAtMs,
        greaterThanOrEqualTo(before + 60),
        reason:
            'winner completed ~80ms after the call started; its '
            'receipt stamp must reflect its own completion instant',
      );
    });

    test('custom reducer is honoured', () async {
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        // Pick the highest RTT instead: proves the reducer seam.
        reducer: (samples) => samples.reduce(
          (a, b) => (a.delayMs ?? 0) >= (b.delayMs ?? 0) ? a : b,
        ),
        debugQueryOverride: () async =>
            rawSample(roundTripMicros: [30000, 70000][call++]),
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 70);
    });

    test('burstCount outside 1..4 is rejected', () {
      expect(() => NtsSource('h', burstCount: 0), throwsAssertionError);
      expect(() => NtsSource('h', burstCount: 5), throwsAssertionError);
    });
  });
}
