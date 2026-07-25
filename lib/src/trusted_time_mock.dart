import '../trusted_time.dart';

/// The global test override for [TrustedTime] (internal use only).
TrustedTimeMock? testOverride;

/// Sets the global test override for [TrustedTime] (internal use only).
void setTestOverride(TrustedTimeMock? mock) => testOverride = mock;

/// High-fidelity test double for deterministic temporal testing.
///
/// Provides a fully controllable virtual clock that simulates the
/// TrustedTime assessment API — trust posture and time advancement.
///
/// ```dart
/// final mock = TrustedTimeMock(initial: DateTime.utc(2024, 1, 1));
/// TrustedTime.overrideForTesting(mock);
///
/// expect(TrustedTime.getAssessment().time, DateTime.utc(2024, 1, 1));
///
/// mock.advanceTime(const Duration(hours: 1));
/// expect(TrustedTime.getAssessment().time, DateTime.utc(2024, 1, 1, 1));
///
/// TrustedTime.resetOverride();
/// ```
final class TrustedTimeMock {
  /// Creates a new mock with an initial UTC timestamp.
  TrustedTimeMock({required DateTime initial})
    : _now = initial.toUtc(),
      _trusted = true;

  DateTime _now;
  bool _trusted;
  NtsAuthLevel _authLevel = NtsAuthLevel.none;
  ConfidenceLevel _confidence = ConfidenceLevel.high;
  TrustStatusReason _unanchoredReason = TrustStatusReason.syncFailed;
  bool _syncInProgress = false;

  /// The scripted current time of the mock.
  DateTime get now => _now;

  /// Whether the mock is currently in a trusted state.
  bool get isTrusted => _trusted;

  /// Advances the mock time by the given duration.
  void advanceTime(Duration delta) => _now = _now.add(delta);

  /// Sets the mock time to the specified UTC [DateTime].
  void setNow(DateTime time) => _now = time.toUtc();

  /// Sets the mock to a trusted or untrusted state.
  ///
  /// When [trusted] is `false`, assessments report an unanchored
  /// posture with a `null` time. Pass [reason] to script which one;
  /// when omitted, the previously active unanchored reason is kept
  /// (initially [TrustStatusReason.syncFailed]). This mirrors
  /// production precedence: [TrustStatusReason.rebootDetected] set by
  /// [simulateReboot] persists until a successful re-sync
  /// ([restoreTrust]), not merely until the next trust-loss event.
  void setTrusted(bool trusted, {TrustStatusReason? reason}) {
    _trusted = trusted;
    if (reason != null) _unanchoredReason = reason;
  }

  /// Sets the NTS authentication level for this mock.
  ///
  /// With [NtsAuthLevel.verified], trusted assessments report
  /// [TrustStatusReason.synchronized]; with [NtsAuthLevel.none] they
  /// report [TrustStatusReason.degraded].
  void setAuthLevel(NtsAuthLevel level) => _authLevel = level;

  /// Sets the confidence grade reported by trusted assessments.
  void setConfidence(ConfidenceLevel level) => _confidence = level;

  /// Scripts the [TimeAssessment.syncInProgress] flag on assessments.
  ///
  /// Orthogonal to the trust posture, mirroring production: script it
  /// alongside `setTrusted(false)` to exercise the "unanchored but
  /// resolution imminent" wait state, or while trusted to simulate a
  /// background refresh in flight.
  void setSyncInProgress(bool inProgress) => _syncInProgress = inProgress;

  /// Restores the mock to a trusted state, simulating a successful
  /// re-sync.
  ///
  /// Also resets the scripted unanchored reason to
  /// [TrustStatusReason.syncFailed], ending a
  /// [TrustStatusReason.rebootDetected] posture set by
  /// [simulateReboot] — mirroring production, where only a successful
  /// sync clears a detected reboot.
  void restoreTrust() {
    _trusted = true;
    _unanchoredReason = TrustStatusReason.syncFailed;
  }

  /// Simulates a device reboot, invalidating trust.
  ///
  /// Mirrors production semantics: assessments report
  /// [TrustStatusReason.rebootDetected] with a `null` time until
  /// [restoreTrust] simulates a successful re-sync.
  void simulateReboot() {
    _trusted = false;
    _unanchoredReason = TrustStatusReason.rebootDetected;
  }

  /// Builds a [TimeAssessment] snapshot from the scripted mock state.
  TimeAssessment getAssessment() {
    if (_trusted) {
      return TimeAssessment(
        reason: _authLevel == NtsAuthLevel.verified
            ? TrustStatusReason.synchronized
            : TrustStatusReason.degraded,
        authLevel: _authLevel,
        confidence: _confidence,
        time: _now,
        uncertainty: Duration.zero,
        anchorAge: Duration.zero,
        syncInProgress: _syncInProgress,
      );
    }
    return TimeAssessment(
      reason: _unanchoredReason,
      authLevel: NtsAuthLevel.none,
      confidence: ConfidenceLevel.none,
      syncInProgress: _syncInProgress,
    );
  }
}
