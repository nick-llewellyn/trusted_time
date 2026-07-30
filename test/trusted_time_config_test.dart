// TrustedTimeConfig: trust policy, projection requirements, default
// source lists, sync cadence, burst count, and DNS concurrency.
//
// One file per model type, mirroring lib/src/models/. The others:
//   models_test.dart      TrustAnchor
//   time_sample_test.dart TimeSample

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/trusted_time.dart';

void main() {
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
    test('ntpServers is the curated inventory', () {
      const config = TrustedTimeConfig();
      expect(config.ntpInventory, same(curatedNtpInventory));
      expect(config.ntpServers, hasLength(51));
    });

    test('ntpServers is the hostname view of ntpInventory', () {
      // The engine queries by name; the metadata drives selection.
      // These two must not drift apart.
      const config = TrustedTimeConfig();
      expect(
        config.ntpServers,
        config.ntpInventory.map((e) => e.host).toList(),
      );
    });

    test('the inventory excludes every documented smearing operator', () {
      // A smeared source diverges from stepping sources by up to a
      // full second around a leap event and can poison the consensus.
      // Google, AWS, and Meta all publish their smear windows; they
      // were probed and dropped on that evidence (trusted_time-5fz).
      //
      // Matched on registrable domain rather than substring: a bare
      // substring would reject an unrelated host that happens to
      // contain 'aws', and exact hostnames alone would admit a sibling
      // like time1.google.com, which smears for the same reason.
      const smearingDomains = ['google.com', 'aws.com', 'facebook.com'];
      for (final entry in curatedNtpInventory) {
        for (final domain in smearingDomains) {
          expect(
            entry.host == domain || entry.host.endsWith('.$domain'),
            isFalse,
            reason: '${entry.host} belongs to documented smearer $domain',
          );
        }
      }
    });

    test('the inventory has no duplicate hosts', () {
      // A repeated host would inflate a quorum with one server's
      // opinion counted twice.
      expect(
        curatedNtpInventory.map((e) => e.host).toSet(),
        hasLength(curatedNtpInventory.length),
      );
    });

    test('every entry carries a resolved group id', () {
      // 'asn-unknown' is the probe's sentinel for a host whose
      // autonomous system could not be established. An entry carrying
      // it would silently escape the diversity accounting.
      for (final entry in curatedNtpInventory) {
        expect(
          entry.observedGroupId,
          matches(RegExp(r'^as[0-9]+$')),
          reason: '${entry.host} has an unusable group id',
        );
      }
    });

    test('the anycast core spans the tiers it claims', () {
      // mvq partitions on tier: the anycast core is self-localizing
      // and always queried, the unicast hosts are the explore pool.
      final byTier = <NtpServerTier, int>{};
      for (final entry in curatedNtpInventory) {
        byTier[entry.tier] = (byTier[entry.tier] ?? 0) + 1;
      }
      expect(byTier[NtpServerTier.anycast], 10);
      expect(byTier[NtpServerTier.unicastStratum1], 34);
      expect(byTier[NtpServerTier.unicastStratum2], 7);
    });

    test('disableNtpForTesting empties the NTP pool', () {
      const config = TrustedTimeConfig(disableNtpForTesting: true);
      expect(config.ntpServers, isEmpty);
      expect(config.ntpInventory, isEmpty);
    });

    test('NtpServerInfo compares by value', () {
      // The inventory is exported, so consumers can reasonably hold
      // entries in sets or compare them against a constructed
      // expectation.
      const a = NtpServerInfo(
        host: 'time.example',
        tier: NtpServerTier.anycast,
        observedStratum: 2,
        observedGroupId: 'as13335',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      );
      const same = NtpServerInfo(
        host: 'time.example',
        tier: NtpServerTier.anycast,
        observedStratum: 2,
        observedGroupId: 'as13335',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      );
      const differentStratum = NtpServerInfo(
        host: 'time.example',
        tier: NtpServerTier.anycast,
        observedStratum: 3,
        observedGroupId: 'as13335',
        leapPolicy: NtpLeapPolicy.documentedStepping,
      );

      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(differentStratum));
      expect(a.toString(), contains('time.example'));
      expect(a.toString(), contains('stratum 2'));
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
}
