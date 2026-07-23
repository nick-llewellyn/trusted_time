import 'package:flutter/foundation.dart';

/// ## Absolute Top Tier: Temporal Integrity Forensics
///
/// [TamperReason] enumerates the exhaustive set of violations that can
/// compromise the temporal baseline of the engine.
enum TamperReason {
  /// A hardware reboot was detected via monotonic uptime reset.
  ///
  /// Reboots invalidate the current hardware anchor and require a fresh
  /// network synchronization to re-establish absolute truth. The
  /// production engine does not emit this reason on `onIntegrityLost` —
  /// a reboot always ends the process and is detected during
  /// `initialize()`, so it is expressed through state (`isTrusted`
  /// stays `false`) instead. Reserved for test doubles and diagnostics.
  deviceRebooted,

  /// A synchronization cycle could not establish a Tier 1 (cryptographically
  /// verified) truth box and fell back to a best-effort, single-tier
  /// consensus.
  ///
  /// The published anchor is still usable for `requireSecure: false`
  /// consumers, but its [IntegrityEvent.reason] signals that the time is no
  /// longer anchored by a library-controlled trust store. Emitted by the
  /// engine whenever the `NtsAuthLevel.verified` samples cannot form a truth
  /// box — either too few are present, or those present are too divergent to
  /// reach a Marzullo quorum (see the tiered-trust design, section 4.2). The
  /// resulting anchor reports `NtsAuthLevel.none`.
  degradedTier,

  /// A manual resynchronization was triggered.
  ///
  /// Reserved for consumer-side auditing or mock-based security testing.
  forcedNtpSync,

  /// The root cause could not be determined from available platform signals.
  unknown,
}

/// Encapsulates a violation of temporal integrity with forensic metadata.
///
/// [IntegrityEvent]s are emitted whenever the integrity monitor detects
/// a discrepancy that invalidates the current [TrustAnchor].
///
/// Use this for security auditing and to trigger high-priority recovery
/// workflows in your application.
@immutable
final class IntegrityEvent {
  /// Creates a magnificent integrity event.
  const IntegrityEvent({
    required this.reason,
    required this.detectedAt,
    this.drift,
  });

  /// The root cause identified by the integrity monitoring subsystem.
  final TamperReason reason;

  /// The UTC timestamp of when the violation was detected.
  final DateTime detectedAt;

  /// The measured magnitude of the clock discrepancy, if available.
  final Duration? drift;

  @override
  String toString() =>
      'IntegrityEvent(reason: $reason, drift: $drift, at: $detectedAt)';
}
