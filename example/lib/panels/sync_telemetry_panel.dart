import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show NtsDnsPoolStats, ntsDnsPoolStats;
import 'package:trusted_time/trusted_time.dart';

import '../sync_telemetry.dart';
import 'dns_pool_stats_bar.dart';
import 'trust_status_bar.dart';

/// Terminal-style telemetry log: dark background, monospaced font,
/// auto-scrolls to the bottom whenever a new event is appended so the
/// most recent activity stays in view during long-running benchmarking
/// sessions. The scroll attachment piggy-backs on the recorder's
/// ChangeNotifier callback so we do not need a second listener layer.
class SyncTelemetryPanel extends StatefulWidget {
  /// Creates a terminal-style view over the supplied [recorder].
  const SyncTelemetryPanel({super.key, required this.recorder});

  /// Source of the telemetry events rendered by this panel.
  final TelemetryRecorder recorder;

  @override
  State<SyncTelemetryPanel> createState() => _SyncTelemetryPanelState();
}

class _SyncTelemetryPanelState extends State<SyncTelemetryPanel> {
  final ScrollController _scrollController = ScrollController();

  // Pixel slack from `maxScrollExtent` within which we still consider
  // the user to be "tailing" the log. One terminal row is ~16 px, so
  // 20 px keeps autoscroll active across normal scroll inertia and
  // touch jitter without grabbing the view back from an operator who
  // has scrolled up to inspect a specific failure.
  static const double _stickyThresholdPx = 20.0;

  // Tracks the recorder's monotonic event counter observed at the
  // previous build so the post-frame autoscroll fires only on growth.
  // Uses `totalEventsRecorded` (not `events.length`) because the
  // recorder's ring buffer saturates at 200 entries — once full,
  // `events.length` stops increasing and a length-based trigger would
  // silently disable autoscroll for the rest of the session. Without
  // this guard, every ChangeNotifier rebuild (e.g. `recorder.reset`)
  // would yank the viewport even though nothing was appended.
  int _lastEventSeq = 0;

  // Live snapshot of `package:nts`'s process-wide DNS resolver pool
  // counters. ntsDnsPoolStats() is documented as four atomic-relaxed
  // loads and explicitly endorsed for UI poll loops, so a 1 s timer
  // rather than coupling to telemetry events keeps the readout
  // responsive even when no syncs are firing. Null until the first
  // poll succeeds; stays null if NtsRustLib was never initialised
  // (NTS-disabled config path) or the FFI throws for any reason.
  NtsDnsPoolStats? _dnsStats;
  // Companion live snapshot of `package:nts`'s process-global
  // trust-anchor diagnostic state, polled on the same 1 s timer
  // because the same UI-poll-loop endorsement applies (three
  // atomic-relaxed loads under the hood). Surfaces the singleton
  // backend identity, Android JNI bootstrap success bit, and
  // hybrid-fallback counter; null on the same conditions as
  // `_dnsStats` so the readout degrades gracefully on the
  // NTS-disabled / NtsRustLib-uninitialised path.
  NtsTrustStatus? _trustStatus;
  // Single 1 s timer that polls every `package:nts` diagnostic
  // surface this panel renders (currently DNS pool stats and the
  // trust-anchor status snapshot). Field name is deliberately
  // domain-neutral so future diagnostic snapshots can be folded
  // into the same tick without a misleading dns-specific identifier.
  Timer? _diagnosticsTicker;

  @override
  void initState() {
    super.initState();
    _diagnosticsTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final dnsSnap = _safeReadDnsStats();
      final trustSnap = _safeReadTrustStatus();
      // Avoid a setState rebuild when neither snapshot has changed —
      // every other source of work in this panel is event-driven,
      // so an idle period should not cost a frame per second.
      if (dnsSnap == _dnsStats && trustSnap == _trustStatus) return;
      setState(() {
        _dnsStats = dnsSnap;
        _trustStatus = trustSnap;
      });
    });
  }

  @override
  void dispose() {
    _diagnosticsTicker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Reads `package:nts`'s DNS pool snapshot. Returns null instead of
  /// rethrowing on any failure (NtsRustLib not initialised, FFI error,
  /// etc.) so the UI degrades gracefully when NTS is disabled in the
  /// active config.
  NtsDnsPoolStats? _safeReadDnsStats() {
    try {
      return ntsDnsPoolStats();
    } catch (_) {
      return null;
    }
  }

  /// Companion of [_safeReadDnsStats] for the trust-status snapshot.
  /// `TrustedTime.ntsTrustStatus()` is documented as throwing
  /// `StateError` if `NtsRustLib.init()` has not completed, so guard
  /// the same way the DNS pool reader does.
  NtsTrustStatus? _safeReadTrustStatus() {
    try {
      return TrustedTime.ntsTrustStatus();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.recorder,
      builder: (context, _) {
        final events = widget.recorder.events;
        final seq = widget.recorder.totalEventsRecorded;
        final grew = seq > _lastEventSeq;
        _lastEventSeq = seq;

        if (grew) {
          // Capture the sticky-bottom decision from the *pre-append*
          // scroll geometry: the post-frame callback runs after the
          // ListView has laid out the new row, by which point
          // maxScrollExtent has grown by ~one row. If we computed
          // `wasNearBottom` inside the callback, an operator parked
          // exactly at the bottom would see (newMax - oldPixels) ==
          // newRowHeight, which exceeds _stickyThresholdPx and
          // wrongly flips the decision to "not near bottom". The
          // hasClients guard short-circuits the very first build
          // (controller not yet attached), in which case we skip the
          // jump entirely — the initial layout already lands at
          // offset 0 with no content above it.
          final wasNearBottom =
              _scrollController.hasClients &&
              (_scrollController.position.maxScrollExtent -
                      _scrollController.position.pixels) <=
                  _stickyThresholdPx;
          if (wasNearBottom) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_scrollController.hasClients) return;
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            });
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Terminal log — autoscrolls to newest event when '
                    'parked at the bottom; scroll up to pin the view. '
                    'Warm-phase failures show as "warm: ..." on the '
                    'sourceFailed line.',
                    style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear telemetry',
                  icon: const Icon(Icons.clear_all),
                  onPressed: widget.recorder.reset,
                ),
              ],
            ),
            const SizedBox(height: 6),
            DnsPoolStatsBar(stats: _dnsStats),
            const SizedBox(height: 4),
            TrustStatusBar(status: _trustStatus),
            const SizedBox(height: 8),
            Container(
              height: 260,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0E0E0E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white12),
              ),
              child: events.isEmpty
                  ? const Center(
                      child: Text(
                        'No events recorded yet.',
                        style: TextStyle(
                          color: Colors.grey,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: events.length,
                      itemBuilder: (context, i) =>
                          _TelemetryRow(event: events[i]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TelemetryRow extends StatelessWidget {
  const _TelemetryRow({required this.event});

  final TelemetryEvent event;

  Color _colorFor(TelemetryKind kind) {
    switch (kind) {
      case TelemetryKind.syncStarted:
        return Colors.blueAccent;
      case TelemetryKind.sample:
        return Colors.greenAccent;
      case TelemetryKind.sourceFailed:
        return Colors.orangeAccent;
      case TelemetryKind.consensus:
        return Colors.cyanAccent;
      case TelemetryKind.metrics:
        return Colors.purpleAccent;
      case TelemetryKind.syncFailed:
        return Colors.redAccent;
      case TelemetryKind.waiting:
        return Colors.amberAccent;
      case TelemetryKind.dnsStats:
        return Colors.tealAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '${event.elapsedMs.toString().padLeft(7)}ms  '
        '${event.kind.name.padRight(13)}  ${event.detail}',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: _colorFor(event.kind),
        ),
      ),
    );
  }
}
