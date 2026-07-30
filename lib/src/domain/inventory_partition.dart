import 'package:flutter/foundation.dart';

import '../models/ntp_server_info.dart';
import 'explorer_shuffle.dart';

/// The hosts one sync cycle queries, split by the role they play.
///
/// See [partitionInventory] for how the split is derived.
@immutable
final class InventoryPartition {
  /// Creates a partition; normally obtained from [partitionInventory].
  const InventoryPartition({required this.quorum, required this.explorers});

  /// Self-localizing hosts queried every cycle.
  ///
  /// These build the anchor, so early-exit applies to them as it always
  /// has.
  final List<String> quorum;

  /// Unicast hosts probed this cycle to refine the ranking.
  ///
  /// A prefix of this install's walk over the stale end of the
  /// inventory, so the set differs from cycle to cycle and between
  /// installs.
  final List<String> explorers;

  /// Every host this cycle queries, quorum first.
  List<String> get all => [...quorum, ...explorers];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InventoryPartition &&
          listEquals(other.quorum, quorum) &&
          listEquals(other.explorers, explorers);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(quorum), Object.hashAll(explorers));

  @override
  String toString() =>
      'InventoryPartition(quorum: ${quorum.length}, '
      'explorers: ${explorers.length})';
}

/// Splits [inventory] into the hosts one cycle queries.
///
/// [NtpServerTier.anycast] hosts become the quorum: they are
/// DNS-steered or anycast, so they resolve to something near the caller
/// from any vantage and need no per-install ranking. Querying all of
/// them every cycle is what makes day-one time quality independent of
/// how far the unicast ranking has converged.
///
/// The unicast hosts are the explorer pool, and only [explorerBudget]
/// of them are probed per cycle — sweeping all of them every cycle is
/// the cost this partition exists to avoid.
///
/// ## Which explorers, and why staleness rather than a cursor
///
/// Candidates are ordered by how long it has been since each was
/// probed, never-probed first, with [shuffle] breaking ties. Staleness
/// is read from [lastProbedUtcMs], which returns the persisted
/// per-source timestamp (or `null` for a host with no recorded probe).
///
/// Using staleness as the cursor rather than carrying a walk position
/// means the traversal survives process death without persisting
/// anything new: the timestamps are already durable, and a host that
/// was skipped keeps rising through the ordering until it is probed.
/// A stored index would instead have to be written every cycle and
/// would reset the walk to a fixed prefix whenever it was lost — the
/// re-anchoring failure that motivated persisting the seed.
///
/// This also gives the starvation guarantee structurally: probing a
/// host resets it to the freshest end of the ordering, so it cannot be
/// selected again until every staler host has been. The shuffle
/// reorders the walk; it exempts nothing from it.
///
/// A non-positive [explorerBudget] yields quorum-only cycles.
InventoryPartition partitionInventory({
  required List<NtpServerInfo> inventory,
  required ExplorerShuffle shuffle,
  required int explorerBudget,
  required int? Function(String host) lastProbedUtcMs,
}) {
  final quorum = <String>[];
  final candidates = <String>[];
  for (final entry in inventory) {
    switch (entry.tier) {
      case NtpServerTier.anycast:
        quorum.add(entry.host);
      case NtpServerTier.unicastStratum1:
      case NtpServerTier.unicastStratum2:
        candidates.add(entry.host);
    }
  }

  if (explorerBudget <= 0 || candidates.isEmpty) {
    return InventoryPartition(quorum: quorum, explorers: const []);
  }

  // Walk order first, so the shuffle — not inventory order — is what
  // breaks staleness ties. Sorting the inventory-ordered list directly
  // would leave equally-stale hosts (notably the all-null first cycle)
  // in the shared listing order, which is the shared-constant walk the
  // shuffle exists to avoid.
  final walk = shuffle.apply(candidates);
  // Decorate with the walk index so the comparator can fall back to it
  // and stay total. List.sort is not stable, so relying on the input
  // order for equal keys would let the all-null first cycle come out in
  // an unspecified order.
  final ranked =
      [
        for (var i = 0; i < walk.length; i++)
          (host: walk[i], walkIndex: i, probedAt: lastProbedUtcMs(walk[i])),
      ]..sort((a, b) {
        final pa = a.probedAt;
        final pb = b.probedAt;
        // Never probed sorts ahead of everything probed.
        if (pa == null && pb != null) return -1;
        if (pa != null && pb == null) return 1;
        if (pa != null && pb != null && pa != pb) return pa.compareTo(pb);
        return a.walkIndex.compareTo(b.walkIndex);
      });

  return InventoryPartition(
    quorum: quorum,
    explorers: [for (final entry in ranked.take(explorerBudget)) entry.host],
  );
}
