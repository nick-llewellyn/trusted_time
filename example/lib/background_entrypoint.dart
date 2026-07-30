import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show DebugPrintCallback, debugPrint, kDebugMode;
import 'package:trusted_time/trusted_time.dart';

import 'background_sync_file_log.dart';
import 'nts_sources.dart';

/// Builds the NTS-exclusive stress-test configuration.
///
/// NTP sources are disabled so the engine relies solely on
/// cryptographically authenticated samples. minQuorumRatio is 0.4, which
/// (combined with MarzulloEngine's hard floor of requiredQuorum >= 2) means
/// at least three samples must arrive in a cycle before consensus is
/// possible, and at least two of those three must overlap.
///
/// Shared between the foreground engine (the example's `main`) and the
/// headless background callback ([trustedTimeBackgroundCallback]) so a
/// background fire refreshes the anchor against the same source policy the
/// foreground engine uses. The pool is shuffled per call so warming-pipeline
/// ordering effects still surface across launches, but every source is used
/// every cycle so diagnostic comparisons are not confounded by random subset
/// selection.
TrustedTimeConfig buildStressConfig() {
  final ntsSubset = (List<String>.of(
    curatedNtsPool,
  )..shuffle(Random())).toList(growable: false);
  return TrustedTimeConfig(
    // The stress harness measures NTS only; the library's curated NTP
    // inventory would add 51 unrelated hosts to every cycle. This is a
    // diagnostic app, so it deliberately reaches for the test seam.
    // ignore: invalid_use_of_visible_for_testing_member
    disableNtpForTesting: true,
    ntsServers: ntsSubset,
    minimumQuorum: 2,
    minQuorumRatio: 0.4,
    refreshInterval: const Duration(seconds: 30),
    persistState: true,
  );
}

/// Top-level entrypoint invoked from a headless [FlutterEngine] when the OS
/// scheduler (Android `WorkManager` / iOS `BGAppRefreshTask`) fires the
/// background sync. The `@pragma('vm:entry-point')` annotation is mandatory
/// — it keeps this symbol alive through release-mode tree-shaking so the
/// callback handle persisted in `SharedPreferences`/`UserDefaults` can be
/// resolved back to a function.
///
/// The pragma is necessary but not sufficient. A persisted handle encodes
/// this function's *library URI* and name, so moving or renaming it
/// invalidates any handle an installed build already stored — see
/// [TrustedTime.registerBackgroundCallback]. The example re-registers on
/// every launch, which repairs a stale handle on the first foreground run
/// after such a change; a host that registers only once must re-register
/// after moving its entrypoint.
@pragma('vm:entry-point')
void trustedTimeBackgroundCallback() {
  // The host callback signature is `void Function()`, so it cannot await
  // the returned Future. `unawaited(...)` makes the fire-and-forget intent
  // explicit and keeps `unawaited_futures` clean if a host copy/pastes
  // this pattern into an async context.
  //
  // The work is delegated to an async helper so the outcome can be awaited
  // and appended to BackgroundSyncFileLog: this callback runs in the
  // headless isolate, which the foreground telemetry stack never observes,
  // so the on-disk transcript is the only durable record of a background
  // fire (readable in-app or via `adb pull`, no logcat needed).
  unawaited(_runAndLogBackgroundSync());
}

/// Runs one headless background sync, appending a `BEGIN` line before the
/// sync and one result line when it completes, then lets the isolate be
/// torn down.
///
/// [TrustedTime.runBackgroundSync] already persists the anchor (on success,
/// when `persistState` is set) and signals native completion via the method
/// channel; this wrapper adds only the example's own observability.
///
/// Two teardown-race defences, both required:
///
/// - The `BEGIN` line is written and awaited *before* the sync starts, so
///   an OS-dispatched fire is durably recorded even if everything after it
///   is lost. Without it, a fire whose result line is truncated leaves no
///   trace at all — indistinguishable from the OS never dispatching.
/// - The result line is written inside the `onResult` hook, which
///   [TrustedTime.runBackgroundSync] awaits *before* it sends the native
///   completion signal. On Android the worker destroys the headless engine
///   as soon as that signal arrives, so any append performed after the
///   outer `await` returns would race the teardown and usually lose.
///
/// The whole body is guarded: a logging failure must never turn a
/// successful sync into a failed background fire, and any thrown error is
/// itself recorded rather than left to escape the isolate.
///
/// **Debug-build tee.** In debug builds the library's internal
/// `[TrustedTime]` diagnostics (burst `receipts=[...]` deltas, consensus
/// `receiptSpread=...`, in-run retry attempts) go through [debugPrint] and
/// land only in logcat — lost once the ring buffer rolls. While the sync
/// runs, [debugPrint] is swapped for a wrapper that also queues each
/// `[TrustedTime]`-prefixed line onto a sequential append chain into the
/// transcript. The chain is drained inside `onResult` — before
/// [TrustedTime.runBackgroundSync] sends the native completion signal —
/// so the tee'd lines cannot lose the engine-teardown race, and they land
/// ahead of the result line. `kDebugMode` is a compile-time constant, so
/// release builds carry none of this (and have no debug lines to tee
/// anyway).
Future<void> _runAndLogBackgroundSync() async {
  DebugPrintCallback? originalDebugPrint;
  var teeChain = Future<void>.value();
  if (kDebugMode) {
    final original = originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith('[TrustedTime]')) {
        // Sequential chain (not fire-and-forget) so transcript order
        // matches emission order and onResult can await one future.
        teeChain = teeChain.then(
          (_) => BackgroundSyncFileLog.append('FIRE      DEBUG    $message'),
        );
      }
      original(message, wrapWidth: wrapWidth);
    };
  }
  try {
    await BackgroundSyncFileLog.append('FIRE      BEGIN');
    // Diagnostic: how the OS scheduler last treated this work. On Android
    // this surfaces WorkManager's WorkInfo.getStopReason() for the
    // *previous* attempt (e.g. TIMEOUT, DEVICE_STATE, QUOTA); on iOS it
    // reports whether the previous BGTask attempt was terminated by the
    // expiration handler (state=EXPIRED(<instant>), TIMEOUT). Either way
    // it answers "was the last fire killed?" from the transcript alone —
    // pairing any orphaned FIRE BEGIN with its cause. Returns null before
    // the first schedule; best-effort, never fatal.
    final stopInfo = await TrustedTime.getBackgroundStopReason();
    if (stopInfo != null) {
      await BackgroundSyncFileLog.append(
        'FIRE      STOPINFO state=${stopInfo.state} '
        'prevStopReason=${stopInfo.stopReasonName}(${stopInfo.stopReason})',
      );
    }
    await TrustedTime.runBackgroundSync(
      config: buildStressConfig(),
      onResult: (result) async {
        // Drain the tee first so debug lines precede the result line and
        // are durably on disk before the native completion signal.
        await teeChain;
        await BackgroundSyncFileLog.append(_formatBackgroundResult(result));
      },
    );
  } catch (e) {
    await teeChain;
    await BackgroundSyncFileLog.append('FIRE      threw    error=$e');
  } finally {
    if (originalDebugPrint != null) {
      debugPrint = originalDebugPrint;
    }
  }
}

/// Formats a [TrustedTimeBackgroundResult] as one aligned log line for the
/// on-disk background-sync transcript.
///
/// On success the anchor's key fields are surfaced (network UTC, auth
/// level, confidence, uncertainty) so a reader can confirm not just that a
/// fire happened but that it reached a real, trustworthy anchor. On failure
/// the reason string is carried verbatim. The `elapsed` wall-clock duration
/// is included in both cases as a coarse health signal.
String _formatBackgroundResult(TrustedTimeBackgroundResult result) {
  final elapsedMs = result is BackgroundSyncSuccess
      ? result.elapsed.inMilliseconds
      : (result as BackgroundSyncFailure).elapsed.inMilliseconds;
  final elapsed = '${elapsedMs}ms';
  switch (result) {
    case BackgroundSyncSuccess(:final anchor):
      final utc = DateTime.fromMillisecondsSinceEpoch(
        anchor.networkUtcMs,
        isUtc: true,
      ).toIso8601String();
      return 'FIRE      SUCCESS  elapsed=$elapsed '
          'utc=$utc auth=${anchor.authLevel.name} '
          'confidence=${anchor.confidence.name} '
          '±${anchor.uncertaintyMs}ms';
    case BackgroundSyncFailure(:final reason):
      return 'FIRE      FAILURE  elapsed=$elapsed reason=$reason';
  }
}
