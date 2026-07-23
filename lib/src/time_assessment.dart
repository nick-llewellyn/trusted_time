import 'models.dart';
import 'sources/nts_auth_level.dart';
import 'trusted_time_estimate.dart';

/// Why the engine reports its current trust posture.
///
/// Exactly one reason is active at any moment. The first two values are
/// the *anchored* postures ([TimeAssessment.time] is non-null); the rest
/// are *unanchored* postures (no usable trust anchor, [TimeAssessment.time]
/// is null and only [TimeAssessment.estimate] may be available).
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
  /// attempt has concluded yet (the first cycle may still be in
  /// flight). A concluded-but-failed first cycle transitions to
  /// [syncFailed].
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
  /// anchored postures carry [time], [uncertainty] and [anchorAge] but
  /// never [estimate]; unanchored postures carry none of those and
  /// report [NtsAuthLevel.none] / [ConfidenceLevel.none]; and
  /// [authLevel] is verified exactly when [reason] is
  /// [TrustStatusReason.synchronized].
  const TimeAssessment({
    required this.reason,
    required this.authLevel,
    required this.confidence,
    this.time,
    this.uncertainty,
    this.anchorAge,
    this.estimate,
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
         estimate == null || time == null,
         'estimate is a fallback for unanchored postures only; it must '
         'be null whenever time is available',
       ),
       assert(
         time != null || confidence == ConfidenceLevel.none,
         'unanchored postures must report ConfidenceLevel.none',
       );

  /// The trusted current UTC time, projected from the live anchor on
  /// the monotonic timeline — or `null` when no anchor exists (see
  /// [reason] for why, and [estimate] for a best-effort fallback).
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

  /// Half-width error bound on [time]: the anchor's consensus
  /// uncertainty plus modeled oscillator drift accumulated over
  /// [anchorAge]. `null` when [time] is null.
  final Duration? uncertainty;

  /// How long ago the live anchor was captured, measured on the same
  /// monotonic timeline that projects [time] — never wall-clock.
  /// `null` when no anchor exists.
  final Duration? anchorAge;

  /// Best-effort wall-clock extrapolation for unanchored postures.
  ///
  /// **Susceptible to wall-clock manipulation** — suitable only for
  /// non-critical UI hints. `null` when [time] is available (use
  /// [time]) or when the engine has no prior state to extrapolate from.
  final TrustedTimeEstimate? estimate;

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
      'uncertainty: $uncertainty, anchorAge: $anchorAge)';
}
