// TrustedTimeConfig: trust policy, projection requirements, default
// source lists, sync cadence, burst count, and DNS concurrency.
//
// One file per model type, mirroring lib/src/models/. The others:
//   models_test.dart      TrustAnchor
//   time_sample_test.dart TimeSample

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/nts_inventory.dart'
    show curatedNtsHostnames;
import 'package:trusted_time/trusted_time.dart';

/// A substitute NTS inventory entry for the seam tests.
const _ntsEntry = NtsServerInfo(
  host: 'fake.nts.test',
  tier: TimeServerTier.anycast,
  observedStratum: 1,
  leapPolicy: LeapPolicy.documentedStepping,
);

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
      final byTier = <TimeServerTier, int>{};
      for (final entry in curatedNtpInventory) {
        byTier[entry.tier] = (byTier[entry.tier] ?? 0) + 1;
      }
      expect(byTier[TimeServerTier.anycast], 10);
      expect(byTier[TimeServerTier.unicastStratum1], 34);
      expect(byTier[TimeServerTier.unicastStratum2], 7);
    });

    test('disableNtpForTesting empties the NTP pool', () {
      const config = TrustedTimeConfig(disableNtpForTesting: true);
      expect(config.ntpServers, isEmpty);
      expect(config.ntpInventory, isEmpty);
    });

    test('ntpInventoryForTesting replaces the inventory', () {
      // The partition reads ntpInventory; the override exists so a test
      // can control its shape without the curated 51.
      const entry = NtpServerInfo(
        host: 'fake.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const config = TrustedTimeConfig(ntpInventoryForTesting: [entry]);
      expect(config.ntpInventory, equals(const [entry]));
    });

    test('ntpInventoryForTesting empties ntpServers on its own', () {
      // Without this the curated 51 would still be built as live
      // NtpSources while eligibility keyed off the override -- real DNS
      // and UDP from a test, against sources the partition then lets
      // through unpartitioned for want of a matching inventory entry.
      const entry = NtpServerInfo(
        host: 'fake.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const config = TrustedTimeConfig(ntpInventoryForTesting: [entry]);
      expect(config.ntpServers, isEmpty);
      expect(config.ntpInventory, equals(const [entry]));
    });

    test('ntpInventoryForTesting survives disableNtpForTesting', () {
      // The override wins over the flag's empty inventory, so the
      // partition still has something to narrow. If the flag won, every
      // test pairing the two would silently take the "nothing to
      // narrow" branch and assert vacuously.
      //
      // The NTS pair resolves the opposite way — see 'disableNts
      // overrides ntsInventoryForTesting'. Both are test seams here, so
      // precedence is only a convenience; there the flag is a production
      // posture, so it has to be the final word.
      const entry = NtpServerInfo(
        host: 'fake.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const config = TrustedTimeConfig(
        disableNtpForTesting: true,
        ntpInventoryForTesting: [entry],
      );
      expect(config.ntpInventory, equals(const [entry]));
      // ntpServers is untouched, so no live source is built for it.
      expect(config.ntpServers, isEmpty);
    });

    test('ntpInventoryForTesting participates in equality and hashCode', () {
      const entry = NtpServerInfo(
        host: 'fake.test',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        observedGroupId: 'as1',
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const a = TrustedTimeConfig(ntpInventoryForTesting: [entry]);
      const b = TrustedTimeConfig(ntpInventoryForTesting: [entry]);
      const none = TrustedTimeConfig();

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(none)));
      expect(a.copyWith(ntpInventoryForTesting: const []), isNot(equals(a)));
    });

    test('an absent override is distinct from an empty one', () {
      // Absent means "use the curated inventory"; empty means "narrow
      // against nothing". Not interchangeable, so == must separate
      // them. Deliberately no hashCode assertion: unequal objects are
      // permitted to collide, and pinning the absence of a collision
      // would bind the test to the SDK's current hash mixing.
      const absent = TrustedTimeConfig();
      const empty = TrustedTimeConfig(ntpInventoryForTesting: []);

      expect(absent, isNot(equals(empty)));
      expect(absent.ntpInventory, same(curatedNtpInventory));
      expect(empty.ntpInventory, isEmpty);
    });

    test('NtpServerInfo compares by value', () {
      // The inventory is exported, so consumers can reasonably hold
      // entries in sets or compare them against a constructed
      // expectation.
      const a = NtpServerInfo(
        host: 'time.example',
        tier: TimeServerTier.anycast,
        observedStratum: 2,
        observedGroupId: 'as13335',
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const same = NtpServerInfo(
        host: 'time.example',
        tier: TimeServerTier.anycast,
        observedStratum: 2,
        observedGroupId: 'as13335',
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const differentStratum = NtpServerInfo(
        host: 'time.example',
        tier: TimeServerTier.anycast,
        observedStratum: 3,
        observedGroupId: 'as13335',
        leapPolicy: LeapPolicy.documentedStepping,
      );

      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(differentStratum));
      expect(a.toString(), contains('time.example'));
      expect(a.toString(), contains('stratum 2'));
    });

    test('ntsServers is the curated inventory', () {
      const config = TrustedTimeConfig();
      expect(config.ntsInventory, same(curatedNtsInventory));
      expect(config.ntsServers, hasLength(curatedNtsInventory.length));
    });

    test('ntsServers is the hostname view of ntsInventory', () {
      const config = TrustedTimeConfig();
      expect(
        config.ntsServers,
        config.ntsInventory.map((e) => e.host).toList(),
      );
    });

    test('ntsServers reuses the precomputed curated hostnames', () {
      // The getter is read on every engine cycle and on each isEmpty
      // gate (nts_bootstrap, supportsSecureTime), so the curated path
      // must not rebuild the list. Identity also pins that the getter
      // recognises the curated inventory rather than copying it.
      const config = TrustedTimeConfig();
      expect(config.ntsServers, same(curatedNtsHostnames));
    });

    test('ntsServers is unmodifiable on every path', () {
      // Matches ntpServers, which returns the unmodifiable curated
      // list or a const empty one.
      const curated = TrustedTimeConfig();
      const disabled = TrustedTimeConfig(disableNts: true);
      const overridden = TrustedTimeConfig(ntsInventoryForTesting: [_ntsEntry]);
      for (final servers in [
        curated.ntsServers,
        disabled.ntsServers,
        overridden.ntsServers,
      ]) {
        expect(() => servers.add('x'), throwsUnsupportedError);
      }
    });

    test('disableNts empties the NTS pool', () {
      const config = TrustedTimeConfig(disableNts: true);
      expect(config.ntsServers, isEmpty);
      expect(config.ntsInventory, isEmpty);
    });

    test('toString disambiguates an empty pool from a disable flag', () {
      // Both pools summarise to a count, and a zero has two causes: the
      // disable flag, or a seam supplying an empty inventory. The dump
      // has to carry the flags for the count to be readable.
      const disabled = TrustedTimeConfig(
        disableNts: true,
        disableNtpForTesting: true,
      );
      expect(disabled.toString(), contains('disableNts: true'));
      expect(disabled.toString(), contains('disableNtpForTesting: true'));

      const emptied = TrustedTimeConfig(
        ntsInventoryForTesting: [],
        ntpInventoryForTesting: [],
      );
      expect(emptied.ntsServers, isEmpty);
      expect(emptied.ntpServers, isEmpty);
      expect(emptied.toString(), contains('disableNts: false'));
      expect(emptied.toString(), contains('disableNtpForTesting: false'));
    });

    test('ntsInventoryForTesting replaces the inventory', () {
      const config = TrustedTimeConfig(ntsInventoryForTesting: [_ntsEntry]);
      expect(config.ntsInventory, equals(const [_ntsEntry]));
    });

    test('ntsInventoryForTesting still builds sources', () {
      // The NTS seam diverges from the NTP one: the y81 bootstrap-gate
      // regressions assert on whether ensureNtsRuntime ran, which is
      // gated on ntsServers being non-empty. An uninitialised NtsSource
      // throws per-source, so nothing reaches the network.
      const config = TrustedTimeConfig(ntsInventoryForTesting: [_ntsEntry]);
      expect(config.ntsServers, ['fake.nts.test']);
    });

    test('disableNts overrides ntsInventoryForTesting', () {
      // Diverges from the NTP pair, where the override wins over the
      // flag ('ntpInventoryForTesting survives disableNtpForTesting'
      // pins that direction). disableNts is what ensureNtsRuntime writes
      // when the FFI bootstrap fails, and no substitute inventory can
      // make a missing runtime work — so the flag has to be the final
      // word. That pair is two test seams; this one crosses into
      // production, which is what flips the precedence.
      const config = TrustedTimeConfig(
        disableNts: true,
        ntsInventoryForTesting: [_ntsEntry],
      );
      expect(config.ntsInventory, isEmpty);
      expect(config.ntsServers, isEmpty);
    });

    test('ntsInventoryForTesting participates in equality and hashCode', () {
      const a = TrustedTimeConfig(ntsInventoryForTesting: [_ntsEntry]);
      const b = TrustedTimeConfig(ntsInventoryForTesting: [_ntsEntry]);
      const none = TrustedTimeConfig();

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(none)));
      expect(a.copyWith(ntsInventoryForTesting: const []), isNot(equals(a)));
    });

    test('disableNts participates in equality', () {
      const on = TrustedTimeConfig(disableNts: true);
      const off = TrustedTimeConfig();
      expect(on, isNot(equals(off)));
      expect(on, equals(off.copyWith(disableNts: true)));
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

  // The query target is the number of NTS hosts a cycle *asks*; the
  // validity floor is the number that must *respond* for a truth box to
  // form. Keeping them apart is the point of the knob -- a target equal
  // to the floor means one timeout degrades the cycle. See ADR 0007's
  // 2026-08-02 postscript.
  group('TrustedTimeConfig ntsQueryTarget', () {
    test('defaults to 5, above the validity floor', () {
      const config = TrustedTimeConfig();
      expect(config.ntsQueryTarget, 5);
      expect(
        config.ntsQueryTarget,
        greaterThan(TrustedTimeConfig.minNtsQueryTarget),
        reason: 'the default must carry failure headroom, not sit on the floor',
      );
    });

    test('the floor is 3, one above the generic quorum minimum', () {
      // Three is the first size that sheds an outlier: at a ratio of 0.6
      // a 3-sample population needs an overlap of 2. At 2 the required
      // overlap is also 2, so both must agree. If these two constants
      // ever converge the floor stops meaning anything.
      expect(TrustedTimeConfig.minNtsQueryTarget, 3);
      expect(
        TrustedTimeConfig.minNtsQueryTarget,
        greaterThan(const TrustedTimeConfig().minimumQuorum),
      );
    });

    test('a target below the floor is rejected, not clamped', () {
      // Clamping would let a config that can never form a truth box run
      // as though it could.
      expect(
        () => TrustedTimeConfig(ntsQueryTarget: 2),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => TrustedTimeConfig(ntsQueryTarget: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a target equal to the floor is legal', () {
      // Documented as the narrowest legal cycle: it forms a box only
      // while every host answers. A metered or battery-critical install
      // may want it, so it must not be rejected alongside the values
      // below it.
      const config = TrustedTimeConfig(
        ntsQueryTarget: TrustedTimeConfig.minNtsQueryTarget,
      );
      expect(config.ntsQueryTarget, 3);
    });

    test('round-trips through copyWith', () {
      const original = TrustedTimeConfig();
      final updated = original.copyWith(ntsQueryTarget: 7);
      expect(updated.ntsQueryTarget, 7);
      // Purely additive: an omitted value preserves the existing one.
      final untouched = updated.copyWith(
        maxLatency: const Duration(seconds: 7),
      );
      expect(untouched.ntsQueryTarget, 7);
    });

    test('participates in equality and hashCode', () {
      const base = TrustedTimeConfig();
      const wide = TrustedTimeConfig(ntsQueryTarget: 7);
      expect(base == wide, isFalse);

      const a = TrustedTimeConfig(ntsQueryTarget: 7);
      const b = TrustedTimeConfig(ntsQueryTarget: 7);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('appears in toString output', () {
      const config = TrustedTimeConfig(ntsQueryTarget: 7);
      expect(config.toString(), contains('ntsQueryTarget: 7'));
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
