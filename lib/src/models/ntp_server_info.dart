/// How a host is expected to reach the caller, and what role it plays
/// in a quorum.
///
/// The tier is a curation decision, not a measurement: it records why
/// a host is in the inventory, whereas [NtpServerInfo.observedStratum]
/// records what a single probe saw.
enum NtpServerTier {
  /// Anycast or DNS-steered: the address the caller reaches depends on
  /// where the caller is.
  ///
  /// Self-localizing, so these hosts need no per-install ranking and
  /// are cheap to query from anywhere. The corollary is that
  /// [NtpServerInfo.observedGroupId] for these hosts is only valid at
  /// the vantage that recorded it — a different network can resolve
  /// them into entirely different autonomous systems.
  anycast,

  /// A fixed unicast address whose upstream is a reference clock.
  unicastStratum1,

  /// A fixed unicast address one or more hops below a reference clock.
  unicastStratum2,
}

/// The strength of the evidence that a host steps leap seconds rather
/// than smearing them.
///
/// A smeared source diverges from stepping sources by up to a full
/// second around a leap event, so a mixed pool can be pulled off
/// consensus. No inventory host is a *documented smearer*; this enum
/// grades how firmly the opposite is established.
enum NtpLeapPolicy {
  /// The operator publishes that it steps.
  documentedStepping,

  /// No operator statement, but the host is run by a metrology
  /// institute, which the IETF NTP BCP requires not to smear.
  bcpStepping,

  /// No statement and no standards obligation. Stock `ntpd` and
  /// `chrony` step by default and smearing takes deliberate
  /// configuration that every known smearer has published, so
  /// stepping is the working assumption — not a guarantee.
  ///
  /// The runtime defence is the Marzullo intersection, which rejects a
  /// roughly one-second outlier whatever caused it.
  presumedStepping,
}

/// One host in the library's curated plain-NTP inventory, with what a
/// live probe established about it.
///
/// See `curatedNtpInventory` for the list and its provenance.
class NtpServerInfo {
  /// Creates an inventory entry.
  const NtpServerInfo({
    required this.host,
    required this.tier,
    required this.observedStratum,
    required this.observedGroupId,
    required this.leapPolicy,
  });

  /// The hostname queried over plain NTP.
  final String host;

  /// Why the host is in the inventory and how it is reached.
  final NtpServerTier tier;

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
  /// [NtpServerTier.anycast] hosts, whose resolution is vantage
  /// dependent, and it can go stale for any host whose operator
  /// renumbers. The value the engine actually groups on is resolved at
  /// query time.
  final String observedGroupId;

  /// How firmly the host is established as stepping rather than
  /// smearing leap seconds.
  final NtpLeapPolicy leapPolicy;

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
