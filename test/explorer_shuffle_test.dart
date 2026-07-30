import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/explorer_shuffle.dart';

void main() {
  group('ExplorerShuffle.order', () {
    test('is a permutation: every index exactly once', () {
      const shuffle = ExplorerShuffle(12345);
      final order = shuffle.order(51);
      expect(order, hasLength(51));
      expect(order.toSet(), hasLength(51));
      expect(order.every((i) => i >= 0 && i < 51), isTrue);
    });

    test('is stable across calls for one seed', () {
      const shuffle = ExplorerShuffle(999);
      expect(shuffle.order(51), equals(shuffle.order(51)));
    });

    test('is reproducible from a restored seed', () {
      // The durability guarantee stated on the type: an install that
      // dies and reloads its seed resumes the same walk, rather than
      // re-anchoring to a fresh permutation prefix.
      const before = ExplorerShuffle(4242);
      final restored = ExplorerShuffle(before.seed);
      expect(restored.order(51), equals(before.order(51)));
    });

    test('differs between seeds', () {
      // The privacy property: two installs must not walk the inventory
      // in the same order, or an observer can place a device at a known
      // offset in a known list.
      const a = ExplorerShuffle(1);
      const b = ExplorerShuffle(2);
      expect(a.order(51), isNot(equals(b.order(51))));
    });

    test('does not exempt any entry from the walk', () {
      // Starvation and staleness guarantees are unchanged by the
      // shuffle: it reorders, it does not drop.
      for (var seed = 0; seed < 20; seed++) {
        final order = ExplorerShuffle(seed).order(51);
        expect(
          order.toSet(),
          hasLength(51),
          reason: 'seed $seed dropped an entry',
        );
      }
    });

    test('returns a growable list at every length', () {
      // An unmodifiable empty list would make mutation fail only on
      // the degenerate length, which is the case a caller is least
      // likely to exercise before shipping.
      const shuffle = ExplorerShuffle(7);
      for (final length in [-1, 0, 1, 51]) {
        expect(
          () => shuffle.order(length).add(99),
          returnsNormally,
          reason: 'length $length',
        );
      }
    });

    test('handles degenerate lengths', () {
      const shuffle = ExplorerShuffle(7);
      expect(shuffle.order(0), isEmpty);
      expect(shuffle.order(-1), isEmpty);
      expect(shuffle.order(1), equals([0]));
    });
  });

  group('ExplorerShuffle.apply', () {
    test('returns the same elements in walk order', () {
      const shuffle = ExplorerShuffle(31337);
      final items = [for (var i = 0; i < 51; i++) 'host$i'];
      final walked = shuffle.apply(items);
      expect(walked, hasLength(items.length));
      expect(walked.toSet(), equals(items.toSet()));
      expect(walked, equals([for (final i in shuffle.order(51)) items[i]]));
    });

    test('returns empty for an empty input', () {
      expect(const ExplorerShuffle(1).apply(<String>[]), isEmpty);
    });
  });

  group('ExplorerShuffle.generate', () {
    test('draws the seed from the supplied generator', () {
      final shuffle = ExplorerShuffle.generate(random: Random(5));
      expect(shuffle.seed, equals(Random(5).nextInt(1 << 32)));
    });

    test('produces a seed inside the JSON-safe integer range', () {
      // Above 2^53 a JSON round trip would silently round the seed on
      // the web, so a reloaded install would walk a different order
      // than the one it persisted.
      for (var i = 0; i < 50; i++) {
        final seed = ExplorerShuffle.generate().seed;
        expect(seed, greaterThanOrEqualTo(0));
        expect(seed, lessThan(ExplorerShuffle.seedBound));
      }
    });

    test('every generated seed passes isValidSeed', () {
      // The store rejects seeds failing isValidSeed, so a generator
      // that could emit one would make installs discard their own
      // freshly minted walk order on the next load.
      for (var i = 0; i < 50; i++) {
        expect(
          ExplorerShuffle.isValidSeed(ExplorerShuffle.generate().seed),
          isTrue,
        );
      }
    });
  });

  group('ExplorerShuffle.isValidSeed', () {
    test('accepts the generated range inclusive of its lower bound', () {
      expect(ExplorerShuffle.isValidSeed(0), isTrue);
      expect(ExplorerShuffle.isValidSeed(1), isTrue);
      expect(
        ExplorerShuffle.isValidSeed(ExplorerShuffle.seedBound - 1),
        isTrue,
      );
    });

    test('rejects negative and out-of-range seeds', () {
      // Random consumes only the low bits and does not specify how it
      // reduces values outside the range, so accepting these would let
      // one install walk differently on the VM than on the web.
      expect(ExplorerShuffle.isValidSeed(-1), isFalse);
      expect(ExplorerShuffle.isValidSeed(ExplorerShuffle.seedBound), isFalse);
      expect(
        ExplorerShuffle.isValidSeed(ExplorerShuffle.seedBound + 1),
        isFalse,
      );
    });

    test('does not return a constant', () {
      // A degenerate CSPRNG draw would collapse every install onto one
      // walk order, which is the shared-constant case the shuffle
      // exists to avoid. Sampling repeatedly makes a fixed generator
      // observable without asserting on any single draw.
      final seeds = {
        for (var i = 0; i < 50; i++) ExplorerShuffle.generate().seed,
      };
      expect(seeds.length, greaterThan(1));
    });
  });

  group('ExplorerShuffle value semantics', () {
    test('equal seeds compare equal and hash alike', () {
      expect(const ExplorerShuffle(8), equals(const ExplorerShuffle(8)));
      expect(
        const ExplorerShuffle(8).hashCode,
        equals(const ExplorerShuffle(8).hashCode),
      );
    });

    test('different seeds compare unequal', () {
      expect(const ExplorerShuffle(8), isNot(equals(const ExplorerShuffle(9))));
    });

    test('toString names the seed', () {
      expect(const ExplorerShuffle(8).toString(), contains('8'));
    });
  });
}
