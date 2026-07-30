import 'dart:math';

import 'package:flutter/foundation.dart';

/// A per-install permutation of the explorer walk over the curated
/// inventory.
///
/// The library probes only a few exploratory hosts per sync cycle, so
/// the order in which it walks the inventory is observable: a
/// local-network, ISP, or on-path observer sees a handful of
/// destinations per cycle and nothing else. If every install walked the
/// inventory in the same order, three consecutive probes would place a
/// device at a known offset in a known list — a join key that links
/// cycles to each other and devices to each other. A per-install order
/// makes the same three probes say nothing beyond "this device uses
/// this library".
///
/// The seed is generated once at first init from [Random.secure] and
/// persisted, never derived from anything device-identifying: a seed
/// derived from an install id, advertising id, or hardware address
/// would reintroduce exactly the correlation the shuffle removes, and
/// would additionally let an observer who learns the derivation
/// recover the identifier from the observed order.
///
/// [order] is a pure function of the seed and the input length, so the
/// same install produces the same walk across process restarts. That
/// is the point: a seed regenerated per process would re-anchor every
/// restart to the same permutation prefix, and a device that restarts
/// often would leak the prefix repeatedly.
///
/// The shuffle reorders the walk; it does not exempt any entry from it.
/// Starvation and staleness guarantees are the caller's, and are
/// unaffected.
@immutable
final class ExplorerShuffle {
  /// Wraps an existing [seed], normally one loaded from storage.
  const ExplorerShuffle(this.seed);

  /// Generates a fresh seed from [Random.secure].
  ///
  /// [random] is a test seam; production leaves it null and gets the
  /// platform CSPRNG. A predictable generator here would make the walk
  /// order predictable across installs, collapsing the shuffle back to
  /// the shared-constant case it exists to avoid.
  factory ExplorerShuffle.generate({Random? random}) =>
      ExplorerShuffle((random ?? Random.secure()).nextInt(seedBound));

  /// Upper bound (exclusive) for a seed.
  ///
  /// Inside the 32-bit range `Random.nextInt` accepts, which is also
  /// well within the 53-bit integers a JSON round trip preserves
  /// exactly on the web's double-backed ints.
  static const int seedBound = 1 << 32;

  /// Whether [seed] lies in the range this type generates.
  ///
  /// `Random` consumes only the low bits of its seed and does not
  /// specify how it reduces values outside that range, so a seed from
  /// elsewhere — a corrupt store, an older key format — could produce
  /// a different walk on the VM than on the web. Callers reading a
  /// seed they did not generate should reject rather than normalize:
  /// a rejected seed costs one install its accumulated walk order,
  /// while a silently normalized one is a walk order that changes
  /// under the install when it moves platforms.
  static bool isValidSeed(int seed) => seed >= 0 && seed < seedBound;

  /// The persisted per-install seed.
  final int seed;

  /// Returns the indices `0..length-1` in this install's walk order.
  ///
  /// Deterministic for a given [seed] and [length]. Returns an empty
  /// list for a non-positive [length].
  List<int> order(int length) {
    if (length <= 0) return const [];
    final indices = [for (var i = 0; i < length; i++) i];
    // Fisher–Yates driven by a seeded generator: uniform over
    // permutations, and reproducible because the generator is
    // re-created from the stored seed on every call rather than
    // carried as mutable state.
    final rng = Random(seed);
    for (var i = length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = indices[i];
      indices[i] = indices[j];
      indices[j] = tmp;
    }
    return indices;
  }

  /// Returns [items] in this install's walk order.
  List<T> apply<T>(List<T> items) => [
    for (final i in order(items.length)) items[i],
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ExplorerShuffle && other.seed == seed;

  @override
  int get hashCode => seed.hashCode;

  @override
  String toString() => 'ExplorerShuffle($seed)';
}
