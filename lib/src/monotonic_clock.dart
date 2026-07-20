import 'package:flutter/services.dart';
import 'package:nts/nts.dart' as nts;

/// Signature of a monotonic reader factory: returns a function that
/// yields microsecond readings on a single monotonic timeline. Only
/// differences between readings from the same returned function are
/// meaningful.
typedef MonotonicReaderFactory = int Function() Function();

/// Resolves the best available monotonic microsecond reader.
///
/// Prefers the sleep-aware [nts.MonotonicClock] (`CLOCK_BOOTTIME` /
/// `mach_continuous_time` / `QueryInterruptTimePrecise` via the Rust
/// bridge), whose readings keep advancing while the device is in deep
/// sleep. When the bridge is not initialized — HTTPS/NTP-only configs
/// that never call `NtsRustLib.init()`, web, or plain unit-test
/// isolates — falls back to a fresh [Stopwatch], which is monotonic
/// but freezes during suspend (the pre-existing behaviour).
int Function() resolveMonotonicReader() {
  try {
    return nts.MonotonicClock.instance.nowMicros;
  } on StateError {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMicroseconds;
  }
}

/// Contract for providing a hardware-pinned monotonic ticker.
///
/// Monotonic clocks only move forward and are immune to system clock
/// manipulation. They reset to zero on device reboot.
abstract interface class MonotonicClock {
  /// Documented.
  Future<int> uptimeMs();

  /// An opaque identifier for the current boot session, or `null` when
  /// the platform cannot provide one.
  ///
  /// Two calls within the same boot session return the same value; a
  /// reboot produces a different value. Unlike [uptimeMs] — which only
  /// reveals that the counter reset — boot identity survives a wait-out
  /// attack, where the device is rebooted and left powered on until the
  /// new uptime exceeds a persisted anchor's recorded uptime.
  Future<String?> getBootId();
}

/// Production implementation using native OS kernel timers via
/// platform channels.
final class PlatformMonotonicClock implements MonotonicClock {
  static const _channel = MethodChannel('trusted_time/monotonic');

  @override
  Future<int> uptimeMs() async {
    final result = await _channel.invokeMethod<int>('getUptimeMs');
    if (result == null) {
      throw StateError('OS kernel returned null uptime baseline.');
    }
    return result;
  }

  @override
  Future<String?> getBootId() async {
    try {
      return await _channel.invokeMethod<String>('getBootId');
    } on PlatformException {
      // Platform has no boot-session concept (or predates the method).
      // A null boot ID makes anchors fail closed on warm restore.
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// In-memory cache enabling sub-microsecond synchronous access to trusted time.
///
/// Projects elapsed time on a monotonic reader so that measurement is
/// immune to system clock manipulation. The default reader resolution
/// ([resolveMonotonicReader]) prefers the sleep-aware
/// [nts.MonotonicClock], so a device that sleeps between syncs no
/// longer freezes the projected clock; bridge-less configs fall back
/// to a suspend-frozen [Stopwatch] timeline as before.
final class SyncClock {
  /// Creates a clock. [readerFactory] overrides monotonic source
  /// resolution — a test seam; production callers use the default
  /// [resolveMonotonicReader].
  SyncClock({MonotonicReaderFactory? readerFactory})
    : _readerFactory = readerFactory ?? resolveMonotonicReader;

  final MonotonicReaderFactory _readerFactory;
  int Function()? _read;
  int _anchorReadingMicros = 0;
  int _cachedUptimeMs = 0;
  int _cachedWallMs = 0;
  int _initialElapsedMs = 0;

  /// Updates the clock with a new trust anchor.
  ///
  /// [initialElapsedMs] seeds [elapsedSinceAnchorMs] with a pre-existing
  /// gap. On warm restore, this is the difference between the current
  /// native uptime and [TrustAnchor.uptimeMs], so that elapsed time
  /// covers the period the app was not running. Defaults to 0 for
  /// fresh-sync callers.
  ///
  /// The monotonic reader is re-resolved on every update: the nts lazy
  /// singleton is not poisoned by a pre-init access, so a bridge
  /// initialized after a first fallback resolution is picked up at the
  /// next sync instead of pinning the suspend-frozen fallback for the
  /// process lifetime. The reader and its anchor reading are captured
  /// together, so one projection never mixes epochs.
  void update(int uptimeMs, int wallMs, {int initialElapsedMs = 0}) {
    _cachedUptimeMs = uptimeMs;
    _cachedWallMs = wallMs;
    _initialElapsedMs = initialElapsedMs;
    final read = _readerFactory();
    _read = read;
    _anchorReadingMicros = read();
  }

  /// Returns the elapsed time since the anchor was last updated.
  int elapsedSinceAnchorMs() {
    final read = _read;
    if (read == null) return _initialElapsedMs;
    return _initialElapsedMs + (read() - _anchorReadingMicros) ~/ 1000;
  }

  /// The hardware uptime recorded in the last anchor.
  int get lastUptimeMs => _cachedUptimeMs;

  /// The system wall-clock recorded in the last anchor.
  int get lastWallMs => _cachedWallMs;

  /// Releases the monotonic reader and clears the cache.
  void dispose() {
    _cachedUptimeMs = 0;
    _cachedWallMs = 0;
    _initialElapsedMs = 0;
    _read = null;
    _anchorReadingMicros = 0;
  }
}
