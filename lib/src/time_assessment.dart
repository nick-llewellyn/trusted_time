import 'models.dart';
import 'sources/nts_auth_level.dart';

/// Why the engine reports its current trust posture.
///
/// Exactly one reason is active at any moment. The first two values are
/// the *anchored* postures ([TimeAssessment.time] is non-null); the rest
/// are *unanchored* postures (no usable trust anchor,
/// [TimeAssessment.time] is null).
enum TrustStatusReason {
  /// A live trust anchor exists, established from Tier 1 verified
  /// consensus or warm-restored intact within the same boot session.
  synchronized,

  /// A live anchor exists, but it was established from a degraded
  /// (lower-tier / unauthenticated) consensus — NTS could not form a
  /// truth box and the engine fell back to NTP-grade agreement, or the
  /// anchor was validated under platform-mediated trust. Time is
  /// usable; cryptographic guarantees are not.
  degraded,

  /// Cold start: no usable persisted anchor was found and no sync
  /// attempt has concluded yet. Whether the first cycle is currently
  /// in flight is queryable via [TimeAssessment.syncInProgress]. A
  /// concluded-but-failed first cycle transitions to [syncFailed].
  neverSynced,

  /// A persisted anchor was found on warm start but discarded because
  /// the device rebooted since it was captured (boot-ID mismatch or
  /// uptime regression). Persists until the first successful sync.
  rebootDetected,

  /// The most recent sync cycle failed and no valid anchor survives,
  /// or trust was explicitly torn down (e.g. `forceResync`) and the
  /// rebuild has not succeeded yet. [rebootDetected] takes precedence:
  /// a failed sync after a detected reboot keeps reporting
  /// [rebootDetected] until a sync succeeds.
  syncFailed,
}

/// A single, self-consistent answer to "what time is it, why, and what
/// are the caveats?" — captured at one instant.
///
/// Returned by `TrustedTime.getAssessment()`. All fields describe the
/// same moment of evaluation; the object never updates in place, so
/// re-assess at meaningful boundaries (app start, foreground resume,
/// before a high-value operation) rather than caching one instance.
///
/// The class is deliberately normalized: there are no stored booleans
/// that could disagree with each other. Trust and security are derived:
///
/// * [isTrusted] ⟺ a live anchor exists ⟺ [time] is non-null.
/// * [isSecure] ⟺ [authLevel] is [NtsAuthLevel.verified].
final class TimeAssessment {
  /// Creates an assessment snapshot. Library-internal; consumers obtain
  /// instances from `TrustedTime.getAssessment()`.
  ///
  /// Asserts enforce the documented invariants so an internally
  /// inconsistent snapshot cannot be constructed in checked mode:
  /// anchored postures carry [time], [uncertainty] and [anchorAge];
  /// unanchored postures carry none of those and report
  /// [NtsAuthLevel.none] / [ConfidenceLevel.none]; [authLevel] is
  /// verified exactly when [reason] is
  /// [TrustStatusReason.synchronized]; and [driftRate] /
  /// [driftCorrectedTime] come as a pair, only on anchored postures.
  const TimeAssessment({
    required this.reason,
    required this.authLevel,
    required this.confidence,
    this.syncInProgress = false,
    this.time,
    this.uncertainty,
    this.anchorAge,
    this.driftRate,
    this.driftCorrectedTime,
  }) : assert(
         (time != null) ==
             (reason == TrustStatusReason.synchronized ||
                 reason == TrustStatusReason.degraded),
         'time must be present exactly when the reason is an anchored '
         'posture (synchronized or degraded)',
       ),
       assert(
         (authLevel == NtsAuthLevel.verified) ==
             (reason == TrustStatusReason.synchronized),
         'authLevel must be verified exactly when the reason is '
         'synchronized: a verified anchor is never reported as degraded, '
         'and degraded/unanchored postures are never verified',
       ),
       assert(
         (uncertainty != null) == (time != null),
         'uncertainty must be present exactly when time is',
       ),
       assert(
         (anchorAge != null) == (time != null),
         'anchorAge must be present exactly when time is',
       ),
       assert(
         (driftCorrectedTime != null) == (driftRate != null),
         'driftRate and driftCorrectedTime must be present together',
       ),
       assert(
         driftRate == null || time != null,
         'a drift rate can only exist on anchored postures (the '
         'reverse is not required: an anchored posture without a '
         'usable rate has both drift fields null)',
       ),
       assert(
         time != null || confidence == ConfidenceLevel.none,
         'unanchored postures must report ConfidenceLevel.none',
       );

  /// The trusted current UTC time, projected from the live anchor on
  /// the monotonic timeline — or `null` when no anchor exists (see
  /// [reason] for why).
  final DateTime? time;

  /// Why the assessment reports this posture.
  final TrustStatusReason reason;

  /// Cryptographic authentication level of the live anchor.
  ///
  /// [NtsAuthLevel.verified] only when the anchor was established from
  /// a Tier 1 NTS truth box validated against a library-controlled
  /// trust store; [NtsAuthLevel.none] otherwise (including all
  /// unanchored postures).
  final NtsAuthLevel authLevel;

  /// Qualitative confidence grade of the live anchor, or
  /// [ConfidenceLevel.none] when no anchor exists.
  final ConfidenceLevel confidence;

  /// Half-width error bound on [time]: the anchor's measured consensus
  /// uncertainty. It does not grow with [anchorAge] — apply your own
  /// staleness policy against [anchorAge] where that matters. `null`
  /// when [time] is null.
  final Duration? uncertainty;

  /// How long ago the live anchor was captured, measured on the same
  /// monotonic timeline that projects [time] — never wall-clock.
  /// `null` when no anchor exists.
  final Duration? anchorAge;

  /// The signed oscillator drift rate applied to [driftCorrectedTime].
  ///
  /// Observed passively within the **current boot session**: the drift
  /// of the device's uptime clock relative to network-consensus UTC,
  /// as `(dUptime - dNetworkUtc) / dNetworkUtc`. Positive means the
  /// device clock runs fast relative to network UTC; negative means it
  /// runs slow.
  ///
  /// `null` unless the current boot has accumulated at least one hour
  /// of observed span between its first and latest anchor — shorter
  /// windows are dominated by anchor noise. Prior boots' observations
  /// are never used for correction (they remain diagnostics via
  /// `TrustedTime.getDriftHistory()`). Always `null` on unanchored
  /// postures.
  final double? driftRate;

  /// [time] de-skewed by [driftRate]: `anchor + elapsed / (1 + rate)`.
  ///
  /// Experimental / diagnostic — [time] remains the primary answer.
  /// Derived from the same single monotonic read as [time], so both
  /// describe one instant. `null` exactly when [driftRate] is.
  ///
  /// Caveat: the rate is derived from kernel uptime, but the
  /// projection's elapsed reading rides the engine's SyncClock reader —
  /// the same kernel timeline when the sleep-aware bridge clock is
  /// available, but a suspend-frozen Stopwatch under the fallback,
  /// where applying a kernel-derived rate to process-relative elapsed
  /// time is slightly mismatched.
  final DateTime? driftCorrectedTime;

  /// Whether a sync cycle is in flight at the moment of assessment.
  ///
  /// True unconditionally whenever the engine is actively syncing: the
  /// first cycle after a cold start, a retry after failure, a scheduled
  /// background refresh, or a `forceResync` rebuild. It is an activity
  /// signal orthogonal to [reason]: it can be true while anchored (a
  /// routine refresh) and is **not** by itself a "something is wrong"
  /// indicator — do not wire UI (e.g. a spinner) directly to it in the
  /// anchored state, or every background refresh will flicker it.
  ///
  /// Unanchored + `syncInProgress` means a definitive answer is
  /// imminent — re-assess shortly rather than treating the posture as
  /// settled:
  ///
  /// ```dart
  /// final a = TrustedTime.getAssessment();
  /// if (!a.isTrusted && a.syncInProgress) {
  ///   // Resolution imminent — show a wait state, re-assess shortly
  ///   // (or await TrustedTime.firstSyncSettled).
  /// } else if (!a.isTrusted) {
  ///   // Concluded without trust — switch on a.reason.
  /// }
  /// ```
  ///
  /// This is the most perishable field on the snapshot: re-assess at
  /// meaningful boundaries, never cache.
  final bool syncInProgress;

  /// Whether a live trust anchor backs this assessment.
  ///
  /// Equivalent to `time != null`. True for [TrustStatusReason.synchronized]
  /// and [TrustStatusReason.degraded]; false otherwise.
  bool get isTrusted => time != null;

  /// Whether the anchor is cryptographically authenticated under the
  /// Secure Time Contract (RFC 8915 NTS, library-controlled roots).
  ///
  /// Equivalent to `authLevel == NtsAuthLevel.verified`.
  bool get isSecure => authLevel == NtsAuthLevel.verified;

  @override
  String toString() =>
      'TimeAssessment(reason: ${reason.name}, time: $time, '
      'authLevel: ${authLevel.name}, confidence: ${confidence.name}, '
      'uncertainty: $uncertainty, anchorAge: $anchorAge, '
      'driftRate: $driftRate, driftCorrectedTime: $driftCorrectedTime, '
      'syncInProgress: $syncInProgress)';
}
