import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'infra/trusted_time_log.dart';
import 'integrity_event.dart';
import 'models.dart';
import 'monotonic_clock.dart';

/// A high-integrity monitoring agent that detects temporal tampering and
/// OS-level clock jumps.
///
/// The [IntegrityMonitor] implements a dual-layer defense strategy:
/// 1. **Native Signals**: Listens for platform-native events (e.g.,
///    `ACTION_TIME_CHANGED` on Android, `WM_TIMECHANGE` on Windows).
/// 2. **Monotonic Drift Detection**: A Dart-side secondary check that compares
///    the delta of the hardware monotonic clock vs. the system wall clock.
///
/// This dual-layer approach ensures that even if native OS hooks are
/// bypassed or suppressed, manual wall-clock manipulation is eventually
/// detected via monotonic divergence.
final class IntegrityMonitor {
  /// Documented.
  IntegrityMonitor({required MonotonicClock clock}) : _clock = clock;

  final MonotonicClock _clock;
  final _controller = StreamController<IntegrityEvent>.broadcast();

  /// The underlying platform channel for native clock-change notifications.
  static const _channel = EventChannel('trusted_time/integrity');

  StreamSubscription<dynamic>? _nativeSub;
  TrustAnchor? _anchor;
  Duration? _lastTimezoneOffset;
  Timer? _driftCheckTimer;

  /// Set once [dispose] runs. Guards the async drift-check loop from
  /// resurrecting a timer (or emitting) after teardown: a
  /// [_runAdaptiveDriftCheck] suspended mid-await can otherwise resume
  /// post-dispose and re-arm [_driftCheckTimer].
  bool _disposed = false;

  /// Reactive stream of detected integrity violations and timezone changes.
  Stream<IntegrityEvent> get events => _controller.stream;

  /// Publishes an externally-detected [event] on the [events] stream.
  ///
  /// The dual-layer detection above (native signals + monotonic drift)
  /// covers clock jumps, reboots, and timezone changes the monitor observes
  /// directly. This entry point lets the engine surface integrity events it
  /// detects itself — currently [TamperReason.degradedTier], raised when a
  /// sync cycle cannot establish a Tier 1 truth box. No-op once disposed.
  void report(IntegrityEvent event) => _emit(event);

  /// Attaches the monitor to an active trust anchor and begins surveillance.
  ///
  /// No-op once disposed: re-attaching after teardown would open a fresh
  /// native subscription (and arm a drift timer) that a subsequent
  /// early-returning [dispose] could no longer cancel, leaking it past
  /// teardown.
  void attach(TrustAnchor anchor) {
    if (_disposed) return;
    _anchor = anchor;
    _lastTimezoneOffset = DateTime.now().timeZoneOffset;
    _nativeSub?.cancel();
    _nativeSub = _channel.receiveBroadcastStream().listen(_onNativeEvent);

    _startDriftCheck();
  }

  /// The dynamic interval for Monotonic-to-Wall drift checks.
  Duration _driftCheckInterval = const Duration(minutes: 5);

  /// Initializes or restarts the adaptive drift check loop.
  void _startDriftCheck() {
    _driftCheckTimer?.cancel();
    _driftCheckTimer = null;
    if (_disposed) return;
    _driftCheckTimer = Timer(_driftCheckInterval, _runAdaptiveDriftCheck);
  }

  /// Executes an adaptive drift check and recalculates the next check interval.
  ///
  /// To optimize for both battery and integrity:
  /// * Upon anomaly detection, the check frequency accelerates to **30 seconds**.
  /// * As stability is maintained, the interval gradually relaxes back to
  ///   the **5-minute** baseline.
  Future<void> _runAdaptiveDriftCheck() async {
    final hasAnomaly = await _checkDrift();
    // dispose() may have run while _checkDrift awaited the platform clock.
    // Bail before touching interval state or arming a new timer so a
    // disposed monitor can't resurrect its drift loop.
    if (_disposed) return;

    if (hasAnomaly) {
      _driftCheckInterval = const Duration(seconds: 30);
    } else {
      _driftCheckInterval = Duration(
        seconds: min(_driftCheckInterval.inSeconds + 30, 300),
      );
    }

    _startDriftCheck();
  }

  /// Compares local monotonic uptime delta against wall-clock delta to
  /// detect tampering.
  ///
  /// In a healthy system, `ΔUptime` and `ΔWall` should be nearly identical.
  /// A divergence of >5 seconds is considered a high-integrity violation.
  Future<bool> _checkDrift() async {
    final anchor = _anchor;
    if (anchor == null) return false;

    final uptimeMs = await _clock.uptimeMs();
    if (_disposed) return false;
    final wallMs = DateTime.now().millisecondsSinceEpoch;

    final elapsedUptime = uptimeMs - anchor.uptimeMs;
    final elapsedWall = wallMs - anchor.wallMs;

    final divergence = (elapsedUptime - elapsedWall).abs();
    if (divergence > 5000) {
      _emit(
        IntegrityEvent(
          reason: TamperReason.systemClockJumped,
          detectedAt: DateTime.now().toUtc(),
          drift: Duration(milliseconds: divergence),
        ),
      );
      return true;
    }
    return false;
  }

  /// Internal handler for raw platform events.
  void _onNativeEvent(dynamic raw) {
    try {
      if (_anchor == null) return;
      if (raw is! Map) return;
      final map = raw;
      final type = map['type'] as String? ?? 'unknown';
      final driftMs = map['driftMs'] as int?;

      switch (type) {
        case 'clockJumped':
          _emit(
            IntegrityEvent(
              reason: TamperReason.systemClockJumped,
              detectedAt: DateTime.now().toUtc(),
              drift: driftMs != null ? Duration(milliseconds: driftMs) : null,
            ),
          );
        case 'reboot':
          _emit(
            IntegrityEvent(
              reason: TamperReason.deviceRebooted,
              detectedAt: DateTime.now().toUtc(),
            ),
          );
        case 'timezoneChanged':
          final now = DateTime.now();
          final prev = _lastTimezoneOffset;
          _lastTimezoneOffset = now.timeZoneOffset;
          _emit(
            IntegrityEvent(
              reason: TamperReason.timezoneChanged,
              detectedAt: now.toUtc(),
              drift: prev != null
                  ? Duration(
                      milliseconds: (now.timeZoneOffset - prev).inMilliseconds
                          .abs(),
                    )
                  : null,
            ),
          );
        default:
          _emit(
            IntegrityEvent(
              reason: TamperReason.unknown,
              detectedAt: DateTime.now().toUtc(),
            ),
          );
      }
    } catch (e, st) {
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.error,
          '[TrustedTime] Critical failure in native event dispatcher: $e\n$st',
        );
      }
    }
  }

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
  /// platform that cannot supply one, is treated as rebooted. Web fails
  /// closed unconditionally — it has no boot concept and its monotonic
  /// source (`performance.now()`) is session-relative, so no persisted
  /// anchor can ever be validated against it. The uptime inequality is
  /// not sufficient there: an anchor captured early in a previous page
  /// session is overtaken by the new session's counter after a short
  /// wait-out, the same shape as the reboot attack on native.
  ///
  /// Returns the reboot verdict alongside the freshly-sampled uptime so
  /// that callers can reuse it (e.g., to compute the elapsed-time gap on
  /// warm restore) without issuing a second platform-channel call.
  Future<({bool rebooted, int currentUptimeMs})> checkRebootOnWarmStart(
    TrustAnchor previousAnchor,
  ) async {
    final currentUptime = await _clock.uptimeMs();
    final uptimeRegressed = currentUptime < previousAnchor.uptimeMs;
    if (kIsWeb) {
      // No boot-session concept on web, and performance.now() resets
      // per page load, so a persisted anchor can never be validated
      // against the current session's counter. Fail closed: any warm
      // restore on web forces a fresh network sync.
      return (rebooted: true, currentUptimeMs: currentUptime);
    }
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

  void _emit(IntegrityEvent event) {
    try {
      if (!_controller.isClosed) _controller.add(event);
    } catch (_) {
      // Stream may have closed between check and add in rare race conditions.
    }
  }

  /// Test-only: whether a drift-check timer is currently armed.
  ///
  /// Uses [Timer.isActive] rather than a null check so the hook reflects an
  /// actually pending timer: a one-shot [Timer] stays referenced after it
  /// fires (until the next [_startDriftCheck] rebinds it), so `!= null` would
  /// report a fired-but-not-yet-rearmed timer as still armed.
  @visibleForTesting
  bool get debugDriftTimerActive => _driftCheckTimer?.isActive ?? false;

  /// Test-only: runs one adaptive drift-check cycle and returns its
  /// future, so the dispose-during-await race can be reproduced
  /// deterministically without waiting on the real 5-minute timer.
  @visibleForTesting
  Future<void> debugRunAdaptiveDriftCheck() => _runAdaptiveDriftCheck();

  /// Releases platform channel listeners and stops surveillance.
  ///
  /// Idempotent: sets [_disposed] first so any in-flight
  /// [_runAdaptiveDriftCheck] that resumes after this point short-circuits
  /// instead of re-arming the drift timer.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _driftCheckTimer?.cancel();
    _driftCheckTimer = null;
    _nativeSub?.cancel();
    _controller.close();
  }
}
