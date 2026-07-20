import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:nts/nts.dart' as nts;

/// A resolved monotonic reader and the timeline property that matters
/// for projection integrity: whether its readings keep advancing while
/// the device is in deep sleep.
final class MonotonicReader {
  /// Creates a reader wrapping [read] with the given capability flag.
  const MonotonicReader({required this.read, required this.isSleepAware});

  /// Yields microsecond readings on a single monotonic timeline. Only
  /// differences between readings from the same reader are meaningful.
  final int Function() read;

  /// Whether the underlying timeline continues counting during device
  /// suspend. `false` means a projection over this reader freezes for
  /// the duration of any sleep cycle and resumes behind by that much.
  final bool isSleepAware;
}

/// Signature of a monotonic reader factory.
typedef MonotonicReaderFactory = MonotonicReader Function();

/// Resolves the best available monotonic microsecond reader.
///
/// Prefers the sleep-aware [nts.MonotonicClock] (`CLOCK_BOOTTIME` /
/// `mach_continuous_time` / `QueryInterruptTimePrecise` via the Rust
/// bridge), whose readings keep advancing while the device is in deep
/// sleep. When the bridge is not initialized — HTTPS/NTP-only configs
/// that never call `NtsRustLib.init()`, web, or plain unit-test
/// isolates — falls back to a fresh [Stopwatch], which is monotonic
/// but freezes during suspend (the pre-existing behaviour). The
/// returned [MonotonicReader.isSleepAware] flag records which timeline
/// was resolved, so callers can surface (or refuse) the degraded
/// fallback instead of riding it silently.
///
/// Availability is checked via the non-throwing
/// `NtsRustLib.instance.initialized` signal — the same condition
/// [nts.MonotonicClock] itself gates on — so bridge-less callers that
/// resolve on every invocation (e.g. [PlatformMonotonicClock.uptimeMs]
/// on a timer) never pay an exception-based probe. Deliberately not
/// memoized: a bridge initialized after a first fallback resolution
/// must be picked up on the next resolution instead of pinning the
/// suspend-frozen fallback for the process lifetime.
MonotonicReader resolveMonotonicReader() {
  // `instance` carries frb's blanket @internal annotation, but the
  // `initialized` getter on it is the documented public signal — and
  // the exact gate nts.MonotonicClock's own constructor checks before
  // throwing. Reading it here keeps the two checks equivalent.
  // ignore: invalid_use_of_internal_member
  if (nts.NtsRustLib.instance.initialized) {
    return MonotonicReader(
      read: nts.MonotonicClock.instance.nowMicros,
      isSleepAware: true,
    );
  }
  // Lazily started on first read: capability-only probes (e.g. the
  // pre-anchor SyncClock.isSleepAware query behind the fail-fast
  // gate) resolve a reader they never read, and must not each leave
  // a running Stopwatch behind. Deltas are unaffected — only
  // differences between readings from the same reader are
  // meaningful, and the first read anchors the epoch.
  Stopwatch? stopwatch;
  return MonotonicReader(
    read: () => (stopwatch ??= Stopwatch()..start()).elapsedMicroseconds,
    isSleepAware: false,
  );
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

/// Production implementation using native OS kernel timers.
///
/// [uptimeMs] prefers the synchronous nts bridge clock when it is
/// available and falls back to the `trusted_time/monotonic` method
/// channel otherwise. Both read the same per-boot kernel counters
/// (`CLOCK_BOOTTIME` / `mach_continuous_time` / interrupt time on the
/// bridge; `SystemClock.elapsedRealtime()` / `systemUptime` /
/// `CLOCK_BOOTTIME` / `GetTickCount64()` on the channel), so readings
/// from the two paths share one epoch and remain mutually comparable —
/// including against anchors persisted by a previous process on the
/// other path within the same boot session.
///
/// [getBootId] always uses the channel: the bridge clock's epoch is
/// per-boot but exposes no boot-session *identity*, which the
/// wait-out-attack detection requires.
final class PlatformMonotonicClock implements MonotonicClock {
  /// Creates a clock. [readerFactory] overrides monotonic source
  /// resolution — a test seam; production callers use the default
  /// [resolveMonotonicReader].
  PlatformMonotonicClock({
    @visibleForTesting MonotonicReaderFactory? readerFactory,
  }) : _readerFactory = readerFactory ?? resolveMonotonicReader;

  static const _channel = MethodChannel('trusted_time/monotonic');

  final MonotonicReaderFactory _readerFactory;

  @override
  Future<int> uptimeMs() async {
    // Only a sleep-aware reader is a per-boot kernel counter on the
    // channel's timeline; the suspend-frozen Stopwatch fallback has an
    // arbitrary process-relative epoch and must never masquerade as
    // uptime, so bridge-less configs keep the async channel path.
    final reader = _readerFactory();
    if (reader.isSleepAware) {
      return reader.read() ~/ 1000;
    }
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
  SyncClock({@visibleForTesting MonotonicReaderFactory? readerFactory})
    : _readerFactory = readerFactory ?? resolveMonotonicReader;

  final MonotonicReaderFactory _readerFactory;
  MonotonicReader? _reader;
  int _anchorReadingMicros = 0;
  int _cachedUptimeMs = 0;
  int _cachedWallMs = 0;
  int _initialElapsedMs = 0;

  /// Whether the projection timeline keeps advancing during device
  /// suspend.
  ///
  /// Reports the reader captured with the current anchor; before the
  /// first [update] it probes the factory for the currently resolvable
  /// capability without capturing anything, so a pre-anchor caller
  /// (e.g. the fail-fast gate at engine init) still gets an accurate
  /// answer.
  bool get isSleepAware => (_reader ?? _readerFactory()).isSleepAware;

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
    final reader = _readerFactory();
    _reader = reader;
    _anchorReadingMicros = reader.read();
  }

  /// Returns the elapsed time since the anchor was last updated.
  int elapsedSinceAnchorMs() {
    final reader = _reader;
    if (reader == null) return _initialElapsedMs;
    return _initialElapsedMs + (reader.read() - _anchorReadingMicros) ~/ 1000;
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
    _reader = null;
    _anchorReadingMicros = 0;
  }
}
