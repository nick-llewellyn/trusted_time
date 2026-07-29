// TrustAnchor: deserialization safety and contributor telemetry.
//
// One file per model type, mirroring lib/src/models/. The others:
//   trusted_time_config_test.dart  TrustedTimeConfig
//   time_sample_test.dart          TimeSample

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
      // Pre-boot-ID anchors deserialize with a null bootId, which the
      // warm-restore reboot check treats as rebooted (fail closed).
      expect(anchor.bootId, isNull);
    });

    test('bootId survives a toJson/fromJson round-trip', () {
      const anchor = TrustAnchor(
        networkUtcMs: 1000000,
        uptimeMs: 50000,
        wallMs: 1000000,
        uncertaintyMs: 10,
        bootId: 'f81d4fae-7dec-11d0-a765-00a0c91e6bf6',
      );

      final restored = TrustAnchor.fromJson(anchor.toJson());
      expect(restored.bootId, 'f81d4fae-7dec-11d0-a765-00a0c91e6bf6');
    });

    test('null bootId is omitted from JSON and round-trips as null', () {
      const anchor = TrustAnchor(
        networkUtcMs: 1000000,
        uptimeMs: 50000,
        wallMs: 1000000,
        uncertaintyMs: 10,
      );

      final json = anchor.toJson();
      expect(json.containsKey('bootId'), isFalse);
      expect(TrustAnchor.fromJson(json).bootId, isNull);
    });
  });

  group('TrustAnchor contributor telemetry', () {
    // Contributor records are diagnostic metadata riding inside the
    // anchor: serialization must round-trip them faithfully, but any
    // absent or malformed entry must cost only itself — never the
    // anchor (which is a trust reference the library must not discard
    // over cosmetic metadata).

    const full = TrustAnchorContributor(
      sourceId: 'nts:time.example.com',
      groupId: 'example.com',
      rttMs: 42,
      dispersionMs: 3,
      authLevel: NtsAuthLevel.verified,
      wonConsensus: true,
      stratum: 2,
      jitterMs: 7,
    );

    const minimal = TrustAnchorContributor(
      sourceId: 'ntp:pool.ntp.org',
      groupId: 'asn-unknown',
      rttMs: 120,
      dispersionMs: 0,
      authLevel: NtsAuthLevel.none,
      wonConsensus: false,
    );

    TrustAnchor anchorWith(List<TrustAnchorContributor> contributors) =>
        TrustAnchor(
          networkUtcMs: 1000000,
          uptimeMs: 50000,
          wallMs: 1000000,
          uncertaintyMs: 10,
          contributors: contributors,
        );

    test('contributors round-trip through toJson/fromJson', () {
      final restored = TrustAnchor.fromJson(
        anchorWith([full, minimal]).toJson(),
      );

      expect(restored.contributors, hasLength(2));
      final a = restored.contributors[0];
      expect(a.sourceId, 'nts:time.example.com');
      expect(a.groupId, 'example.com');
      expect(a.rttMs, 42);
      expect(a.dispersionMs, 3);
      expect(a.authLevel, NtsAuthLevel.verified);
      expect(a.wonConsensus, isTrue);
      expect(a.stratum, 2);
      expect(a.jitterMs, 7);

      final b = restored.contributors[1];
      expect(b.sourceId, 'ntp:pool.ntp.org');
      expect(b.authLevel, NtsAuthLevel.none);
      expect(b.wonConsensus, isFalse);
      // Optional telemetry absent → omitted from JSON → null on restore.
      expect(b.stratum, isNull);
      expect(b.jitterMs, isNull);
    });

    test('empty contributors are omitted from JSON (legacy-shape output)', () {
      final json = anchorWith(const []).toJson();
      expect(json.containsKey('contributors'), isFalse);
    });

    test('legacy JSON without a contributors key restores as empty', () {
      // Anchors persisted before the field existed must keep loading.
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
        'authLevel': 'verified',
        'confidence': 1,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.contributors, isEmpty);
      expect(anchor.authLevel, NtsAuthLevel.verified);
    });

    test('malformed contributor entries are dropped, not fatal', () {
      final json = anchorWith([full]).toJson();
      // Corrupt the list in-place: a mistyped entry, a non-map entry,
      // entries with a missing or mistyped wonConsensus, and one valid
      // record. A missing wonConsensus must drop the entry rather than
      // silently defaulting to a fake "lost consensus" record.
      json['contributors'] = [
        {'sourceId': 42, 'groupId': 'x', 'rttMs': 'fast'},
        'not-a-map',
        full.toJson()..remove('wonConsensus'),
        full.toJson()..['wonConsensus'] = 'yes',
        full.toJson(),
      ];

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.contributors, hasLength(1));
      expect(anchor.contributors.single.sourceId, 'nts:time.example.com');
    });

    test('unknown contributor authLevel degrades to none', () {
      final entry = full.toJson()..['authLevel'] = 'quantum';
      final anchor = TrustAnchor.fromJson(
        anchorWith(const []).toJson()..['contributors'] = [entry],
      );
      expect(anchor.contributors.single.authLevel, NtsAuthLevel.none);
    });

    test('contributors is not part of the trust surface', () {
      // A wholly corrupt contributors value must not fail the anchor.
      final json = anchorWith(const []).toJson()..['contributors'] = 'garbage';
      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.contributors, isEmpty);
      expect(anchor.networkUtcMs, 1000000);
    });
  });
}
