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
    _filePath = '${dir.path}/nts_session_$stamp.log';
    _sink = File(_filePath!).openWrite(mode: FileMode.writeOnlyAppend);

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
  /// closes the file handle. Safe to call multiple times.
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
      } finally {
        await sink.close();
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
    final d = '${t.year.toString().padLeft(4, '0')}'
        '${two(t.month)}${two(t.day)}';
    final h = '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    return '${d}_$h';
  }
}
