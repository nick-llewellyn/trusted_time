import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart';
import 'package:trusted_time/trusted_time.dart';

/// The kind of telemetry event captured from a [SyncObserver] callback.
///
/// [waiting] is not a [SyncObserver] callback — it is emitted by the
/// benchmarking UI to mark the inter-cycle delay between continuous
/// sync cycles, so the gap is visible in both the on-screen terminal
/// and the persisted session log.
///
/// [dnsStats] is also UI-emitted, not a [SyncObserver] callback. The
/// benchmarking UI snapshots `package:nts`'s process-wide DNS pool
/// counters at the start and end of every worldwide-rotation slice
/// and logs the deltas through this kind so per-slice DNS-pool
/// behaviour (refusals, recoveries, in-flight high-water mark) is
/// attributable in the session log alongside the slice's NTS-KE /
/// NTP outcomes.
enum TelemetryKind {
  syncStarted,
  sample,
  sourceFailed,
  consensus,
  metrics,
  syncFailed,
  waiting,
  dnsStats,
}

/// A single observable event in the synchronization lifecycle, stamped
/// with elapsed time since the recorder was constructed.
@immutable
class TelemetryEvent {
  const TelemetryEvent({
    required this.elapsedMs,
    required this.kind,
    required this.detail,
  });
  final int elapsedMs;
  final TelemetryKind kind;
  final String detail;

  /// Single-line representation matching the layout the recorder
  /// emits to the on-screen terminal and the BenchmarkLogger writes
  /// to disk, so error logs that interpolate `$event` (e.g. the
  /// listener-fan-out catch in TelemetryRecorder._add) carry the
  /// same actionable timestamp/kind/detail context as the rest of
  /// the telemetry trail.
  @override
  String toString() =>
      '${elapsedMs.toString().padLeft(7)}ms  '
      '${kind.name.padRight(13)}  $detail';
}

/// A [SyncObserver] that records every callback into a bounded ring of
/// [TelemetryEvent]s and notifies listeners so the UI can render the
/// per-source pipeline behaviour.
///
/// `onSourceFailed` events surface the engine's `'warm: <error>'`
/// prefix when a [Warmable] source's warm phase throws, letting the UI
/// distinguish warming-phase failures from query-phase failures without
/// any extra plumbing.
class TelemetryRecorder extends ChangeNotifier implements SyncObserver {
  TelemetryRecorder() : _start = Stopwatch()..start();

  static const int _maxEvents = 200;

  final Stopwatch _start;
  final List<TelemetryEvent> _events = [];
  late final UnmodifiableListView<TelemetryEvent> _eventsView =
      UnmodifiableListView(_events);
  final List<void Function(TelemetryEvent)> _listeners = [];
  final List<void Function()> _cycleListeners = [];
  int _totalRecorded = 0;

  /// Live unmodifiable view of recorded events, oldest first.
  ///
  /// Returns a stable [UnmodifiableListView] backed by the same
  /// underlying buffer rather than a fresh `List.unmodifiable` copy
  /// per access. The terminal panel rebuilds on every notifyListeners
  /// (one rebuild per recorded event, plus the per-second DNS-stats
  /// ticker) and the buffer is capped at [_maxEvents] = 200, so a
  /// per-build copy was up to 200 allocations + GC pressure on every
  /// cycle for no benefit. The view is read-only: any mutating call
  /// (add / removeAt / etc.) on the returned list throws
  /// UnsupportedError, matching the previous List.unmodifiable
  /// contract for callers.
  UnmodifiableListView<TelemetryEvent> get events => _eventsView;

  /// Monotonically-increasing count of every [TelemetryEvent] ever
  /// `_add`ed since the last [reset]. Distinct from `events.length`,
  /// which saturates at [_maxEvents] once the ring buffer fills:
  /// downstream listeners that need an "is there a new event since
  /// last build?" signal must compare against this counter rather
  /// than the snapshot length, otherwise growth becomes invisible
  /// after the first 200 entries. Reset to zero by [reset].
  int get totalEventsRecorded => _totalRecorded;

  /// Subscribes [listener] to receive every [TelemetryEvent] as it is
  /// recorded. The benchmarking log writer uses this to mirror events
  /// to disk without coupling the recorder to a specific sink. Returns
  /// a disposer that removes the subscription.
  VoidCallback addEventListener(void Function(TelemetryEvent) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Subscribes [listener] to fire once at the end of every sync cycle,
  /// regardless of whether the cycle succeeded ([SyncObserver.onMetricsReported])
  /// or failed ([SyncObserver.onSyncFailed]). The benchmarking UI uses
  /// this hook to drive continuous resync in long-running sessions.
  /// Returns a disposer that removes the subscription.
  VoidCallback addCycleEndListener(void Function() listener) {
    _cycleListeners.add(listener);
    return () => _cycleListeners.remove(listener);
  }

  /// Records a [TelemetryKind.waiting] entry describing the inter-cycle
  /// delay before the next continuous sync cycle. Routed through the
  /// same `_add` pipeline as observer callbacks so the entry appears in
  /// the on-screen terminal, debug console, and benchmark session log
  /// without any special-casing in the listeners.
  void logCycleDelay(int seconds) {
    _add(
      TelemetryKind.waiting,
      'Waiting $seconds seconds before next cycle...',
    );
  }

  /// Records a [TelemetryKind.dnsStats] entry. The UI formats the
  /// detail string itself (deltas of `recovered` / `refused`,
  /// `highWaterMark`, slice label) so the recorder stays decoupled
  /// from `package:nts`'s `NtsDnsPoolStats` shape and the line layout
  /// can evolve without touching this class. Routed through the same
  /// `_add` pipeline as observer callbacks for terminal / debug /
  /// session-log fan-out.
  void logDnsDelta(String detail) {
    _add(TelemetryKind.dnsStats, detail);
  }

  /// Records a [TelemetryKind.syncFailed] entry tagged
  /// `reconfigure: <detail>` so a re-init failure inside
  /// [TrustedTime.initialize] (called by the benchmarking UI's
  /// reconfigure path) is visible in the same terminal/log stream as
  /// SyncObserver-reported failures. The `reconfigure: ` prefix
  /// mirrors the engine's own `warm: ` convention for warming-phase
  /// failures, keeping all error rows visually grouped under the
  /// `syncFailed` kind. Does not call any cycle-end listeners — a
  /// reconfigure failure means the rotation loop should stop, not
  /// schedule another advance.
  void logReconfigureFailure(String detail) {
    _add(TelemetryKind.syncFailed, 'reconfigure: $detail');
  }

  void _add(TelemetryKind kind, String detail) {
    final event = TelemetryEvent(
      elapsedMs: _start.elapsedMilliseconds,
      kind: kind,
      detail: detail,
    );
    _events.add(event);
    _totalRecorded++;
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
    // Snapshot before iterating so a listener that synchronously calls
    // its disposer (which mutates _listeners via List.remove) cannot
    // throw ConcurrentModificationError mid-fanout. Mirrors the same
    // guard already in _notifyCycleEnded; closes trusted_time-dmc.
    //
    // Per-listener try/catch so a thrower (e.g. BenchmarkLogger
    // hitting a disk-full / permission-denied condition) cannot
    // abort the rest of the fan-out and bubble up through the
    // SyncObserver callbacks into the engine. In debug builds we
    // surface the failure via debugPrint so the cause is visible
    // during local development; in release builds we swallow
    // silently because telemetry recording is best-effort.
    for (final l in List<void Function(TelemetryEvent)>.of(_listeners)) {
      try {
        l(event);
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint(
            '[TelemetryRecorder] listener threw on event $event: $e\n$s',
          );
        }
      }
    }
    // Mirror to the Flutter console using the same single-line layout
    // that _TelemetryRow renders, so terminal logs can be copy-pasted
    // straight into bug reports during device testing. Gated on
    // kDebugMode so release builds do not leak telemetry to logcat /
    // oslog. Delegates to TelemetryEvent.toString so this layout, the
    // on-screen terminal, and BenchmarkLogger's on-disk transcript all
    // share one definition.
    if (kDebugMode) {
      debugPrint(event.toString());
    }
    notifyListeners();
  }

  /// Removes all recorded events from the visible buffer and resets
  /// the running event count, but **preserves the elapsed-time
  /// origin** so events from any in-flight sync cycle remain ordered
  /// consistently with events recorded after the reset.
  ///
  /// Resetting [_start] mid-cycle would cause callbacks for the
  /// in-flight cycle (sample / sourceFailed / consensus / metrics)
  /// to record `elapsedMs` values starting near zero even though
  /// they are chronologically in the middle of a cycle that began
  /// well before the reset. The on-screen terminal would surface
  /// the rewound ordering, and the BenchmarkLogger would persist it
  /// to disk. Clearing the visible window does not change when those
  /// events actually happened, so the recorder's elapsed-time origin
  /// is fixed at construction.
  void reset() {
    _events.clear();
    _totalRecorded = 0;
    notifyListeners();
  }

  @override
  void onSyncStarted() => _add(TelemetryKind.syncStarted, 'cycle started');

  @override
  void onSampleReceived(TimeSample sample) {
    // Per-NTS-handshake trust-anchor identifier. Always null for
    // non-NTS samples (NTP, HTTPS), so the row stays unchanged for
    // them; rendered for NTS samples so an operator can spot a
    // silent webpki-roots fallback in deployments that expect
    // platform-store enforcement (MDM-pinned CA, user-installed
    // root). Appended last so the existing window/auth columns
    // stay positionally stable for log parsers.
    final backend = sample.trustBackend;
    final backendField = backend == null ? '' : ' backend=${backend.name}';
    _add(
      TelemetryKind.sample,
      '${sample.sourceId} '
      'window=${sample.interval.endMs - sample.interval.startMs}ms '
      'auth=${sample.authLevel.name}$backendField',
    );
  }

  @override
  void onSourceFailed(String sourceId, Object error) {
    // TransientSourceError is the engine's signal that a source failure
    // (e.g. NTS DnsSaturation) was classified as transient and the
    // source will be retried on the next cycle without exponential
    // cooldown. Tag the row with `[transient, no cooldown]` so the
    // panel makes the cooldown bypass visually distinct from regular
    // failures, and unwrap `cause` so the rest of the formatter (NTS
    // per-phase tagging below) still applies to the underlying error.
    final isTransient = error is TransientSourceError;
    final tag = isTransient ? ' [transient, no cooldown]' : '';
    final cause = isTransient ? error.cause : error;
    // Surface the per-phase tag from package:nts so timeout failures
    // (DNS / connect / TLS / KE / NTP) are immediately distinguishable
    // in the terminal log without requiring the operator to decode the
    // sealed-class toString. The `phase` accessor is the public name
    // for the named-parameter payload on NtsErrorTimeout.
    if (cause is NtsErrorTimeout) {
      _add(
        TelemetryKind.sourceFailed,
        '$sourceId$tag: timeout during ${cause.phase.name}',
      );
      return;
    }
    _add(TelemetryKind.sourceFailed, '$sourceId$tag: $cause');
  }

  @override
  void onConsensusReached(ConsensusResult result) {
    // `quorum` is the sweep-depth used by the engine's quorum check;
    // `participants` is the stricter midpoint-containment count. They
    // diverge when one source's bimodal arrival latency widens the
    // window past where other sources' midpoints sit (skj.3).
    _add(
      TelemetryKind.consensus,
      'utc=${result.utc.toIso8601String()} '
      '±${result.uncertaintyMs}ms '
      'quorum=${result.quorumDepth} '
      'participants=${result.participantCount} '
      'groups=${result.groupCount}',
    );
  }

  @override
  void onMetricsReported(SyncMetrics metrics) {
    _add(
      TelemetryKind.metrics,
      'latency=${metrics.latencyMs}ms '
      'uncertainty=${metrics.uncertaintyMs}ms '
      'confidence=${metrics.confidence.name}',
    );
    _notifyCycleEnded();
  }

  @override
  void onSyncFailed(Object error) {
    _add(TelemetryKind.syncFailed, error.toString());
    _notifyCycleEnded();
  }

  void _notifyCycleEnded() {
    // Snapshot to a local list so a listener that disposes itself
    // mid-iteration cannot mutate the list we're walking. Per-
    // listener try/catch matches the _add fan-out so a thrower
    // cannot abort delivery to its peers; cycle-end listeners are
    // wired into application-level scheduling (see Section 7's
    // continuous-sync hook in main.dart) and a thrown exception
    // here would propagate out through the SyncObserver callback
    // that triggered the cycle-end and into engine code.
    for (final l in List<void Function()>.of(_cycleListeners)) {
      try {
        l();
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('[TelemetryRecorder] cycle-end listener threw: $e\n$s');
        }
      }
    }
  }
}
