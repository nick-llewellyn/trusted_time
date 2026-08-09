import 'time_sample.dart';

/// Contract for implementing custom time-authority providers.
abstract interface class TimeSource {
  /// Prefix for Network Time Protocol (NTP) sources.
  static const String prefixNtp = 'ntp:';

  /// Prefix for Secure Network Time Protocol (NTS) sources.
  static const String prefixNts = 'nts:';

  /// A unique identifier for this source (e.g., 'ntp:time.google.com').
  String get id;

  /// A group identifier to detect correlated sources (e.g., 'google', 'cloudflare', 'pool.ntp.org').
  String get groupId;

  /// Queries the remote authority and returns a [TimeSample].
  Future<TimeSample> getTime();
}

/// Optional capability for [TimeSource]s that can return a sample the
/// consensus engine will classify as `verified`, declared up front so
/// the engine can decide whether a cycle is worth waiting for.
///
/// A cycle whose verified samples cannot form a truth box publishes a
/// degraded result. Before it does, the engine checks which of the
/// queries still in flight could yet lift it — and only sources that
/// implement this interface, and answer `true` from
/// [canProduceVerified], are counted. A source that stamps
/// `verified` on its samples without implementing this is admitted to
/// a truth box exactly as before; what it forgoes is having the cycle
/// wait for it, which costs the anchor its trust level when its reply
/// is the one that would have closed the box.
///
/// **Schedules a wait; never classifies a sample.** The engine reads
/// [canProduceVerified] only to choose between waiting and publishing.
/// The trust label is decided downstream, from what the sample itself
/// carries. Implementations must not read anything into being counted
/// here, and callers must not treat `true` as evidence about a sample.
///
/// Answer for the source's *capability*, not its last outcome: whether
/// any successful query could be classified verified, knowable before
/// one resolves. Over-claiming costs at most a wait that does not pay
/// off, bounded by the latency budget the query is already under.
/// Under-claiming costs the anchor its trust level, which no later
/// cycle recovers for a consumer already holding it. The result must
/// not vary across a cycle, or the engine's tally of what is
/// outstanding will not drain.
abstract interface class VerifiedCapable {
  /// Whether a successful query from this source could be classified
  /// as `verified`.
  bool get canProduceVerified;
}

/// Optional capability for [TimeSource]s that need a one-time setup
/// step (handshakes, key exchange, cache priming) which should
/// complete *outside* the per-query latency budget.
///
/// The engine type-checks each active source for this interface and
/// runs [warm] before the timed query phase. Sources that do not need
/// warming should not implement this; they will be queried directly.
///
/// Implementations should be idempotent and tolerate repeated
/// invocation. They must not throw; failures should be handled
/// internally so that [TimeSource.getTime] can still attempt a
/// cold-start query.
abstract interface class Warmable {
  /// Performs the source's one-time setup work.
  Future<void> warm();
}
