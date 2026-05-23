import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/trusted_time.dart';

void main() {
  group('TrustAnchor Deserialization Safety (CRITICAL-6)', () {
    test('handles invalid NtsAuthLevel index gracefully', () {
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
        'authLevel': 999, // Out of bounds
        'confidence': 1,
        'syncTime': 1000000,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.authLevel, NtsAuthLevel.none);
    });

    test('handles invalid ConfidenceLevel index gracefully', () {
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
        'authLevel': 1,
        'confidence': -1, // Out of bounds
        'syncTime': 1000000,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.confidence, ConfidenceLevel.none);
    });

    test('handles missing optional fields with safe defaults', () {
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(anchor.confidence, ConfidenceLevel.none);
    });
  });

  group('TrustedTimeConfig.ntsTrustMode', () {
    test('defaults to platformWithFallback for backward compatibility', () {
      // Default constructor must preserve the v2.x / pre-NTS-v3
      // behaviour where every NTS-KE handshake silently falls back
      // from the platform store to the static webpki-roots bundle on
      // build_with_native_verifier failure. Changing this default
      // would be a silent semantic break for enterprise / MDM
      // deployments that currently depend on the fallback being
      // available.
      const config = TrustedTimeConfig();
      expect(config.ntsTrustMode, TrustMode.platformWithFallback);
    });

    test('round-trips through copyWith', () {
      const original = TrustedTimeConfig();
      final updated = original.copyWith(ntsTrustMode: TrustMode.platformOnly);
      expect(updated.ntsTrustMode, TrustMode.platformOnly);
      // Other fields should remain at defaults — verifies the new
      // copyWith parameter is purely additive.
      expect(updated.ntsServers, original.ntsServers);
      expect(updated.ntsPort, original.ntsPort);
    });

    test('copyWith with omitted ntsTrustMode preserves existing value', () {
      const original = TrustedTimeConfig(ntsTrustMode: TrustMode.platformOnly);
      final updated = original.copyWith(maxLatency: const Duration(seconds: 7));
      expect(updated.ntsTrustMode, TrustMode.platformOnly);
    });

    test('participates in equality', () {
      const a = TrustedTimeConfig();
      const b = TrustedTimeConfig(ntsTrustMode: TrustMode.platformOnly);
      expect(a == b, isFalse);
    });

    test('equal configs produce equal hashCodes (positive contract)', () {
      // Verifies the field is folded into hashCode by checking the
      // forward direction of the Object.== / hashCode contract:
      // equal objects MUST share a hashCode. The reverse (unequal
      // -> unequal hashCode) is intentionally not asserted because
      // hash collisions are permitted by the contract; asserting
      // inequality would test a non-guarantee and could spuriously
      // fail under a future hashAll re-tuning.
      const a = TrustedTimeConfig(ntsTrustMode: TrustMode.platformOnly);
      const b = TrustedTimeConfig(ntsTrustMode: TrustMode.platformOnly);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('appears in toString output', () {
      const config = TrustedTimeConfig(ntsTrustMode: TrustMode.platformOnly);
      expect(
        config.toString(),
        contains('ntsTrustMode: TrustMode.platformOnly'),
      );
    });
  });

  group('TimeSample.trustBackend', () {
    // The field is the per-handshake observability counterpart to
    // TrustedTimeConfig.ntsTrustMode: nullable, surfaced unchanged
    // from package:nts's NtsTimeSample for NTS samples and absent
    // (null) for non-NTS sources that have no equivalent concept.
    // These tests lock in the backward-compatible default and the
    // pass-through contract that telemetry consumers
    // (SyncObserver.onSampleReceived, the example app's terminal
    // log) depend on.

    const interval = TimeInterval(startMs: 1000, endMs: 1100);

    test('defaults to null when constructor parameter is omitted', () {
      // Backward compatibility: every call site that constructs a
      // TimeSample without naming trustBackend (NTP source, HTTPS
      // source, every test fake) keeps producing samples whose
      // trustBackend field is null. Future readers must not change
      // this default to a non-null sentinel — it would falsely
      // imply NTS-style trust-backend semantics for sources that
      // have no such concept.
      const sample = TimeSample(
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
      const sample = TimeSample(
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
        const nullBackend = TimeSample(
          interval: interval,
          sourceId: 'ntp:time.example',
          groupId: 'g',
        );
        expect(nullBackend.toString(), isNot(contains('backend:')));

        const platformBackend = TimeSample(
          interval: interval,
          sourceId: 'nts:time.example',
          groupId: 'g',
          trustBackend: TrustBackend.platform,
        );
        expect(platformBackend.toString(), contains('backend: platform'));
      },
    );
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
