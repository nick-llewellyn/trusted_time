// curatedNtsInventory and NtsServerInfo: the invariants the curation
// promised, pinned so a later edit to the list cannot quietly break
// them.
//
// The plain-NTP counterpart lives in trusted_time_config_test.dart,
// where the inventory is already reachable through the config. NTS is
// not wired into TrustedTimeConfig yet, so its invariants are asserted
// against the exported list directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/nts_inventory.dart';
import 'package:trusted_time/src/sources/registrable_domain.dart';
import 'package:trusted_time/trusted_time.dart';

void main() {
  group('curatedNtsInventory', () {
    test('is the 57 verified hosts', () {
      expect(curatedNtsInventory, hasLength(57));
    });

    test('curatedNtsHostnames is the hostname view, in order', () {
      // The engine queries by name; the metadata drives selection.
      // These two must not drift apart.
      expect(
        curatedNtsHostnames,
        curatedNtsInventory.map((e) => e.host).toList(),
      );
    });

    test('has no duplicate hosts', () {
      // A repeated host would inflate a quorum with one server's
      // opinion counted twice.
      expect(
        curatedNtsInventory.map((e) => e.host).toSet(),
        hasLength(curatedNtsInventory.length),
      );
    });

    test('excludes every documented smearing operator', () {
      // A smeared source diverges from stepping sources by up to a
      // full second around a leap event and can poison the consensus.
      //
      // Matched on registrable domain rather than substring: a bare
      // substring would reject an unrelated host that happens to
      // contain 'aws', and exact hostnames alone would admit a sibling
      // that smears for the same reason.
      const smearingDomains = ['google.com', 'aws.com', 'facebook.com'];
      for (final entry in curatedNtsInventory) {
        for (final domain in smearingDomains) {
          expect(
            entry.host == domain || entry.host.endsWith('.$domain'),
            isFalse,
            reason: '${entry.host} belongs to documented smearer $domain',
          );
        }
      }
    });

    test('the anycast core spans the tiers it claims', () {
      // The partition reads the tier: the anycast core is
      // self-localizing and always queried, the unicast hosts are the
      // explore pool.
      final byTier = <TimeServerTier, int>{};
      for (final entry in curatedNtsInventory) {
        byTier[entry.tier] = (byTier[entry.tier] ?? 0) + 1;
      }
      expect(byTier[TimeServerTier.anycast], 3);
      expect(byTier[TimeServerTier.unicastStratum1], 27);
      expect(byTier[TimeServerTier.unicastStratum2], 27);
    });

    test('the anycast tier alone spans three operators', () {
      // The blocking quorum is drawn from this tier, so it has to
      // satisfy minGroupCount on its own rather than leaning on
      // whichever explorers a cycle happens to pick.
      final groups = {
        for (final entry in curatedNtsInventory)
          if (entry.tier == TimeServerTier.anycast)
            registrableDomain(entry.host),
      };
      expect(groups, {'cloudflare.com', 'netnod.se', 'time.nl'});
    });

    test('is ordered by tier', () {
      // The list doubles as the order hosts are presented in, and the
      // library doc comment states the tier ordering.
      final tiers = curatedNtsInventory.map((e) => e.tier.index).toList();
      expect(tiers, orderedEquals(List.of(tiers)..sort()));
    });

    test('no group holds a majority of the inventory', () {
      // Grouping is the diversity accounting; one operator large
      // enough to outvote the rest would defeat it.
      final counts = <String, int>{};
      for (final entry in curatedNtsInventory) {
        final group = registrableDomain(entry.host);
        counts[group] = (counts[group] ?? 0) + 1;
      }
      expect(counts, hasLength(24));
      expect(counts['netnod.se'], 11);
      for (final MapEntry(key: group, value: count) in counts.entries) {
        expect(
          count * 2,
          lessThan(curatedNtsInventory.length),
          reason: '$group holds $count of the ${curatedNtsInventory.length}',
        );
      }
    });

    test('every observed stratum is plausible', () {
      // Zero is the NTP "unspecified/kiss-o-death" stratum and 16 is
      // "unsynchronized"; either would mean the probe recorded a host
      // that was not actually serving time.
      for (final entry in curatedNtsInventory) {
        expect(
          entry.observedStratum,
          inInclusiveRange(1, 15),
          reason: '${entry.host} recorded stratum ${entry.observedStratum}',
        );
      }
    });
  });

  group('NtsServerInfo', () {
    test('compares by value', () {
      // The inventory is exported, so consumers can reasonably hold
      // entries in sets or compare them against a constructed
      // expectation.
      const a = NtsServerInfo(
        host: 'time.example',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const same = NtsServerInfo(
        host: 'time.example',
        tier: TimeServerTier.anycast,
        observedStratum: 1,
        leapPolicy: LeapPolicy.documentedStepping,
      );
      const differentStratum = NtsServerInfo(
        host: 'time.example',
        tier: TimeServerTier.anycast,
        observedStratum: 2,
        leapPolicy: LeapPolicy.documentedStepping,
      );

      expect(a, equals(same));
      expect(a.hashCode, equals(same.hashCode));
      expect(a, isNot(equals(differentStratum)));
      expect(a.toString(), contains('time.example'));
      expect(a.toString(), contains('stratum 1'));
    });
  });
}
