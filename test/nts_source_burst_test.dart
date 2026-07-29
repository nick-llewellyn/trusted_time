// NtsSource query path: driving a burst of queries through
// debugQueryOverride, and shaping the winning result into a TimeSample
// interval per RFC 5905 clock-filter semantics.
//
// The identity and reduction concerns either side of this path — trust
// backend mapping, lowest-RTT reduction, group ID derivation — live in
// nts_source_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/sources/nts_source.dart';

/// Fixture: a raw query result with the given RTT (µs) and timestamp.
/// The 7.1 clock-filter fields default to their `0` "not available"
/// sentinels, matching pre-7.1-shaped samples.
nts.NtsTimeSample rawSample({
  required int roundTripMicros,
  int utcUnixMicros = 1000000000000,
  int serverStratum = 2,
  int peerDelayMicros = 0,
  int rootDelayMicros = 0,
  int rootDispersionMicros = 0,
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
    peerDelayMicros: peerDelayMicros,
    rootDelayMicros: rootDelayMicros,
    rootDispersionMicros: rootDispersionMicros,
  );
}

void main() {
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

    test('burst attempts run sequentially, never overlapping', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 4,
        debugQueryOverride: () async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          inFlight--;
          call++;
          return rawSample(roundTripMicros: 30000);
        },
      );

      await source.getTime();
      expect(call, 4);
      expect(
        maxInFlight,
        1,
        reason: 'sequential burst must never have two attempts in flight',
      );
    });

    test('a depleted maxLatency budget skips remaining attempts and '
        'returns the best sample gathered so far', () async {
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 4,
        maxLatency: const Duration(milliseconds: 20),
        debugQueryOverride: () async {
          call++;
          // Each attempt outlives the whole budget, so only the
          // first attempt (which always dispatches) runs.
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return rawSample(roundTripMicros: 30000);
        },
      );

      final sample = await source.getTime();
      expect(call, 1, reason: 'budget depletion must skip later attempts');
      expect(sample.delayMs, 30);
    });

    test('RTT tie-break is deterministic by attempt index', () async {
      // All attempts tie on RTT. The sequential burst appends
      // successes in attempt-index order, so lowestRttReducer's
      // "first wins" tie-break selects attempt 0 — pinning that the
      // winning sample and its stratum attribution stay deterministic
      // when RTT keys tie.
      const tiedRttMicros = 30000;
      var call = 0;
      int? observedStratum;
      final source = NtsSource(
        'test.example',
        burstCount: 3,
        onStratumObserved: (s) => observedStratum = s,
        debugQueryOverride: () async {
          final attempt = call++;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          // Offset each attempt's timestamp by a full second so the
          // winner stays identifiable after the µs -> ms conversion.
          return rawSample(
            roundTripMicros: tiedRttMicros,
            utcUnixMicros: 1000000000000 + attempt * 1000000,
            serverStratum: attempt + 1,
          );
        },
      );

      final sample = await source.getTime();
      expect(call, 3, reason: 'all burst attempts should have fired');
      // Attempt 0's timestamp (offset +0) identifies the winner.
      final midpointMs = (sample.interval.startMs + sample.interval.endMs) ~/ 2;
      expect(midpointMs, 1000000000000 ~/ 1000);
      expect(
        observedStratum,
        1,
        reason: 'stratum attribution must follow the attempt-0 winner',
      );
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

    test('winner carries the burst delay spread as jitterMs and its '
        'own stratum', () async {
      // RTTs 80/20/55ms → winner δ=20ms, spread 60ms. Stratum rides
      // per-attempt so the winner's own value (not the last seen) is
      // the one surfaced.
      final rtts = <int>[80000, 20000, 55000];
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 3,
        debugQueryOverride: () async {
          final attempt = call++;
          return rawSample(
            roundTripMicros: rtts[attempt],
            serverStratum: attempt + 1,
          );
        },
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 20);
      expect(sample.jitterMs, 60);
      expect(sample.stratum, 2);
    });

    test('single-success burst leaves jitterMs null', () async {
      // Two attempts, one lands: a spread needs two observations, so
      // jitter stays null rather than reporting a misleading 0.
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        debugQueryOverride: () async {
          if (call++ == 0) {
            throw const nts.NtsError.timeout(phase: nts.TimeoutPhase.ntp);
          }
          return rawSample(roundTripMicros: 47000);
        },
      );

      final sample = await source.getTime();
      expect(sample.jitterMs, isNull);
      expect(sample.stratum, 2);
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

    test(
      'pre-wrapped TransientSourceError keeps transient classification',
      () async {
        // A TransientSourceError thrown directly by the query (rather than
        // being wrapped by the dnsSaturation branch) must still count as
        // transient, so an all-transient burst bypasses cooldown instead of
        // being classified as a hard failure.
        final source = NtsSource(
          'test.example',
          burstCount: 2,
          debugQueryOverride: () async {
            throw const TransientSourceError('already-wrapped transient');
          },
        );

        await expectLater(
          source.getTime(),
          throwsA(isA<TransientSourceError>()),
        );
      },
    );

    test('pre-wrapped transient sibling cannot mask a hard failure', () async {
      // Attempt 0 fails hard immediately; attempt 1 throws a pre-wrapped
      // TransientSourceError later. If the wrapper were routed through
      // the generic (non-transient) catch, its later assignment would
      // overwrite the hard error and the burst would incorrectly
      // propagate as transient — bypassing cooldown despite the hard
      // failure. The hard error must take precedence.
      var call = 0;
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        debugQueryOverride: () async {
          final attempt = call++;
          if (attempt == 0) {
            throw const nts.NtsError.timeout(phase: nts.TimeoutPhase.connect);
          }
          await Future.delayed(const Duration(milliseconds: 20));
          throw const TransientSourceError('already-wrapped transient');
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

      final before = TimeSample.monotonicReceiptNowMs();
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

    test('burstCount outside 1..8 is rejected', () {
      // RangeError (not assert), so the check survives release builds:
      // TrustedTimeConfig's const constructor can only assert, making
      // this the deterministic production failure point for an invalid
      // ntsBurstCount.
      expect(() => NtsSource('h', burstCount: 0), throwsRangeError);
      expect(() => NtsSource('h', burstCount: 9), throwsRangeError);
      // The inclusive upper bound is accepted.
      expect(() => NtsSource('h', burstCount: 8), returnsNormally);
    });

    test('warm() is a no-op under debugQueryOverride', () async {
      // The override contract promises the FFI surface is never
      // touched, so warm() must complete without attempting to mint an
      // NtsClient, and the subsequent scripted query must run normally.
      final source = NtsSource(
        'test.example',
        debugQueryOverride: () async => rawSample(roundTripMicros: 30000),
      );

      await source.warm();
      final sample = await source.getTime();
      expect(sample.delayMs, 30);
    });

    test('reducer returning a non-input instance is rejected in '
        'debug', () async {
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        // Contract violation: returns a derived copy instead of an
        // input element, so the winner cannot be mapped back to its
        // raw attempt for stratum attribution.
        reducer: (samples) =>
            samples.first.normalizedTo(samples.first.receivedAtMs! + 1),
        debugQueryOverride: () async => rawSample(roundTripMicros: 30000),
      );

      // The assertion fires inside getTime()'s awaited work, so the
      // expectation must await the Future to reliably observe it.
      await expectLater(source.getTime(), throwsAssertionError);
    });
  });

  group('RFC 5905 clock-filter interval shaping (nts 7.1)', () {
    // One helper per case: run a single-query burst through
    // debugQueryOverride so the sample crosses the real _toTimeSample
    // conversion.
    Future<TimeSample> convert(nts.NtsTimeSample raw) async {
      final source = NtsSource(
        'test.example',
        debugQueryOverride: () async => raw,
      );
      return source.getTime();
    }

    test('plausible peer delay yields the root-distance interval', () async {
      // RTT 80ms, δ 20ms (server spent 60ms processing), root delay
      // 10ms, root dispersion 3ms.
      final sample = await convert(
        rawSample(
          roundTripMicros: 80000,
          utcUnixMicros: 1000000000000,
          peerDelayMicros: 20000,
          rootDelayMicros: 10000,
          rootDispersionMicros: 3000,
        ),
      );

      // Midpoint: server transmit time + δ/2 = 1000000000ms + 10ms.
      expect(sample.interval.midpoint, 1000000010);
      // Half-width Λ = δ/2 + rootDelay/2 + rootDispersion
      //             = 10 + 5 + 3 = 18ms (vs 40ms under RTT/2).
      expect(sample.uncertaintyMs, 18);
      // δ is the network-only peer delay, not the whole RTT.
      expect(sample.delayMs, 20);
      // E = rootDelay/2 + rootDispersion = 8ms, so Λ = E + δ/2
      // reproduces the half-width.
      expect(sample.dispersionMs, 8);
      expect(sample.rootDistanceMs, 18);
    });

    test('sub-millisecond server error budget rounds up, never to '
        'zero', () async {
      // rootDelay/2 + rootDispersion = 250 + 900 = 1150µs → 2ms after
      // ceiling. Λ is a bound: conversion error must widen it, not
      // truncate a non-zero budget away.
      final sample = await convert(
        rawSample(
          roundTripMicros: 80000,
          utcUnixMicros: 1000000000000,
          peerDelayMicros: 20000,
          rootDelayMicros: 500,
          rootDispersionMicros: 900,
        ),
      );

      expect(sample.dispersionMs, 2);
      // Half-width Λ = δ/2 + E = 10 + 2 = 12ms.
      expect(sample.uncertaintyMs, 12);
    });

    test('zero peer delay (sentinel) keeps the legacy RTT/2 shape', () async {
      final sample = await convert(
        rawSample(
          roundTripMicros: 80000,
          utcUnixMicros: 1000000000000,
          // peerDelayMicros defaults to 0: pre-7.1-shaped sample.
          rootDelayMicros: 10000,
          rootDispersionMicros: 3000,
        ),
      );

      expect(sample.interval.midpoint, 1000000000);
      expect(sample.uncertaintyMs, 40);
      expect(sample.delayMs, 80);
      expect(sample.dispersionMs, 0);
    });

    test('implausible peer delay (> RTT) falls back to RTT/2', () async {
      // δ above the round trip signals a local clock step
      // mid-exchange; the clock-filter fields must be ignored.
      final sample = await convert(
        rawSample(
          roundTripMicros: 80000,
          utcUnixMicros: 1000000000000,
          peerDelayMicros: 90000,
          rootDelayMicros: 10000,
          rootDispersionMicros: 3000,
        ),
      );

      expect(sample.interval.midpoint, 1000000000);
      expect(sample.uncertaintyMs, 40);
      expect(sample.delayMs, 80);
      expect(sample.dispersionMs, 0);
    });

    test('burst reduction keys on peer delay, not whole RTT', () async {
      // Attempt 0: lower RTT but higher network delay (fast server
      // processing far away). Attempt 1: higher RTT but lower δ (slow
      // server processing nearby). The reducer must pick attempt 1 —
      // the least path-asymmetric sample.
      var call = 0;
      final raws = [
        rawSample(
          roundTripMicros: 50000,
          peerDelayMicros: 45000,
          utcUnixMicros: 1000000000000,
        ),
        rawSample(
          roundTripMicros: 70000,
          peerDelayMicros: 15000,
          utcUnixMicros: 1000000000000,
        ),
      ];
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        debugQueryOverride: () async => raws[call++],
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 15);
    });

    test('mixed burst: plausible-δ sample outranks a sentinel sample '
        'only when its δ is smaller', () async {
      // Sentinel attempt keys on its whole RTT (30ms); the
      // clock-filter attempt keys on δ = 12ms and wins despite its
      // larger RTT.
      var call = 0;
      final raws = [
        rawSample(roundTripMicros: 30000),
        rawSample(roundTripMicros: 60000, peerDelayMicros: 12000),
      ];
      final source = NtsSource(
        'test.example',
        burstCount: 2,
        debugQueryOverride: () async => raws[call++],
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 12);
    });
  });
}
