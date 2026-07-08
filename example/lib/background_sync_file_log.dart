import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart';

/// Durable, process-independent transcript of every headless background
/// sync fire, written to a single append-only file under a `logs/`
/// sub-directory of the application documents directory.
///
/// **Why this exists.** The headless background-sync isolate (spun up by
/// Android `WorkManager` / iOS `BGTaskScheduler`, see ADR 0002) runs in a
/// separate process from the foreground app and is torn down as soon as
/// each fire completes. The foreground telemetry stack
/// (`TelemetryRecorder` + `BenchmarkLogger`) is attached to the foreground
/// engine's `SyncObserver` and therefore never sees a background fire.
/// Before this class, the only trace a background fire left was a
/// debug-only `debugPrint` on failure — visible in `logcat` while the
/// device was tethered, gone afterwards. This log makes the background
/// process its own source of truth: every fire appends one line here,
/// readable in-app (see the readback panel in `main.dart`) or off-device
/// via `adb pull`, with no `logcat` capture required.
///
/// **Why a per-call open/write/close rather than a long-lived [IOSink].**
/// `BenchmarkLogger` holds an [IOSink] open for the whole foreground
/// session because it streams hundreds of events per benchmark run. The
/// headless isolate is the opposite shape: it fires once, writes a single
/// summary line, and is destroyed. There is no session to hold a handle
/// open across, and a periodic flush timer would be pointless in an
/// isolate that will not outlive the call. So [append] opens the file in
/// append mode, writes one line, flushes, and closes — fully synchronous
/// with the caller's `await`, so the line is durably on disk before the
/// isolate returns control to the OS scheduler.
///
/// **Platform scope: native (mobile / desktop) only.** Imports `dart:io`
/// and `path_provider`, neither available on Flutter web. The bundled
/// example is android + ios only, so this is consistent with its
/// deployment surface — same constraint as [BenchmarkLogger]. The core
/// `trusted_time` package itself stays web-compatible; this is an
/// example-only diagnostic instrument.
class BackgroundSyncFileLog {
  BackgroundSyncFileLog._();

  /// Whether the transcript is written at all in this build.
  ///
  /// Debug builds always log — the transcript is the development loop's
  /// primary window onto the headless path. Release builds default to
  /// *no* logging (a production install must not accumulate an unbounded
  /// diagnostic file in the user's documents directory), but a test
  /// install can opt back in at build time:
  ///
  /// ```sh
  /// flutter run --release --dart-define=BG_SYNC_LOG=true
  /// ```
  ///
  /// Both operands are compile-time constants, so in an ordinary release
  /// build the writer body below is tree-shaken out entirely rather than
  /// branch-checked at runtime — same mechanism as the `BG_SYNC_MINUTES`
  /// verification hook in `main.dart`.
  static const bool enabled = kDebugMode || bool.fromEnvironment('BG_SYNC_LOG');

  /// Sub-directory under `<docs>/` that holds the transcript, keeping the
  /// background-sync log grouped rather than loose in the documents root.
  /// Created on demand by [append]; see the recursive parent-create there.
  static const String subDirName = 'logs';

  /// File name of the transcript under `<docs>/[subDirName]/`. A single
  /// stable file (not a per-session file like [BenchmarkLogger]) so
  /// background fires from independent isolate invocations all accumulate
  /// in one place the operator can `adb pull` by a known path.
  static const String fileName = 'nts_bg_syncs.log';

  /// Resolves the absolute path to the transcript, creating no file.
  ///
  /// Surfaced so the readback panel can display the exact on-device path
  /// for `adb pull`, and so callers can probe existence before reading.
  static Future<String> resolvePath() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/$subDirName/$fileName';
  }

  /// Appends a single [line] to the transcript, prefixed with a UTC
  /// wall-clock timestamp, and returns once the write is durably flushed
  /// and the handle closed.
  ///
  /// Never throws: a background fire's outcome must not be lost to a
  /// disk-full / permission-denied condition on the *logging* path, and
  /// the headless isolate has no console to surface an error to anyway.
  /// I/O failures are swallowed; the worst case is a missing log line,
  /// which is strictly better than an unhandled exception aborting the
  /// isolate after the sync itself already succeeded.
  ///
  /// A trailing newline is added, so callers pass a single logical line
  /// without their own terminator.
  ///
  /// A no-op when [enabled] is false, so this single choke-point enforces
  /// the build-time logging policy for every writer (foreground and
  /// headless alike) — call sites stay unconditional.
  static Future<void> append(String line) async {
    if (!enabled) return;
    try {
      final path = await resolvePath();
      final file = File(path);
      // Ensure the parent exists — on a fresh install the documents dir
      // itself is present, but guard defensively so the first background
      // fire on a device that has never run the foreground app still
      // records its line.
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      final stamp = DateTime.now().toUtc().toIso8601String();
      final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      try {
        sink.writeln('$stamp  $line');
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (_) {
      // Best-effort: see dartdoc. A lost log line must not escalate into
      // a failed background fire.
    }
  }

  /// Reads the tail of the transcript back as a list of lines, newest
  /// first, capped at [maxLines] (most-recent) to bound UI cost for a
  /// transcript that grows unbounded across a multi-hour capture.
  ///
  /// The file is streamed line-by-line through a fixed-size ring buffer
  /// rather than materialized with `readAsLines()`, so peak memory is
  /// O([maxLines]) no matter how large the transcript has grown — a
  /// multi-day soak capture on a low-end device costs the same RAM as a
  /// fresh install. (I/O is still a single sequential pass over the file:
  /// a true seek-from-end tail is not worth the byte-boundary complexity
  /// for a diagnostic transcript that grows by one line per fire.)
  ///
  /// Returns an empty list if the file does not exist yet or cannot be
  /// read. Never throws, for the same reason as [append] — the readback
  /// panel treats "no log" and "unreadable log" identically as "nothing
  /// to show yet". A non-positive [maxLines] is treated as a cap of
  /// zero and returns an empty list without touching the file (rather
  /// than tripping the ring buffer's eviction on an empty queue, or —
  /// for negative values — never evicting at all and silently breaking
  /// the O([maxLines]) memory bound).
  static Future<List<String>> readLatest({int maxLines = 200}) async {
    if (maxLines <= 0) return const [];
    try {
      final file = File(await resolvePath());
      if (!await file.exists()) return const [];
      // Ring buffer of the last [maxLines] non-empty lines: enqueue each
      // line as it streams past, evicting the oldest once full.
      final tail = ListQueue<String>(maxLines);
      final lines = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        if (tail.length == maxLines) tail.removeFirst();
        tail.addLast(line);
      }
      // Newest first so the operator sees the most recent fire at the top
      // without scrolling a long unbounded transcript.
      return tail.toList().reversed.toList();
    } catch (_) {
      return const [];
    }
  }

  /// Deletes the transcript, if present. Returns silently whether or not
  /// a file existed. Used by the readback panel's clear action so an
  /// operator can start a fresh capture without stale lines.
  static Future<void> clear() async {
    try {
      final file = File(await resolvePath());
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort, consistent with append/readLatest.
    }
  }
}
