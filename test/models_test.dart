import 'package:flutter_test/flutter_test.dart';
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
}
