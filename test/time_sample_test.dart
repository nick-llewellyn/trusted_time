// TimeSample: trust backend mapping, root distance, normalization, and
// the monotonic receipt timeline. Plus TrustedTime.ntsTrustStatus, whose
// pass-through contract is asserted against the same nts surface.
//
// One file per model type, mirroring lib/src/models/. The others:
//   models_test.dart               TrustAnchor
//   trusted_time_config_test.dart  TrustedTimeConfig

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/trusted_time.dart';

void main() {
  group('TimeSample.trustBackend', () {
    // The field is the per-handshake observability counterpart to the
    // TrustedTimeConfig trust policy (usePlatformTrust /
    // customRootCerts): nullable, surfaced unchanged
    // from package:nts's NtsTimeSample for NTS samples and absent
    // (null) for non-NTS sources that have no equivalent concept.
    // These tests lock in the backward-compatible default and the
    // pass-through contract that telemetry consumers
    // (SyncObserver.onSampleReceived, the example app's terminal
    // log) depend on.

    final interval = TimeInterval(startMs: 1000, endMs: 1100);

    test('defaults to null when constructor parameter is omitted', () {
      // Backward compatibility: every call site that constructs a
      // TimeSample without naming trustBackend (NTP source, every
      // test fake) keeps producing samples whose
      // trustBackend field is null. Future readers must not change
      // this default to a non-null sentinel — it would falsely
      // imply NTS-style trust-backend semantics for sources that
      // have no such concept.
      final sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      expect(sample.trustBackend, isNull);
    });

    test('round-trips a non-null TrustBackend through the constructor', () {
      // Stub-source equivalent of the bd's pass-through criterion:
      // a TimeSample produced with a specific TrustBackend value
      // exposes that exact value unchanged. Engine forwarding to
      // SyncObserver.onSampleReceived is a single
      // `_observer?.onSampleReceived(sample)` call with no
      // reconstruction (verifiable by inspection in
      // lib/src/sync_engine.dart), so this constructor-level
      // round-trip is sufficient to cover the documented "flows
      // through unchanged" contract.
      final sample = TimeSample(
        interval: interval,
        sourceId: 'nts:time.example',
        groupId: 'g',
        trustBackend: TrustBackend.platform,
      );
      expect(sample.trustBackend, TrustBackend.platform);
    });

    test(
      'toString omits backend marker when null and includes it when set',
      () {
        final nullBackend = TimeSample(
          interval: interval,
          sourceId: 'ntp:time.example',
          groupId: 'g',
        );
        expect(nullBackend.toString(), isNot(contains('backend:')));

        final platformBackend = TimeSample(
          interval: interval,
          sourceId: 'nts:time.example',
          groupId: 'g',
          trustBackend: TrustBackend.platform,
        );
        expect(platformBackend.toString(), contains('backend: platform'));
      },
    );
  });

  group('TimeSample.rootDistanceMs', () {
    // Root distance Λ = E + δ/2 (NTPv4). delayMs carries the whole
    // round-trip δ; dispersionMs carries E (default 0). The getter
    // falls back to the interval half-width for the δ/2 term when
    // delayMs is unset, so every sample — including interval-only
    // fixtures — has a defined metric. This is pure data plumbing: no
    // consensus path reads it yet (the weighted-combine sibling ticket
    // does), so these are constructor/getter-level assertions.

    final interval = TimeInterval(startMs: 1000, endMs: 1100); // width 100

    test('fields default to delay-unset and zero dispersion', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      expect(sample.delayMs, isNull);
      expect(sample.dispersionMs, 0);
    });

    test('falls back to interval half-width when delayMs is null', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      // E=0, δ unset → Λ = interval.width ~/ 2 = 50.
      expect(sample.rootDistanceMs, 50);
    });

    test('uses δ/2 from delayMs when set, independent of interval width', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
        delayMs: 80,
      );
      // E=0, δ=80 → Λ = 0 + 80 ~/ 2 = 40 (not the 50 half-width).
      expect(sample.rootDistanceMs, 40);
    });

    test('adds dispersion E to the half round-trip', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'nts:time.example',
        groupId: 'g',
        delayMs: 80,
        dispersionMs: 15,
      );
      // Λ = E + δ/2 = 15 + 40 = 55.
      expect(sample.rootDistanceMs, 55);
    });

    test('dispersion applies on the half-width fallback too', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'nts:time.example',
        groupId: 'g',
        dispersionMs: 15,
      );
      // δ unset → Λ = 15 + (100 ~/ 2) = 65.
      expect(sample.rootDistanceMs, 65);
    });

    test('asserts on negative delayMs', () {
      // A negative δ would yield a nonsensical Λ; guard at construction.
      expect(
        () => TimeSample(
          interval: interval,
          sourceId: 'ntp:time.example',
          groupId: 'g',
          delayMs: -1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts on negative dispersionMs', () {
      expect(
        () => TimeSample(
          interval: interval,
          sourceId: 'ntp:time.example',
          groupId: 'g',
          dispersionMs: -1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('TimeSample.normalizedTo', () {
    // Each sample's interval estimates the true time at its own
    // receipt instant. normalizedTo slides the interval along the
    // local timeline by (refMs - receivedAtMs) so samples received at
    // different instants become directly comparable under Marzullo
    // intersection. See SyncEngine._normalizedToLatestReceipt for the
    // consuming side.

    final interval = TimeInterval(startMs: 1000, endMs: 1100);

    test('shifts the interval by refMs - receivedAtMs', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'nts:time.example',
        groupId: 'g',
        receivedAtMs: 5000,
      );
      final shifted = sample.normalizedTo(8000);
      expect(shifted.interval.startMs, 4000);
      expect(shifted.interval.endMs, 4100);
      expect(shifted.receivedAtMs, 8000);
    });

    test('shifts backwards for a reference earlier than receipt', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'nts:time.example',
        groupId: 'g',
        receivedAtMs: 5000,
      );
      final shifted = sample.normalizedTo(4000);
      expect(shifted.interval.startMs, 0);
      expect(shifted.interval.endMs, 100);
    });

    test('preserves width and all non-interval fields', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'nts:time.example',
        groupId: 'g',
        authLevel: NtsAuthLevel.verified,
        delayMs: 80,
        dispersionMs: 15,
        receivedAtMs: 5000,
      );
      final shifted = sample.normalizedTo(9000);
      expect(shifted.interval.width, sample.interval.width);
      expect(shifted.sourceId, sample.sourceId);
      expect(shifted.groupId, sample.groupId);
      expect(shifted.authLevel, sample.authLevel);
      expect(shifted.delayMs, sample.delayMs);
      expect(shifted.dispersionMs, sample.dispersionMs);
    });

    test('returns this unchanged when receivedAtMs is null', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      expect(identical(sample.normalizedTo(8000), sample), isTrue);
    });

    test('returns this unchanged when already at the reference', () {
      final sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
        receivedAtMs: 8000,
      );
      expect(identical(sample.normalizedTo(8000), sample), isTrue);
    });
  });

  group('TimeSample.monotonicReceiptNowMs', () {
    // The receipt timeline rides the reader resolved at first stamp
    // (the shared nts bridge clock when initialized), latched for the
    // process lifetime so all stamps compare on one epoch. The seam
    // below injects a scripted reader in place of the latched one.

    tearDown(() => TimeSample.debugSetReceiptReader(null));

    test('reads deltas from the injected reader in milliseconds', () {
      var micros = 7_000_000;
      TimeSample.debugSetReceiptReader(
        MonotonicReader(read: () => micros, isSleepAware: true),
      );
      // Injection captures the current reading as the origin.
      expect(TimeSample.monotonicReceiptNowMs(), 0);
      micros += 2_500_000;
      expect(TimeSample.monotonicReceiptNowMs(), 2500);
    });

    test('latches the reader across stamps (no re-resolution)', () {
      var reads = 0;
      var micros = 0;
      TimeSample.debugSetReceiptReader(
        MonotonicReader(
          read: () {
            reads++;
            return micros;
          },
          isSleepAware: true,
        ),
      );
      micros = 1_000_000;
      TimeSample.monotonicReceiptNowMs();
      TimeSample.monotonicReceiptNowMs();
      // One read at injection (origin capture) plus one per stamp —
      // a re-resolving implementation would not consult this reader
      // at all after the first call.
      expect(reads, 3);
    });

    test('unlatching resolves a fresh default reader on next stamp', () {
      var micros = 0;
      TimeSample.debugSetReceiptReader(
        MonotonicReader(read: () => micros, isSleepAware: true),
      );
      micros = 9_000_000;
      expect(TimeSample.monotonicReceiptNowMs(), 9000);
      TimeSample.debugSetReceiptReader(null);
      // Default resolution in a test isolate is the Stopwatch fallback,
      // whose first read anchors a fresh epoch near zero.
      expect(TimeSample.monotonicReceiptNowMs(), lessThan(9000));
    });
  });

  group('TrustedTime.ntsTrustStatus pass-through', () {
    // The bd's acceptance criterion says the regression test must
    // confirm the wrapper returns whatever `nts.ntsTrustStatus()`
    // returns at call time, without asserting specific field values
    // (those depend on platform / runtime state). Here we exercise
    // the negative half of the pass-through contract: with no
    // `NtsRustLib.init()` having run in the unit-test process, both
    // `nts.ntsTrustStatus()` and `TrustedTime.ntsTrustStatus()`
    // throw `StateError` for the same FRB-dispatcher reason. If the
    // wrapper were swallowing, wrapping, or otherwise converting
    // the error, this test would catch it.
    //
    // The positive (returns-snapshot) half cannot be exercised in
    // CI without the Rust dylib loaded, same constraint that gated
    // PR #27 / #28 / #29's behavioural tests.

    test('wrapper propagates underlying StateError with matching '
        'runtimeType and message', () {
      // Capture the underlying call's failure first so we have a
      // concrete reference to compare against. Per the ffi
      // dispatcher's contract, this throws StateError when
      // NtsRustLib.init() has not run.
      StateError? underlyingError;
      try {
        nts.ntsTrustStatus();
      } on StateError catch (e) {
        underlyingError = e;
      }

      // Then capture the wrapper's failure.
      StateError? wrapperError;
      try {
        TrustedTime.ntsTrustStatus();
      } on StateError catch (e) {
        wrapperError = e;
      }

      // Both calls must have actually thrown — otherwise the test
      // is vacuous (would also pass if neither call threw).
      expect(
        underlyingError,
        isNotNull,
        reason:
            'Sanity check: nts.ntsTrustStatus() must throw '
            'StateError without NtsRustLib.init(). If a future '
            'package:nts version makes this returnable in test '
            'envs, this group becomes vacuous and should be '
            'redesigned to compare snapshot identity instead.',
      );
      expect(wrapperError, isNotNull);

      // Tighten the pass-through claim: the wrapper must produce
      // the same concrete runtimeType and the same message text.
      // A swallow-and-rethrow or convert-to-Exception would
      // change the runtimeType; a re-throw via a new
      // StateError(...) would change the message.
      expect(wrapperError!.runtimeType, equals(underlyingError!.runtimeType));
      expect(wrapperError.message, equals(underlyingError.message));
    });
  });
}
