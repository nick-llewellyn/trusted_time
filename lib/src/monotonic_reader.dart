// Deliberately Flutter-free (only `package:nts`, which is plain-Dart
// safe): `defaultNtpExchange` and the `bin/ntp_cli.dart` probe tool
// need monotonic readings on the standalone Dart VM, where
// `dart:ui`-transitive imports fail to compile. The Flutter-facing
// clock surfaces live in `monotonic_clock.dart`, which re-exports
// this library so existing imports are unaffected.
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
/// sleep. When the bridge is not initialized — NTP-only configs
/// that never call `NtsRustLib.init()`, or plain unit-test
/// isolates — falls back to a fresh [Stopwatch], which is monotonic
/// but freezes during suspend (the pre-existing behaviour). The
/// returned [MonotonicReader.isSleepAware] flag records which timeline
/// was resolved, so callers can surface (or refuse) the degraded
/// fallback instead of riding it silently.
///
/// Availability is checked via the non-throwing
/// `NtsRustLib.instance.initialized` signal — the same condition
/// [nts.MonotonicClock] itself gates on — so bridge-less callers that
/// resolve on every invocation (e.g. `PlatformMonotonicClock.uptimeMs`
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
