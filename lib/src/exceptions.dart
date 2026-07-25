/// Thrown when accessing [TrustedTime.now] before a successful sync has
/// established a trust anchor.
///
/// This typically means [TrustedTime.initialize] has not been awaited, or
/// the initial network sync failed.
final class TrustedTimeNotReadyException implements Exception {
  /// Creates a [TrustedTimeNotReadyException].
  const TrustedTimeNotReadyException();

  @override
  String toString() =>
      'TrustedTime is not yet trusted. '
      'Await initialize() and ensure sync succeeded.';
}

/// Thrown when the sync engine cannot produce a trust anchor.
///
/// Most instances are network weather — the device is completely offline,
/// all configured servers are unreachable, network latency exceeds the
/// configured [TrustedTimeConfig.maxLatency], or quorum is not reached —
/// and carry [transient] `true`. The engine also raises this type for
/// failures that recur identically on every attempt (e.g. an empty source
/// configuration); those carry [transient] `false` so retry schedulers
/// know not to re-attempt them.
final class TrustedTimeSyncException implements Exception {
  /// Creates a [TrustedTimeSyncException] with a descriptive [message].
  const TrustedTimeSyncException(this.message, {this.transient = true});

  /// Human-readable description of why consensus failed.
  final String message;

  /// Whether a retry can plausibly recover from this failure.
  ///
  /// `true` (the default) for conditions that can clear between attempts:
  /// quorum not reached, sync timeout, all sources in exponential cooldown.
  /// `false` for failures that are structural — an empty source
  /// configuration, a consensus result with no participant samples — and
  /// would fail identically on every attempt. Consumed by
  /// `isTransientSyncError`, the shared verdict used by the foreground
  /// retry scheduler and the background in-run retry loop.
  final bool transient;

  @override
  String toString() => 'TrustedTimeSyncException: $message';
}

/// Thrown when [TrustedTime.trustedLocalTimeIn] is called with an IANA
/// timezone identifier that does not exist in the embedded database.
///
/// Example invalid identifiers: `'Mars/Elon_City'`, `'UTC+5'`.
final class UnknownTimezoneException implements Exception {
  /// Creates an [UnknownTimezoneException] for the given [identifier].
  const UnknownTimezoneException(this.identifier);

  /// The unrecognized IANA timezone identifier.
  final String identifier;

  @override
  String toString() => 'Unknown timezone: $identifier';
}

/// Thrown when a secure time query is requested but the engine cannot provide
/// cryptographically authenticated time (e.g. NTS failed).
final class TrustedTimeSecurityException implements Exception {
  /// Creates a [TrustedTimeSecurityException] with a descriptive [message].
  const TrustedTimeSecurityException(this.message);

  /// Human-readable description of the security requirement violation.
  final String message;
  @override
  String toString() => 'TrustedTimeSecurityException: $message';
}

/// Thrown when local state restoration or persistence fails.
final class TrustedTimePersistenceException implements Exception {
  /// Creates a [TrustedTimePersistenceException] with a descriptive [message].
  const TrustedTimePersistenceException(this.message);

  /// Human-readable description of the persistence error.
  final String message;
  @override
  String toString() => 'TrustedTimePersistenceException: $message';
}

/// Thrown by a `TimeSource` to signal that the failure was transient
/// and the source should be retried immediately on the next sync
/// cycle without the exponential cooldown a regular failure would arm.
///
/// Example: an `NtsSource` whose `ntsQuery` returned
/// `NtsError.timeout(TimeoutPhase.dnsSaturation)` because the bounded
/// DNS resolver pool was momentarily full. The host itself is healthy;
/// the next cycle will probably succeed once peers release their
/// resolver slots, so blacklisting the source for minutes would be
/// incorrect.
///
/// **Sustained-streak escalation:** the cooldown bypass applies only
/// to the immediate per-event retry. A source that throws
/// `TransientSourceError` on every consecutive cycle is escalated
/// onto the regular cooldown ladder once the consecutive-failure
/// streak reaches `TrustedTimeConfig.transientStreakThreshold`
/// (default 5). The streak counter resets on a successful query, on a
/// regular (non-transient) failure, and on each escalation. Set
/// `transientStreakThreshold` to `0` (or any non-positive value) to
/// disable the escalation guard and preserve the legacy retry-forever
/// behaviour. UI code that surfaces the no-cooldown tag should treat
/// it as describing the per-event classification, not a guarantee
/// that the source can never transition into cooldown.
final class TransientSourceError implements Exception {
  /// Creates a [TransientSourceError] wrapping the underlying [cause].
  const TransientSourceError(this.cause);

  /// The original error that the source classified as transient.
  final Object cause;

  @override
  String toString() => 'TransientSourceError: $cause';
}
