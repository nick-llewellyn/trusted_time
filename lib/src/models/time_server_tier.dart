/// How a host is expected to reach the caller, and what role it plays
/// in a quorum.
///
/// The tier is a curation decision, not a measurement: it records why
/// a host is in an inventory, whereas an observed stratum records what
/// a single probe saw.
///
/// Protocol-agnostic. Both the plain-NTP and the NTS inventories
/// classify their hosts on the same three-way split, and the per-cycle
/// partition reads the tier without caring which protocol will carry
/// the query.
enum TimeServerTier {
  /// Anycast or DNS-steered: the address the caller reaches depends on
  /// where the caller is.
  ///
  /// Self-localizing, so these hosts need no per-install ranking and
  /// are cheap to query from anywhere. The corollary is that any
  /// autonomous system recorded against such a host is only valid at
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
enum LeapPolicy {
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
