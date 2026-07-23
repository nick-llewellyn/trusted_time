import 'models.dart';
import 'monotonic_clock.dart';

/// Detects reboots across process restarts.
///
/// Time projection is monotonic-only, so wall-clock manipulation cannot
/// affect `now()` and is not monitored. The one temporal event that does
/// invalidate a monotonic anchor is a reboot — the monotonic counter
/// resets — which [checkRebootOnWarmStart] detects via boot-session
/// identity plus an uptime-regression tripwire. The verdict is expressed
/// through assessment state (`TrustStatusReason.rebootDetected`), not
/// events: a reboot always ends the process, so it is only ever detected
/// during initialization.
final class IntegrityMonitor {
  /// Creates a monitor that samples uptime and boot identity via [clock].
  IntegrityMonitor({required MonotonicClock clock}) : _clock = clock;

  final MonotonicClock _clock;

  /// Verification check for reboots during warm-start (cache restoration).
  ///
  /// A reboot is confirmed by boot-session *identity*: the anchor is only
  /// honoured when its recorded [TrustAnchor.bootId] matches the device's
  /// current boot ID. The uptime inequality (`currentUptime <
  /// anchor.uptimeMs`) is kept as a secondary tripwire, but identity is
  /// what defeats the wait-out attack — reboot, then leave the device
  /// powered on until the new uptime exceeds the anchor's recorded value.
  ///
  /// Fails closed on missing identity: an anchor without a boot ID, or a
  /// platform that cannot supply one, is treated as rebooted.
  ///
  /// Returns the reboot verdict alongside the freshly-sampled uptime so
  /// that callers can reuse it (e.g., to compute the elapsed-time gap on
  /// warm restore) without issuing a second platform-channel call.
  Future<({bool rebooted, int currentUptimeMs})> checkRebootOnWarmStart(
    TrustAnchor previousAnchor,
  ) async {
    final currentUptime = await _clock.uptimeMs();
    final uptimeRegressed = currentUptime < previousAnchor.uptimeMs;
    if (uptimeRegressed) {
      // Uptime regression is conclusive on its own — the monotonic
      // counter only resets at boot — so skip the identity IPC call.
      return (rebooted: true, currentUptimeMs: currentUptime);
    }
    if (previousAnchor.bootId == null) {
      // A pre-upgrade anchor can never match any current boot identity,
      // so fail closed without the IPC call.
      return (rebooted: true, currentUptimeMs: currentUptime);
    }
    final currentBootId = await _clock.getBootId();
    final identityMismatch =
        currentBootId == null || previousAnchor.bootId != currentBootId;
    return (
      rebooted: uptimeRegressed || identityMismatch,
      currentUptimeMs: currentUptime,
    );
  }
}
