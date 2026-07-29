import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'trusted_time_log.dart';

/// Owns background synchronization: the platform method channel on
/// Android/iOS and the in-isolate periodic timer everywhere else.
///
/// Both paths converge on the `onSync` callback supplied at
/// construction; the collaborator holds no reference to the engine.
class BackgroundChannel {
  /// Creates a background-sync façade that runs [onSync] on every
  /// background fire, whether delivered by the platform scheduler or by
  /// the desktop in-isolate timer.
  BackgroundChannel({required Future<void> Function() onSync})
    : _onSync = onSync;

  /// The method channel shared with the native background scheduler.
  ///
  /// Static because the native side addresses one well-known channel
  /// name; the *handler* bound to it is per-instance, so a re-initialize
  /// rebinds rather than stacking.
  static const MethodChannel channel = MethodChannel('trusted_time/background');

  /// Lower bound (minutes) enforced by the platform scheduler. Android's
  /// [WorkManager] rejects any periodic interval below 15 minutes
  /// (`PeriodicWorkRequest.MIN_PERIODIC_INTERVAL_MILLIS`); we mirror that
  /// floor here so the request the native layer receives is always
  /// schedulable and the clamp is visible to Dart-side tests.
  static const int _minBgSyncMinutes = 15;

  /// Upper bound (minutes) = one week, matching the previous 168h cap.
  static const int _maxBgSyncMinutes = 168 * 60;

  final Future<void> Function() _onSync;

  Timer? _desktopTimer;
  bool _disposed = false;

  /// The desktop in-isolate periodic background-sync timer, if armed.
  ///
  /// Exposed as the [Timer] itself (rather than a bool) so tests can pin
  /// the replace-not-stack contract of repeated [enable] calls by
  /// observing cancellation and identity of the old timer.
  Timer? get desktopTimer => _desktopTimer;

  /// Binds the inbound platform-callback handler.
  ///
  /// Called only after a successful bootstrap, so a failed initialize
  /// leaves the channel cleanly unbound.
  void bind() => channel.setMethodCallHandler(_handleMethodCall);

  /// Enables background synchronization at [interval].
  ///
  /// On Android/iOS the interval is applied at minute resolution and
  /// clamped to `[15 min, 1 week]`; the desktop timer path honours
  /// [interval] as given.
  Future<void> enable(Duration interval) async {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (interval.inMinutes < 15) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] Background sync interval below the platform '
          'scheduler floor (15 min); clamped up.',
        );
      }
      await _invoke(interval);
    } else {
      _desktopTimer?.cancel();
      _desktopTimer = Timer.periodic(interval, (_) => unawaited(_onSync()));
    }
  }

  Future<void> _invoke(Duration interval) async {
    // Round *up* to the next whole minute rather than truncating:
    // background sync is battery-sensitive OS work, so a leftover-seconds
    // interval (e.g. 15m59s) must never schedule *more* frequently than
    // the caller requested. Pure integer ceiling division — no double
    // conversion, so no precision loss for very large Durations.
    final minutes =
        (interval.inMicroseconds + Duration.microsecondsPerMinute - 1) ~/
        Duration.microsecondsPerMinute;
    try {
      await channel.invokeMethod<void>('enableBackgroundSync', {
        'intervalMinutes': minutes.clamp(_minBgSyncMinutes, _maxBgSyncMinutes),
      });
    } catch (e) {
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] Background sync failed: $e',
        );
      }
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    // Defence in depth alongside the handler unbind in [dispose]: a
    // callback already dispatched (in flight on the platform thread)
    // when dispose ran must not drive a sync on a disposed engine.
    if (_disposed) return;
    if (call.method == 'onBackgroundSync') await _onSync();
  }

  /// Unbinds the platform handler and cancels the desktop timer.
  ///
  /// Detaching the handler is what stops platform callbacks
  /// (`onBackgroundSync`) from reaching a disposed engine; the
  /// `_disposed` guard in the handler covers the already-dispatched
  /// case the unbind cannot.
  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
    _desktopTimer?.cancel();
    _desktopTimer = null;
  }
}
