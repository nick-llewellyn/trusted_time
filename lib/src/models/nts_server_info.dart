import 'time_server_tier.dart';

/// One host in the library's curated NTS inventory, with what a live
/// probe established about it.
///
/// See `curatedNtsInventory` for the list and its provenance.
///
/// Deliberately narrower than `NtpServerInfo`, which also records the
/// autonomous system a probe resolved the host into. An NTS group is
/// the registrable domain of the hostname, which is derivable from
/// [host] alone and identical at every vantage, so recording it here
/// would store a value that can be computed rather than one that had
/// to be observed.
class NtsServerInfo {
  /// Creates an inventory entry.
  const NtsServerInfo({
    required this.host,
    required this.tier,
    required this.observedStratum,
    required this.leapPolicy,
  });

  /// The hostname queried over NTS.
  ///
  /// Also the operator identifier: NTS-KE binds the name to a TLS
  /// certificate, so the registrable domain of this string is a
  /// cryptographically backed group key rather than a heuristic.
  final String host;

  /// Why the host is in the inventory and how it is reached.
  final TimeServerTier tier;

  /// The stratum reported during the verification probe.
  ///
  /// A single observation, and lower is not automatically better: a
  /// well-run stratum 2 on a short path routinely beats a distant
  /// stratum 1. Some hosts also report a stratum that disagrees with
  /// their [tier] — `time.cloudflare.com` answered stratum 3 from the
  /// probe vantage — because the tier records the curation decision
  /// and this records the measurement.
  final int observedStratum;

  /// How firmly the host is established as stepping rather than
  /// smearing leap seconds.
  final LeapPolicy leapPolicy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NtsServerInfo &&
          other.host == host &&
          other.tier == tier &&
          other.observedStratum == observedStratum &&
          other.leapPolicy == leapPolicy;

  @override
  int get hashCode => Object.hash(host, tier, observedStratum, leapPolicy);

  @override
  String toString() =>
      'NtsServerInfo($host, ${tier.name}, stratum $observedStratum, '
      '${leapPolicy.name})';
}
