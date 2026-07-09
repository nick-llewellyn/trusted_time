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

  group('TrustedTimeConfig cadence mode (ADR 0006)', () {
    test('defaults to singleTier30m with legacy timing untouched', () {
      // The migration contract: existing 1.x integrators who never name
      // cadenceMode keep the single uniform refresh loop bit-for-bit.
      // Assert both the mode and the legacy timing constants the
      // single-tier scheduler reads, so a future accidental flip of any
      // default surfaces here.
      const config = TrustedTimeConfig();
      expect(config.cadenceMode, CadenceMode.singleTier30m);
      expect(config.refreshInterval, const Duration(minutes: 30));
      expect(config.oscillatorDriftFactor, 0.00005);
    });

    test('mobileDefaults() selects tieredMobile with platform-tuned knobs', () {
      // Pins every value ADR 0006 fixes for the factory: the mode, the
      // 15 ppm drift envelope, and the 24h establish cadence on both the
      // foreground refresh and background maintenance timers.
      final config = TrustedTimeConfig.mobileDefaults();
      expect(config.cadenceMode, CadenceMode.tieredMobile);
      expect(config.oscillatorDriftFactor, 0.000015);
      expect(config.refreshInterval, const Duration(hours: 24));
      expect(config.backgroundSyncInterval, const Duration(hours: 24));
    });

    test('mobileDefaults() leaves the global drift default unchanged', () {
      // ADR 0006 open question 2: the platform factory tightens drift
      // for mobile callers without silently shrinking the conservative
      // worst-case band for desktop callers on the global default.
      expect(
        const TrustedTimeConfig().oscillatorDriftFactor,
        isNot(TrustedTimeConfig.mobileDefaults().oscillatorDriftFactor),
      );
    });

    test('round-trips cadenceMode through copyWith', () {
      const original = TrustedTimeConfig();
      final tiered = original.copyWith(cadenceMode: CadenceMode.tieredMobile);
      expect(tiered.cadenceMode, CadenceMode.tieredMobile);
      // Purely additive: an omitted cadenceMode preserves the existing
      // value, and untouched fields keep their defaults.
      final untouched = tiered.copyWith(maxLatency: const Duration(seconds: 7));
      expect(untouched.cadenceMode, CadenceMode.tieredMobile);
      expect(untouched.refreshInterval, original.refreshInterval);
    });

    test('cadenceMode participates in equality and hashCode', () {
      const base = TrustedTimeConfig();
      const tiered = TrustedTimeConfig(cadenceMode: CadenceMode.tieredMobile);
      expect(base == tiered, isFalse);

      const a = TrustedTimeConfig(cadenceMode: CadenceMode.tieredMobile);
      const b = TrustedTimeConfig(cadenceMode: CadenceMode.tieredMobile);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('cadenceMode appears in toString output', () {
      const config = TrustedTimeConfig(cadenceMode: CadenceMode.tieredMobile);
      expect(
        config.toString(),
        contains('cadenceMode: CadenceMode.tieredMobile'),
      );
    });
  });

  group('TrustedTimeConfig validateBurstCount (ADR 0006)', () {
    test('defaults to 4', () {
      expect(const TrustedTimeConfig().validateBurstCount, 4);
    });

    test('mobileDefaults() pins a 4-sample validate burst', () {
      expect(TrustedTimeConfig.mobileDefaults().validateBurstCount, 4);
    });

    test('asserts the burst is at least 1', () {
      expect(
        () => TrustedTimeConfig(validateBurstCount: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('round-trips through copyWith', () {
      const original = TrustedTimeConfig();
      final updated = original.copyWith(validateBurstCount: 7);
      expect(updated.validateBurstCount, 7);
      // Purely additive: an omitted value preserves the existing one.
      final untouched = updated.copyWith(
        maxLatency: const Duration(seconds: 7),
      );
      expect(untouched.validateBurstCount, 7);
    });

    test('participates in equality and hashCode', () {
      const base = TrustedTimeConfig();
      const bursty = TrustedTimeConfig(validateBurstCount: 8);
      expect(base == bursty, isFalse);

      const a = TrustedTimeConfig(validateBurstCount: 8);
      const b = TrustedTimeConfig(validateBurstCount: 8);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('appears in toString output', () {
      const config = TrustedTimeConfig(validateBurstCount: 6);
      expect(config.toString(), contains('validateBurstCount: 6'));
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

  group('TrustedTimeConfig validate cadence knobs (ADR 0006)', () {
    test('default to a 1h validate interval and 15m foreground threshold', () {
      const config = TrustedTimeConfig();
      expect(config.validateInterval, const Duration(hours: 1));
      expect(config.foregroundValidateThreshold, const Duration(minutes: 15));
    });

    test('mobileDefaults() pins the ADR 0006 validate cadence', () {
      final config = TrustedTimeConfig.mobileDefaults();
      expect(config.validateInterval, const Duration(hours: 1));
      expect(config.foregroundValidateThreshold, const Duration(minutes: 15));
    });

    test('round-trip through copyWith', () {
      const original = TrustedTimeConfig();
      final updated = original.copyWith(
        validateInterval: const Duration(minutes: 30),
        foregroundValidateThreshold: const Duration(minutes: 5),
      );
      expect(updated.validateInterval, const Duration(minutes: 30));
      expect(updated.foregroundValidateThreshold, const Duration(minutes: 5));
      // Purely additive: omitted values preserve the existing ones.
      final untouched = updated.copyWith(
        maxLatency: const Duration(seconds: 7),
      );
      expect(untouched.validateInterval, const Duration(minutes: 30));
      expect(untouched.foregroundValidateThreshold, const Duration(minutes: 5));
    });

    test('participate in equality and hashCode', () {
      const base = TrustedTimeConfig();
      const slowValidate = TrustedTimeConfig(
        validateInterval: Duration(hours: 2),
      );
      const eagerForeground = TrustedTimeConfig(
        foregroundValidateThreshold: Duration(minutes: 1),
      );
      expect(base == slowValidate, isFalse);
      expect(base == eagerForeground, isFalse);

      const a = TrustedTimeConfig(validateInterval: Duration(hours: 2));
      const b = TrustedTimeConfig(validateInterval: Duration(hours: 2));
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('appear in toString output', () {
      const config = TrustedTimeConfig(
        validateInterval: Duration(minutes: 45),
        foregroundValidateThreshold: Duration(minutes: 3),
      );
      final dump = config.toString();
      expect(dump, contains('validateInterval: 0:45:00.000000'));
      expect(dump, contains('foregroundValidateThreshold: 0:03:00.000000'));
    });

    test('allows a zero foreground threshold (probe on every resume)', () {
      const config = TrustedTimeConfig(
        foregroundValidateThreshold: Duration.zero,
      );
      expect(config.foregroundValidateThreshold, Duration.zero);
    });

    test('const-constructs a negative foreground threshold (normalized to '
        'zero at the point of use, not by the const constructor)', () {
      const config = TrustedTimeConfig(
        foregroundValidateThreshold: Duration(minutes: -1),
      );
      expect(config.foregroundValidateThreshold, const Duration(minutes: -1));
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

  group('TimeSample.rootDistanceMs', () {
    // Root distance Λ = E + δ/2 (NTPv4). delayMs carries the whole
    // round-trip δ; dispersionMs carries E (default 0). The getter
    // falls back to the interval half-width for the δ/2 term when
    // delayMs is unset, so every sample — including interval-only
    // fixtures — has a defined metric. This is pure data plumbing: no
    // consensus path reads it yet (the weighted-combine sibling ticket
    // does), so these are constructor/getter-level assertions.

    const interval = TimeInterval(startMs: 1000, endMs: 1100); // width 100

    test('fields default to delay-unset and zero dispersion', () {
      const sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      expect(sample.delayMs, isNull);
      expect(sample.dispersionMs, 0);
    });

    test('falls back to interval half-width when delayMs is null', () {
      const sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      // E=0, δ unset → Λ = interval.width ~/ 2 = 50.
      expect(sample.rootDistanceMs, 50);
    });

    test('uses δ/2 from delayMs when set, independent of interval width', () {
      const sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
        delayMs: 80,
      );
      // E=0, δ=80 → Λ = 0 + 80 ~/ 2 = 40 (not the 50 half-width).
      expect(sample.rootDistanceMs, 40);
    });

    test('adds dispersion E to the half round-trip', () {
      const sample = TimeSample(
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
      const sample = TimeSample(
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

    const interval = TimeInterval(startMs: 1000, endMs: 1100);

    test('shifts the interval by refMs - receivedAtMs', () {
      const sample = TimeSample(
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
      const sample = TimeSample(
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
      const sample = TimeSample(
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
      const sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
      );
      expect(identical(sample.normalizedTo(8000), sample), isTrue);
    });

    test('returns this unchanged when already at the reference', () {
      const sample = TimeSample(
        interval: interval,
        sourceId: 'ntp:time.example',
        groupId: 'g',
        receivedAtMs: 8000,
      );
      expect(identical(sample.normalizedTo(8000), sample), isTrue);
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
