import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/ntp_inventory.dart';
import 'package:trusted_time/src/domain/explorer_shuffle.dart';
import 'package:trusted_time/src/domain/inventory_partition.dart';
import 'package:trusted_time/src/models/ntp_server_info.dart';

NtpServerInfo _entry(String host, NtpServerTier tier) => NtpServerInfo(
  host: host,
  tier: tier,
  observedStratum: 2,
  observedGroupId: 'as1',
  leapPolicy: NtpLeapPolicy.presumedStepping,
);

/// Ten unicast candidates plus two anycast, enough to see a budget bite.
List<NtpServerInfo> _inventory({int unicast = 10, int anycast = 2}) => [
  for (var i = 0; i < anycast; i++) _entry('any$i.test', NtpServerTier.anycast),
  for (var i = 0; i < unicast; i++)
    _entry('uni$i.test', NtpServerTier.unicastStratum2),
];

InventoryPartition _partition({
  List<NtpServerInfo>? inventory,
  ExplorerShuffle shuffle = const ExplorerShuffle(4242),
  int budget = 3,
  Map<String, int> probed = const {},
}) => partitionInventory(
  inventory: inventory ?? _inventory(),
  shuffle: shuffle,
  explorerBudget: budget,
  lastProbedUtcMs: (host) => probed[host],
);

void main() {
  group('partitionInventory quorum', () {
    test('is every anycast host, and only those', () {
      final p = _partition();
      expect(p.quorum, equals(['any0.test', 'any1.test']));
    });

    test('is unaffected by the explorer budget', () {
      expect(_partition(budget: 0).quorum, hasLength(2));
      expect(_partition(budget: 99).quorum, hasLength(2));
    });

    test('keeps inventory order so the always-queried set is stable', () {
      const a = ExplorerShuffle(1);
      const b = ExplorerShuffle(2);
      expect(
        _partition(shuffle: a).quorum,
        equals(_partition(shuffle: b).quorum),
      );
    });
  });

  group('partitionInventory explorers', () {
    test('are unicast only, never a quorum host', () {
      final p = _partition(budget: 99);
      expect(p.explorers.any((h) => h.startsWith('any')), isFalse);
      expect(p.explorers, hasLength(10));
    });

    test('are capped at the budget', () {
      expect(_partition(budget: 3).explorers, hasLength(3));
      expect(_partition(budget: 1).explorers, hasLength(1));
    });

    test('a non-positive budget yields a quorum-only cycle', () {
      expect(_partition(budget: 0).explorers, isEmpty);
      expect(_partition(budget: -1).explorers, isEmpty);
    });

    test('a budget beyond the pool takes the pool, not more', () {
      expect(_partition(budget: 500).explorers, hasLength(10));
    });

    test('differ between installs on the first cycle', () {
      // The privacy claim: two installs with no probe history must not
      // walk the same prefix. Same inputs, different seed only.
      final a = _partition(shuffle: const ExplorerShuffle(11));
      final b = _partition(shuffle: const ExplorerShuffle(22));
      expect(a.explorers, isNot(equals(b.explorers)));
    });

    test('are stable for one install given unchanged staleness', () {
      expect(_partition().explorers, equals(_partition().explorers));
    });
  });

  group('partitionInventory staleness ordering', () {
    test('never-probed hosts are taken before any probed host', () {
      // Nine of ten probed recently; the tenth must be picked first.
      final probed = {for (var i = 0; i < 9; i++) 'uni$i.test': 1000 + i};
      final p = _partition(budget: 1, probed: probed);
      expect(p.explorers, equals(['uni9.test']));
    });

    test('among probed hosts, the stalest goes first', () {
      final probed = {for (var i = 0; i < 10; i++) 'uni$i.test': 5000 - i};
      // uni9 has the smallest timestamp, so it is stalest.
      final p = _partition(budget: 2, probed: probed);
      expect(p.explorers, equals(['uni9.test', 'uni8.test']));
    });

    test('probing rotates the selection: the walk starves nothing', () {
      // Simulate cycles, stamping each explorer as probed. Every host
      // must be reached before any is repeated.
      final probed = <String, int>{};
      final seen = <String>[];
      var clock = 1;
      for (var cycle = 0; cycle < 5; cycle++) {
        final p = _partition(budget: 2, probed: probed);
        for (final host in p.explorers) {
          seen.add(host);
          probed[host] = clock++;
        }
      }
      expect(seen, hasLength(10));
      expect(seen.toSet(), hasLength(10));
    });
  });

  group('partitionInventory edge cases', () {
    test('an empty inventory yields an empty partition', () {
      final p = _partition(inventory: const []);
      expect(p.quorum, isEmpty);
      expect(p.explorers, isEmpty);
    });

    test('an all-anycast inventory yields no explorers', () {
      final p = _partition(inventory: _inventory(unicast: 0));
      expect(p.quorum, hasLength(2));
      expect(p.explorers, isEmpty);
    });

    test('an all-unicast inventory yields no quorum', () {
      final p = _partition(inventory: _inventory(anycast: 0), budget: 99);
      expect(p.quorum, isEmpty);
      expect(p.explorers, hasLength(10));
    });

    test('stratum 1 and 2 unicast both explore', () {
      final p = _partition(
        inventory: [
          _entry('s1.test', NtpServerTier.unicastStratum1),
          _entry('s2.test', NtpServerTier.unicastStratum2),
        ],
        budget: 99,
      );
      expect(p.explorers.toSet(), equals({'s1.test', 's2.test'}));
    });
  });

  group('partitionInventory against the shipped inventory', () {
    test('splits the curated 51 hosts into 10 quorum / 41 explorable', () {
      final p = partitionInventory(
        inventory: curatedNtpInventory,
        shuffle: const ExplorerShuffle(7),
        explorerBudget: 1000,
        lastProbedUtcMs: (_) => null,
      );
      expect(p.quorum, hasLength(10));
      expect(p.explorers, hasLength(41));
      expect(p.all.toSet(), hasLength(51));
    });

    test('a budgeted cycle queries far fewer than the full pool', () {
      final p = partitionInventory(
        inventory: curatedNtpInventory,
        shuffle: const ExplorerShuffle(7),
        explorerBudget: 5,
        lastProbedUtcMs: (_) => null,
      );
      expect(p.all, hasLength(15));
    });
  });

  group('InventoryPartition', () {
    test('all is quorum then explorers', () {
      final p = _partition(budget: 2);
      expect(p.all, equals([...p.quorum, ...p.explorers]));
    });

    test('value equality', () {
      expect(_partition(), equals(_partition()));
      expect(_partition().hashCode, equals(_partition().hashCode));
      expect(_partition(budget: 1), isNot(equals(_partition(budget: 2))));
    });

    test('toString reports the two counts', () {
      expect(
        _partition(budget: 3).toString(),
        equals('InventoryPartition(quorum: 2, explorers: 3)'),
      );
    });
  });
}
