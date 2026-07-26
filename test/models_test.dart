import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/monotonic_clock.dart';
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
      // and one valid record.
      json['contributors'] = [
        {'sourceId': 42, 'groupId': 'x', 'rttMs': 'fast'},
        'not-a-map',
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

  group('TrustedTimeConfig trust policy', () {
    test('defaults resolve to bundledOnly (security-by-default flip)', () {
      // The headline security posture: a consumer who never reasons
      // about trust gets a library-controlled anchor set, not one the
      // surrounding network (corporate MDM, TLS-inspection CA) can
      // influence. package:nts keeps its own constructor default at
      // platformWithFallback for broad-audience UX; trusted_time flips
      // the *effective* default to bundledOnly on its side.
      const config = TrustedTimeConfig();
      expect(config.usePlatformTrust, isFalse);
      expect(config.customRootCerts, isEmpty);
      expect(config.effectiveTrustMode, TrustMode.bundledOnly);
    });

    test('usePlatformTrust: true resolves to platformOnly', () {
      const config = TrustedTimeConfig(usePlatformTrust: true);
      expect(config.effectiveTrustMode, TrustMode.platformOnly);
    });

    test('non-empty customRootCerts resolves to custom', () {
      const config = TrustedTimeConfig(customRootCerts: [1, 2, 3]);
      expect(config.effectiveTrustMode, TrustMode.custom);
    });

    test('mutually-exclusive combination throws ArgumentError on resolve', () {
      // The const constructor cannot reject this (list emptiness is not
      // a const-evaluable expression), so the config object constructs
      // fine. effectiveTrustMode is the single enforcement point —
      // SyncEngine reads it while building its per-source NtsSource list
      // (each NtsSource constructs its nts.NtsClient lazily), so an
      // invalid config fails closed before any source is built. This is
      // the "both-non-default -> rejected" criterion from the ticket and
      // the merged Secure Time Contract persona-selection table.
      const config = TrustedTimeConfig(
        usePlatformTrust: true,
        customRootCerts: [1, 2, 3],
      );
      expect(() => config.effectiveTrustMode, throwsArgumentError);
    });

    test('round-trips the new fields through copyWith', () {
      const original = TrustedTimeConfig();
      final platform = original.copyWith(usePlatformTrust: true);
      expect(platform.usePlatformTrust, isTrue);
      expect(platform.effectiveTrustMode, TrustMode.platformOnly);

      final custom = original.copyWith(customRootCerts: const [9, 9]);
      expect(custom.customRootCerts, const [9, 9]);
      expect(custom.effectiveTrustMode, TrustMode.custom);

      // Purely additive: untouched fields keep their defaults.
      expect(platform.ntsServers, original.ntsServers);
      expect(platform.ntsPort, original.ntsPort);
    });

    test('copyWith with omitted fields preserves existing values', () {
      const original = TrustedTimeConfig(usePlatformTrust: true);
      final updated = original.copyWith(maxLatency: const Duration(seconds: 7));
      expect(updated.usePlatformTrust, isTrue);
      expect(updated.customRootCerts, isEmpty);
    });

    test('both new fields participate in equality', () {
      const base = TrustedTimeConfig();
      const platform = TrustedTimeConfig(usePlatformTrust: true);
      const custom = TrustedTimeConfig(customRootCerts: [1]);
      expect(base == platform, isFalse);
      expect(base == custom, isFalse);
      expect(platform == custom, isFalse);
    });

    test('equal configs produce equal hashCodes (positive contract)', () {
      // Forward direction of the ==/hashCode contract: equal objects
      // MUST share a hashCode. customRootCerts is folded via
      // Object.hashAll, matching the other list-typed fields, so two
      // configs with equal-by-value root lists hash equally. The
      // reverse (unequal -> unequal hashCode) is intentionally not
      // asserted: hash collisions are permitted by the contract.
      const a = TrustedTimeConfig(customRootCerts: [1, 2, 3]);
      const b = TrustedTimeConfig(customRootCerts: [1, 2, 3]);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('both new fields appear in toString output', () {
      const config = TrustedTimeConfig(usePlatformTrust: true);
      final dump = config.toString();
      expect(dump, contains('usePlatformTrust: true'));
      expect(dump, contains('customRootCerts: 0 bytes'));
    });

    test(
      'toString summarises customRootCerts as a byte count, not raw bytes',
      () {
        // Guards against regressing to interpolating the raw List<int>:
        // doing so leaks consumer CA material into logs and produces
        // huge log lines for PEM bundles. The dump must report only the
        // length and never the byte values themselves.
        const config = TrustedTimeConfig(customRootCerts: [10, 20, 30]);
        final dump = config.toString();
        expect(dump, contains('customRootCerts: 3 bytes'));
        // Assert the field is never rendered as a list at all, rather
        // than excluding one exact rendering of these bytes. Any
        // regression that interpolates the List<int> — regardless of
        // element formatting (spaces, separators) or content — opens
        // with `customRootCerts: [`, so its absence is the
        // format-agnostic leak guard.
        expect(dump, isNot(contains('customRootCerts: [')));
      },
    );
  });

  group('TrustedTimeConfig.requireSleepAwareProjection', () {
    test('defaults to false (fallback accepted silently)', () {
      const config = TrustedTimeConfig();
      expect(config.requireSleepAwareProjection, isFalse);
    });

    test('round-trips through copyWith and preserves when omitted', () {
      const original = TrustedTimeConfig();
      final strict = original.copyWith(requireSleepAwareProjection: true);
      expect(strict.requireSleepAwareProjection, isTrue);

      final untouched = strict.copyWith(maxLatency: const Duration(seconds: 7));
      expect(untouched.requireSleepAwareProjection, isTrue);
    });

    test('participates in equality, hashCode, and toString', () {
      const base = TrustedTimeConfig();
      const strict = TrustedTimeConfig(requireSleepAwareProjection: true);
      expect(base == strict, isFalse);

      const a = TrustedTimeConfig(requireSleepAwareProjection: true);
      expect(a, equals(strict));
      expect(a.hashCode, equals(strict.hashCode));

      expect(strict.toString(), contains('requireSleepAwareProjection: true'));
    });
  });

  group('TrustedTimeConfig default source lists', () {
    test('ntpServers default to three stepping operators', () {
      // Leap-second policy: every default host steps. time.google.com
      // (smearing) was deliberately removed — a smeared source
      // diverges from stepping sources by up to a full second around
      // a leap event.
      const config = TrustedTimeConfig();
      expect(config.ntpServers, [
        'pool.ntp.org',
        'time.apple.com',
        'time.windows.com',
      ]);
      expect(config.ntpServers, isNot(contains('time.google.com')));
    });

    test('ntsServers default to two anycast anchors from distinct '
        'operators', () {
      // minGroupCount defaults to 2, so the default NTS pool must
      // span two registrable-domain groups to mint a verified truth
      // box on its own.
      const config = TrustedTimeConfig();
      expect(config.ntsServers, ['time.cloudflare.com', 'nts.netnod.se']);
    });
  });

  group('TrustedTimeConfig sync cadence', () {
    test('defaults use the 48h anchor-age staleness bound', () {
      const config = TrustedTimeConfig();
      expect(config.refreshInterval, const Duration(hours: 48));
    });

    test('mobileDefaults() pins the 48h anchor-age policy knobs', () {
      // One background refresh attempt per day, with a 48h staleness
      // bound so the best-effort OS scheduler gets a full day of
      // slack before a foreground resume forces a sync.
      final config = TrustedTimeConfig.mobileDefaults();
      expect(config.refreshInterval, const Duration(hours: 48));
      expect(config.backgroundSyncInterval, const Duration(hours: 24));
    });
  });

  group('TrustedTimeConfig ntpBurstCount', () {
    test('defaults to 8', () {
      expect(const TrustedTimeConfig().ntpBurstCount, 8);
    });

    test('asserts the burst is in 1..8', () {
      expect(
        () => TrustedTimeConfig(ntpBurstCount: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => TrustedTimeConfig(ntpBurstCount: 9),
        throwsA(isA<AssertionError>()),
      );
    });

    test('round-trips through copyWith', () {
      const original = TrustedTimeConfig();
      final updated = original.copyWith(ntpBurstCount: 5);
      expect(updated.ntpBurstCount, 5);
      // Purely additive: an omitted value preserves the existing one.
      final untouched = updated.copyWith(
        maxLatency: const Duration(seconds: 7),
      );
      expect(untouched.ntpBurstCount, 5);
    });

    test('participates in equality and hashCode', () {
      const base = TrustedTimeConfig();
      const bursty = TrustedTimeConfig(ntpBurstCount: 3);
      expect(base == bursty, isFalse);

      const a = TrustedTimeConfig(ntpBurstCount: 3);
      const b = TrustedTimeConfig(ntpBurstCount: 3);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('appears in toString output', () {
      const config = TrustedTimeConfig(ntpBurstCount: 6);
      expect(config.toString(), contains('ntpBurstCount: 6'));
    });
  });

  group('TrustedTimeConfig maxConcurrentDnsLookups (ADR 0008)', () {
    test('defaults to null with an effective budget of 6', () {
      const config = TrustedTimeConfig();
      expect(config.maxConcurrentDnsLookups, isNull);
      expect(
        config.effectiveMaxConcurrentDnsLookups,
        TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups,
      );
      expect(config.effectiveMaxConcurrentDnsLookups, 6);
    });

    test('an explicit value wins over the deprecated NTS-only cap', () {
      const config = TrustedTimeConfig(
        maxConcurrentDnsLookups: 9,
        // ignore: deprecated_member_use
        ntsDnsConcurrencyCap: 3,
      );
      expect(config.effectiveMaxConcurrentDnsLookups, 9);
    });

    test('honours the deprecated ntsDnsConcurrencyCap during migration', () {
      const config = TrustedTimeConfig(
        // ignore: deprecated_member_use
        ntsDnsConcurrencyCap: 4,
      );
      expect(config.maxConcurrentDnsLookups, isNull);
      expect(config.effectiveMaxConcurrentDnsLookups, 4);
    });

    test('round-trips through copyWith', () {
      const original = TrustedTimeConfig();
      final updated = original.copyWith(maxConcurrentDnsLookups: 8);
      expect(updated.maxConcurrentDnsLookups, 8);
      // Purely additive: an omitted value preserves the existing one.
      final untouched = updated.copyWith(
        maxLatency: const Duration(seconds: 7),
      );
      expect(untouched.maxConcurrentDnsLookups, 8);
    });

    test('participates in equality and hashCode', () {
      const base = TrustedTimeConfig();
      const capped = TrustedTimeConfig(maxConcurrentDnsLookups: 8);
      expect(base == capped, isFalse);

      const a = TrustedTimeConfig(maxConcurrentDnsLookups: 8);
      const b = TrustedTimeConfig(maxConcurrentDnsLookups: 8);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('appears in toString output', () {
      const config = TrustedTimeConfig(maxConcurrentDnsLookups: 8);
      expect(config.toString(), contains('maxConcurrentDnsLookups: 8'));
    });

    test('rejects a non-positive resolved budget', () {
      const explicit = TrustedTimeConfig(maxConcurrentDnsLookups: 0);
      expect(
        () => explicit.effectiveMaxConcurrentDnsLookups,
        throwsArgumentError,
      );

      const legacy = TrustedTimeConfig(
        // ignore: deprecated_member_use
        ntsDnsConcurrencyCap: -1,
      );
      expect(
        () => legacy.effectiveMaxConcurrentDnsLookups,
        throwsArgumentError,
      );
    });
  });

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
