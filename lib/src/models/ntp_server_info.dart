import 'time_server_entry.dart';
import 'time_server_tier.dart';

/// One host in the library's curated plain-NTP inventory, with what a
/// live probe established about it.
///
/// See `curatedNtpInventory` for the list and its provenance.
class NtpServerInfo implements TimeServerEntry {
  /// Creates an inventory entry.
  const NtpServerInfo({
    required this.host,
    required this.tier,
    required this.observedStratum,
    required this.observedGroupId,
    required this.leapPolicy,
  });

  /// The hostname queried over plain NTP.
  @override
  final String host;

  /// Why the host is in the inventory and how it is reached.
  @override
  final TimeServerTier tier;

  /// The stratum reported during the verification probe.
  ///
  /// A single observation, and lower is not automatically better: a
  /// well-run stratum 2 on a short path routinely beats a distant
  /// stratum 1. Some hosts also report a stratum that disagrees with
  /// their [tier] — `time.windows.com` answered stratum 4 from the
  /// probe vantage — because the tier records the curation decision
  /// and this records the measurement.
  final int observedStratum;

  /// The autonomous system the host resolved into during the
  /// verification probe, in the `as13335` form `TimeSource.groupId`
  /// uses.
  ///
  /// Lets quorum-inflation risk be seen before any DNS happens: eleven
  /// inventory hosts share `as57021`, so a quorum drawn only from them
  /// carries one operator's opinion eleven times. Indicative only for
  /// [TimeServerTier.anycast] hosts, whose resolution is vantage
  /// dependent, and it can go stale for any host whose operator
  /// renumbers. The value the engine actually groups on is resolved at
  /// query time.
  final String observedGroupId;

  /// How firmly the host is established as stepping rather than
  /// smearing leap seconds.
  final LeapPolicy leapPolicy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NtpServerInfo &&
          other.host == host &&
          other.tier == tier &&
          other.observedStratum == observedStratum &&
          other.observedGroupId == observedGroupId &&
          other.leapPolicy == leapPolicy;

  @override
  int get hashCode =>
      Object.hash(host, tier, observedStratum, observedGroupId, leapPolicy);

  @override
  String toString() =>
      'NtpServerInfo($host, ${tier.name}, stratum $observedStratum, '
      '$observedGroupId, ${leapPolicy.name})';
}
