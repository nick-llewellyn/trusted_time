import 'package:flutter/foundation.dart';

/// Severity of a diagnostic line emitted by the trusted_time engine.
///
/// Levels map onto the conventional logging ladder so a host sink can
/// forward each message to its own logger at the equivalent level:
///
/// - [debug] — high-volume per-cycle diagnostics (per-source sample
///   lines, consensus attribution — including which samples were
///   rejected as outliers — and NTS burst telemetry).
/// - [info] — noteworthy but expected events (a source query failing).
/// - [warning] — conditions an operator should look at (sync cycle
///   failed, anchor minted degraded, deprecated configuration).
/// - [error] — unexpected internal failures.
enum TrustedTimeLogLevel {
  /// High-volume per-cycle diagnostics.
  debug,

  /// Noteworthy but expected events.
  info,

  /// Conditions an operator should look at.
  warning,

  /// Unexpected internal failures.
  error,
}

/// Host-supplied sink for the engine's diagnostic log lines.
///
/// Install one via `TrustedTime.initialize(onLog: ...)` to receive
/// every `[TrustedTime]` diagnostic — in release and profile builds
/// too — and route it into the host's own logging pipeline (a `Log`
/// utility, Crashlytics breadcrumbs, a file, ...). When no sink is
/// installed, diagnostics fall back to [debugPrint] in debug builds
/// and are dropped entirely in release/profile builds, preserving the
/// package's historical behaviour.
///
/// The callback is invoked synchronously on whichever isolate/zone
/// produced the message; implementations should be fast and must not
/// throw.
typedef TrustedTimeLogSink =
    void Function(TrustedTimeLogLevel level, String message);

/// Process-global router for the engine's diagnostic log lines.
///
/// A static facade (rather than a value threaded through every
/// constructor) because producers span sources, the engine, the
/// impl singleton, and platform-event handlers — several of which
/// are `const`-constructible and cannot carry a closure. Mirrors the
/// process-global nature of [debugPrint], which this replaces.
abstract final class TrustedTimeLog {
  static TrustedTimeLogSink? _sink;

  /// Installs (or, with `null`, removes) the process-global sink.
  static set sink(TrustedTimeLogSink? sink) => _sink = sink;

  /// Whether an emitted message can reach any destination.
  ///
  /// `false` only in release/profile builds with no sink installed.
  /// Call sites building expensive messages should guard on this so
  /// the string work is skipped when nothing would receive it.
  static bool get enabled => _sink != null || kDebugMode;

  /// Routes [message] to the installed sink, or to [debugPrint] in
  /// debug builds when no sink is installed. A sink takes over
  /// routing entirely — messages are not additionally [debugPrint]ed.
  ///
  /// A sink that throws (despite the [TrustedTimeLogSink] contract) is
  /// contained here: logging is a side channel, and a consumer logging
  /// bug must not take down a sync or background-sync flow.
  static void log(TrustedTimeLogLevel level, String message) {
    final sink = _sink;
    if (sink != null) {
      try {
        sink(level, message);
      } catch (e) {
        if (kDebugMode) debugPrint('[TrustedTime] log sink threw: $e');
      }
      return;
    }
    if (kDebugMode) debugPrint(message);
  }
}
