import 'time_server_tier.dart';

/// What the per-cycle partition needs to know about an inventory host,
/// whatever protocol will carry the query.
///
/// `NtpServerInfo` and `NtsServerInfo` each record more than this — an
/// observed stratum, a leap policy, and for NTP an observed autonomous
/// system. None of that participates in deciding which hosts a cycle
/// touches, so `partitionInventory` takes this narrower view and works
/// for either inventory unchanged.
///
/// Implemented by the inventory models rather than by callers: there
/// are exactly two inventories, both shipped by this package, and both
/// already carry these two fields.
abstract interface class TimeServerEntry {
  /// The hostname queried.
  String get host;

  /// Why the host is in the inventory and how it is reached.
  TimeServerTier get tier;
}
