import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'sync_telemetry.dart';

/// Streams [TelemetryEvent]s out to a per-session log file under the
/// application documents directory, in the `nts_benchmarks/` folder.
///
/// One file is opened per [BenchmarkLogger] instance, named
/// `nts_session_YYYYMMDD_HHMMSS.log` based on wall-clock time at
/// [start]. Writes are issued through an [IOSink] in append mode so
/// they are queued and serialised by the runtime, which keeps the
/// per-event cost low enough to sustain multi-hour benchmarking
/// sessions without buffering the entire transcript in RAM. A periodic
/// flush bounds how much data can be lost if the process is killed.
class BenchmarkLogger {
  BenchmarkLogger({
    Duration flushInterval = const Duration(seconds: 5),
  }) : _flushInterval = flushInterval;

  final Duration _flushInterval;

  IOSink? _sink;
  String? _filePath;
  Timer? _flushTimer;
  VoidCallback? _unsubscribe;

  /// Path of the log file once [start] has resolved, or `null` while
  /// the logger is uninitialised. Intentionally retained across
  /// [dispose] so the UI can continue to surface "the run was
  /// written to …" after the operator stops a benchmark; clear it
  /// at the call site if a stale-path display is undesirable.
  String? get filePath => _filePath;

  /// Opens a fresh session log under `<docs>/nts_benchmarks/` and
  /// subscribes to [recorder] so every recorded event is mirrored to
  /// disk. Subsequent calls without a matching [dispose] are no-ops.
  Future<void> start(TelemetryRecorder recorder) async {
    if (_sink != null) return;

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/nts_benchmarks');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final stamp = _formatStamp(DateTime.now());
    final candidatePath = '${dir.path}/nts_session_$stamp.log';
    // Open the sink first; only commit `_filePath` to instance state
    // once the sink construction has succeeded so the UI can never
    // surface a path that doesn't actually back a writable log file
    // (openWrite can throw on permission-denied / disk-full / invalid
    // path conditions).
    final sink = File(candidatePath).openWrite(mode: FileMode.writeOnlyAppend);
    _sink = sink;
    _filePath = candidatePath;

    _writeHeader();
    _unsubscribe = recorder.addEventListener(_writeEvent);
    // IOSink.flush returns a Future; the Timer.periodic callback
    // is `void Function(Timer)`, so without the wrapper the
    // returned future is dropped and any flush failure (disk full,
    // permission denied) propagates to the zone as an unhandled
    // async exception. Swallow with a debug-only log: data lost in
    // a flush still sits in the IOSink's internal buffer for the
    // next flush cycle, and a final flush in dispose() catches
    // anything still pending at shutdown.
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      final sink = _sink;
      if (sink == null) return;
      unawaited(
        sink.flush().catchError((Object e, StackTrace s) {
          if (kDebugMode) {
            debugPrint('[BenchmarkLogger] periodic flush failed: $e\n$s');
          }
        }),
      );
    });
  }

  /// Detaches from the recorder, flushes any buffered output, and
  /// closes the file handle. Safe to call multiple times. Does not
  /// throw: I/O failures during the final flush/close are swallowed
  /// (with a debug-only log) so callers can `unawaited(dispose())`
  /// from a widget teardown without the risk of an unhandled async
  /// error escaping into the zone — same swallow-and-log policy as
  /// the periodic flush in [start].
  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _unsubscribe?.call();
    _unsubscribe = null;
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('[BenchmarkLogger] dispose flush failed: $e\n$s');
        }
      }
      try {
        await sink.close();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('[BenchmarkLogger] dispose close failed: $e\n$s');
        }
      }
    }
  }

  void _writeHeader() {
    _sink?.writeln(
      '# trusted_time NTS benchmark session '
      'started ${DateTime.now().toIso8601String()}',
    );
  }

  void _writeEvent(TelemetryEvent event) {
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(
      '${event.elapsedMs.toString().padLeft(7)}ms  '
      '${event.kind.name.padRight(13)}  ${event.detail}',
    );
  }

  static String _formatStamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    final d = '${t.year.toString().padLeft(4, '0')}'
        '${two(t.month)}${two(t.day)}';
    final h = '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    // Millisecond suffix so two BenchmarkLoggers started in the same
    // wall-clock second (hot restart, multi-instance test harness)
    // never collide on the same nts_session_*.log path. openWrite
    // uses append mode, so without the ms component a collision
    // would interleave both sessions' lines into a single file.
    final ms = three(t.millisecond);
    return '${d}_${h}_$ms';
  }
}
