import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' show NtsDnsPoolStats, ntsDnsPoolStats;
import 'package:trusted_time/trusted_time.dart';

import 'benchmark_logger.dart';
import 'nts_sources.dart';
import 'sync_telemetry.dart';

/// Orchestration behind Section 7 — Benchmarking Configuration.
///
/// Owns the server selection, the continuous-sync loop, the Worldwide
/// Beauty Parade rotation, and the engine reconfigures those drive. The
/// host widget keeps only presentation concerns and rebuilds through a
/// [ListenableBuilder]; every state mutation here ends in
/// [notifyListeners] where the widget-owned version used `setState`.
///
/// Lifetime is tied to the host widget: [start] wires the cycle-end hook
/// and opens the session log, [dispose] tears both down along with any
/// pending inter-cycle timer.
class BenchmarkController extends ChangeNotifier {
  BenchmarkController({required TelemetryRecorder telemetry})
    : _telemetry = telemetry;

  final TelemetryRecorder _telemetry;

  /// Invoked when a reconfigure fails, with the formatted error text.
  /// The host widget surfaces this as a snack bar; the controller has no
  /// [BuildContext] of its own.
  void Function(String message)? onReconfigureFailure;

  /// [_selectedServers] is seeded from `TrustedTime.config.ntsServers`,
  /// i.e. the live engine configuration as it stands when this
  /// controller is constructed. Because `main()` awaits
  /// `TrustedTime.initialize(...)` before `runApp(...)`, the engine's
  /// active host set is always available by the time this field
  /// initialiser runs. This decouples the chip selection from the
  /// particular bootstrap constant (`curatedNtsPool`) so a future
  /// change to the bootstrap pool — or a runtime reconfiguration —
  /// automatically propagates to the chip state instead of silently
  /// diverging from the live engine. The chip grid itself renders the
  /// union of curated and extended pools so every host the operator
  /// might reach for is representable.
  final Set<String> _selectedServers = Set<String>.of(
    TrustedTime.config.ntsServers,
  );

  /// [_continuousSyncEnabled] gates the cycle-end auto-resync hook,
  /// which is wired in [start] via the recorder's cycle-end listener
  /// so it survives reconfiguration cycles without re-subscription.
  bool _continuousSyncEnabled = false;
  bool _reconfiguring = false;

  /// Inter-cycle delay between continuous syncs. Investigative knob for
  /// observing per-server recovery behaviour and avoiding KE-server
  /// rate-limiting during long-form runs. The 5 s default lines up with
  /// the engine's per-source cooldown granularity; 0 reproduces the
  /// previous immediate-resync behaviour.
  int _interCycleDelaySeconds = 5;
  Timer? _interCycleTimer;
  VoidCallback? _cycleEndDisposer;

  /// Worldwide Beauty Parade rotation state. When
  /// [worldwideRotationActive] is true, every cycle-end advances
  /// [worldwideRotationOffset] by [worldwideSubsetSize] and
  /// reconfigures the engine with the next contiguous slice of
  /// [extendedNtsPool] (wrapping at the end). The chip-driven
  /// [selectedServers] is intentionally not touched in this mode; the
  /// chips remain the manual-mode UI, and the worldwide card's own
  /// status line is the source of truth for what the engine is
  /// currently syncing against.
  static const int worldwideSubsetSize = 8;
  bool _worldwideRotationActive = false;
  int _worldwideRotationOffset = 0;

  /// Per-slice DNS pool delta tracking. Snapshot is taken at the tail of
  /// every rotation reconfigure; the next advance computes deltas
  /// against this snapshot before taking a fresh one. Logged through
  /// [TelemetryRecorder.logDnsDelta] so the per-slice DNS-pool
  /// behaviour (refusals, recoveries, in-flight high-water mark)
  /// appears in the on-screen terminal and the persisted session log
  /// alongside the slice's NTS-KE / NTP outcomes. Null until the
  /// first reconfigure inside a rotation run.
  NtsDnsPoolStats? _lastSliceDnsSnapshot;
  int? _lastSliceDnsOffset;

  /// Optional manual override for the engine's unified DNS lookup
  /// budget, forwarded as TrustedTimeConfig.maxConcurrentDnsLookups on
  /// the next reconfigure (ADR 0008). Null leaves the engine on its
  /// default budget (TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups).
  /// Investigative knob for diagnosing DNS-pool starvation observed
  /// via `DnsPoolStatsBar` (rising `refused`) versus genuine
  /// server-side timeouts.
  int? _maxConcurrentDnsLookupsOverride;

  final BenchmarkLogger _benchmarkLogger = BenchmarkLogger();

  bool _disposed = false;

  Set<String> get selectedServers => UnmodifiableSetView(_selectedServers);
  bool get continuousSyncEnabled => _continuousSyncEnabled;
  bool get reconfiguring => _reconfiguring;
  int get interCycleDelaySeconds => _interCycleDelaySeconds;
  bool get worldwideRotationActive => _worldwideRotationActive;
  int get worldwideRotationOffset => _worldwideRotationOffset;
  int? get maxConcurrentDnsLookupsOverride => _maxConcurrentDnsLookupsOverride;
  String? get logFilePath => _benchmarkLogger.filePath;

  /// Wires the continuous-benchmarking cycle-end hook and opens the
  /// per-session log file. Called once from the host widget's
  /// `initState`.
  void start() {
    // Section 7: continuous benchmarking — schedule a forceResync at
    // the end of every cycle, after the configurable inter-cycle
    // delay. The recorder fires onCycleEnd from both
    // onMetricsReported (success) and onSyncFailed (failure), so this
    // covers every cycle outcome. The Timer (rather than a microtask)
    // gives us a cancellation handle so toggling continuous mode off
    // mid-delay, applying a new server selection, or disposing the
    // widget cannot race a forceResync against a torn-down engine.
    _cycleEndDisposer = _telemetry.addCycleEndListener(_scheduleNextCycle);

    // Open the per-session log file and mirror every TelemetryEvent
    // through it. Failures (sandboxed test envs, denied storage, etc.)
    // are swallowed so the UI still functions when path_provider has
    // no platform implementation.
    unawaited(_startBenchmarkLogger());
  }

  Future<void> _startBenchmarkLogger() async {
    try {
      await _benchmarkLogger.start(_telemetry);
    } catch (_) {
      // Logger remains disposed; UI is unaffected.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelInterCycleTimer();
    _cycleEndDisposer?.call();
    if (_continuousSyncEnabled) {
      // Continuous mode pauses the engine's refresh timer so the
      // inter-cycle slider is the sole scheduler (see
      // [setContinuousSync]). Tearing down the scheduler without
      // restoring the timer would leave the engine with nothing
      // driving refreshes at all, so the pause is unwound here as
      // well as on the toggle-off path.
      TrustedTime.resumeAutomaticRefresh();
    }
    unawaited(_benchmarkLogger.dispose());
    super.dispose();
  }

  void toggleServer(String host, bool picked) {
    if (picked) {
      _selectedServers.add(host);
    } else {
      _selectedServers.remove(host);
    }
    notifyListeners();
  }

  void setInterCycleDelaySeconds(int value) {
    _interCycleDelaySeconds = value;
    notifyListeners();
  }

  void setMaxConcurrentDnsLookupsOverride(int? value) {
    _maxConcurrentDnsLookupsOverride = value;
    notifyListeners();
  }

  /// Flips continuous benchmarking on or off.
  ///
  /// Defence in depth: the SwitchListTile passes null to onChanged
  /// while [reconfiguring] (see BenchmarkingPanel) so the user can't
  /// fire this path during a re-init window. Re-check here to keep the
  /// contract enforced even if the caller forgets to wire the disable,
  /// since the body calls into TrustedTime methods that would hit a
  /// disposed engine instance during initialize().
  void setContinuousSync(bool enabled) {
    if (_reconfiguring) return;
    _continuousSyncEnabled = enabled;
    if (!enabled) {
      // Stopping continuous sync also stops the worldwide rotation;
      // the rotation cannot advance without the cycle-end hook firing.
      _worldwideRotationActive = false;
    }
    notifyListeners();
    if (enabled) {
      // Suppress the engine's internal refresh timer for the duration
      // of continuous mode so the slider's inter-cycle delay is the
      // sole scheduler. Without this the engine's refreshInterval
      // (30 s here) raced the slider, collapsing the configured
      // cadence to whichever timer fired first.
      TrustedTime.pauseAutomaticRefresh();
      // Kick the loop immediately rather than waiting for the
      // slider's first inter-cycle delay.
      _forceResyncSafely();
    } else {
      // Restore the engine's automatic cadence so a long-idle app
      // still refreshes its anchor.
      TrustedTime.resumeAutomaticRefresh();
      // Drop any pending inter-cycle timer so the loop stops right
      // now, not after the current delay.
      _cancelInterCycleTimer();
    }
  }

  /// Cycle-end hook for non-rotation continuous benchmarking. Cancels
  /// any existing pending timer first so back-to-back cycle-end
  /// notifications cannot stack delays. With delay == 0 we still
  /// funnel through `Timer` so the cancel-on-toggle-off and
  /// cancel-on-dispose guarantees stay uniform; the engine's own
  /// state machine has already unwound by the time the zero-duration
  /// timer fires.
  ///
  /// Bypassed in worldwide rotation mode: the next rotation step is
  /// scheduled by [_reconfigureEngine] when init returns, so the
  /// engine's internal exponential-backoff retries (which fire
  /// onCycleEnd well before [interCycleDelaySeconds]) cannot reset
  /// the rotation timer and stall it on a slice whose hosts are all
  /// failing.
  /// The [_disposed] guard is load-bearing rather than defensive: the
  /// recorder snapshots its cycle-end listener list before fanning
  /// out, so a cycle that ends while we are tearing down still
  /// delivers here after our disposer has run. Without the early
  /// return that late delivery would emit a cycle-delay log entry and
  /// arm a timer whose only remaining job is to bail out.
  void _scheduleNextCycle() {
    if (_disposed) return;
    if (_worldwideRotationActive) return;
    _cancelInterCycleTimer();
    if (!_continuousSyncEnabled || _reconfiguring) return;
    final seconds = _interCycleDelaySeconds;
    if (seconds > 0) {
      _telemetry.logCycleDelay(seconds);
    }
    _interCycleTimer = Timer(Duration(seconds: seconds), () {
      _interCycleTimer = null;
      if (_disposed) return;
      if (!_continuousSyncEnabled || _reconfiguring) return;
      _forceResyncSafely();
    });
  }

  /// Fire-and-forget [TrustedTime.forceResync] for the cycle-end and
  /// continuous-toggle paths. Sync failures already surface through
  /// the SyncObserver fan-out (TelemetryRecorder records them as
  /// `syncFailed` events for both the on-screen terminal and the
  /// persisted session log), so swallowing them here only prevents
  /// the otherwise-redundant unhandled async error from escaping to
  /// the zone. debugPrint preserves the trace for local development.
  void _forceResyncSafely() {
    unawaited(
      TrustedTime.forceResync().catchError((Object e, StackTrace s) {
        if (kDebugMode) {
          debugPrint('[example] forceResync failed: $e\n$s');
        }
      }),
    );
  }

  /// Schedules the next rotation advance, called from
  /// [_reconfigureEngine] when init returns. Anchors the rotation
  /// clock to reconfigure-completion rather than cycle-end events,
  /// so engine-internal retries inside the slice cannot reset it.
  /// When the timer fires it advances [worldwideRotationOffset] and
  /// reconfigures the engine to the next slice — which in turn
  /// schedules the following advance, perpetuating the rotation
  /// loop until either continuous sync is toggled off or rotation
  /// mode is exited.
  void _scheduleRotationAdvance() {
    _cancelInterCycleTimer();
    if (!_continuousSyncEnabled ||
        !_worldwideRotationActive ||
        _reconfiguring) {
      return;
    }
    final seconds = _interCycleDelaySeconds;
    if (seconds > 0) {
      _telemetry.logCycleDelay(seconds);
    }
    _interCycleTimer = Timer(Duration(seconds: seconds), () {
      _interCycleTimer = null;
      if (_disposed) return;
      if (!_continuousSyncEnabled ||
          !_worldwideRotationActive ||
          _reconfiguring) {
        return;
      }
      _logSliceDnsDeltaIfAvailable();
      _worldwideRotationOffset =
          (_worldwideRotationOffset + worldwideSubsetSize) %
          extendedNtsPool.length;
      notifyListeners();
      unawaited(_reconfigureEngine(_currentWorldwideSubset()));
    });
  }

  /// Computes the DNS pool counter deltas accumulated during the slice
  /// that just ended (between the snapshot taken at its reconfigure
  /// tail and now) and logs them through the telemetry recorder.
  /// No-op when no prior snapshot exists (first slice of a run) or
  /// when the snapshot read failed.
  void _logSliceDnsDeltaIfAvailable() {
    final prev = _lastSliceDnsSnapshot;
    final prevOffset = _lastSliceDnsOffset;
    if (prev == null || prevOffset == null) return;
    final now = _readDnsStatsOrNull();
    if (now == null) return;
    final refusedDelta = now.refused - prev.refused;
    final recoveredDelta = now.recovered - prev.recovered;
    final hwmDelta = now.highWaterMark - prev.highWaterMark;
    // Match the wrap-aware slice math in _currentWorldwideSubset so
    // the logged label accurately describes the hosts measured.
    // When the slice wraps the end of the pool we render it as two
    // contiguous ranges (e.g. "slice 76-80, 0-2") rather than
    // collapsing to a clamped single range that would silently hide
    // the wrap-around.
    final poolLen = extendedNtsPool.length;
    const size = worldwideSubsetSize;
    final String sliceLabel;
    if (prevOffset + size <= poolLen) {
      sliceLabel = 'slice $prevOffset–${prevOffset + size - 1}';
    } else {
      final wrapEnd = (prevOffset + size) % poolLen - 1;
      sliceLabel = 'slice $prevOffset–${poolLen - 1}, 0–$wrapEnd';
    }
    _telemetry.logDnsDelta(
      '$sliceLabel '
      'refused+$refusedDelta recovered+$recoveredDelta '
      'hwmΔ$hwmDelta inFlight=${now.inFlight}',
    );
  }

  void _cancelInterCycleTimer() {
    _interCycleTimer?.cancel();
    _interCycleTimer = null;
  }

  /// Starts the Worldwide Beauty Parade: rotation mode that cycles the
  /// engine through fixed-size subsets of [extendedNtsPool] so every
  /// host gets isolated, contention-free measurements over a long-form
  /// run. Each cycle reconfigures the engine with the next contiguous
  /// slice of the pool (wrapping at the end); per-source telemetry
  /// accumulated by the recorder can then be aggregated to rank hosts
  /// by latency and reliability.
  ///
  /// Leaves [selectedServers] (the chip selection) untouched so the
  /// operator's manual subset is preserved for an immediate switch
  /// back via Apply Selection. To stop the rotation: flip Continuous
  /// Sync off via the toggle below the chip grid, or press Apply
  /// Selection on the manual chip set.
  Future<void> runWorldwideBenchmark() async {
    if (_reconfiguring) return;
    _worldwideRotationActive = true;
    _worldwideRotationOffset = 0;
    _continuousSyncEnabled = true;
    notifyListeners();
    await _reconfigureEngine(_currentWorldwideSubset());
  }

  /// Returns the current rotation slice of [extendedNtsPool] starting
  /// at [worldwideRotationOffset]. Wraps around so the slice always
  /// has [worldwideSubsetSize] hosts even when the offset is near the
  /// end of the pool, which keeps cycle-to-cycle quorum availability
  /// uniform.
  List<String> _currentWorldwideSubset() {
    final pool = extendedNtsPool;
    const size = worldwideSubsetSize;
    final start = _worldwideRotationOffset % pool.length;
    if (start + size <= pool.length) {
      return pool.sublist(start, start + size);
    }
    return [
      ...pool.sublist(start),
      ...pool.sublist(0, (start + size) % pool.length),
    ];
  }

  /// Re-initialises the engine with the current Section 7 selection so
  /// the next sync cycle uses exactly those servers. Exits rotation
  /// mode if it was active — manual Apply Selection is the explicit
  /// "go back to chip-driven control" gesture. Delegates to
  /// [_reconfigureEngine] for the actual init.
  Future<void> applySelectedServers() async {
    if (_selectedServers.isEmpty || _reconfiguring) return;
    if (_worldwideRotationActive) {
      _worldwideRotationActive = false;
      notifyListeners();
    }
    await _reconfigureEngine(_selectedServers.toList());
  }

  /// Disposes the previous TrustedTime instance and re-initialises it
  /// against [servers]. TrustedTimeImpl's internal init() disposes the
  /// previous instance before constructing a new one, so timers,
  /// integrity subscriptions, and source warm state all reset
  /// cleanly. The observer set lives on the instance and is therefore
  /// lost across re-init; we re-register the telemetry recorder
  /// afterwards. [reconfiguring] gates the continuous-sync hook so a
  /// cycle that completes during the dispose window cannot trigger a
  /// forceResync against a disposed engine.
  ///
  /// Shared between manual Apply Selection (chip-driven), the initial
  /// Run Worldwide Beauty Parade press, and every per-cycle rotation
  /// step inside the worldwide mode.
  Future<void> _reconfigureEngine(List<String> servers) async {
    if (servers.isEmpty || _reconfiguring) return;
    // Drop any in-flight inter-cycle timer so it cannot fire a
    // forceResync against the engine instance we are about to dispose.
    _cancelInterCycleTimer();
    _reconfiguring = true;
    notifyListeners();
    var failed = false;
    try {
      final shuffled = (List<String>.of(
        servers,
      )..shuffle(Random())).toList(growable: false);
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: shuffled,
          maxConcurrentDnsLookups: _maxConcurrentDnsLookupsOverride,
          minimumQuorum: 2,
          minQuorumRatio: 0.4,
          refreshInterval: const Duration(seconds: 30),
          persistState: true,
        ),
      );
      TrustedTime.registerObserver(_telemetry);
      // Pause state is reset on every TrustedTime.initialize() by
      // design (see TrustedTime.pauseAutomaticRefresh docs). When
      // continuous sync is on, re-pause immediately so the engine's
      // refresh timer does not race the inter-cycle slider — the
      // slider becomes the sole scheduler for the next cycle.
      if (_continuousSyncEnabled) {
        TrustedTime.pauseAutomaticRefresh();
      }
    } catch (e, s) {
      // Centralised catch so a failed re-init cannot bubble up as an
      // unhandled async error from any of this method's call sites
      // (manual Apply Selection, Run Worldwide press, or the
      // unawaited _scheduleRotationAdvance step). Keeping the
      // recovery here rather than at every .catchError site means
      // the rotation/continuous-flag teardown is identical across
      // entry points.
      failed = true;
      if (kDebugMode) {
        debugPrint('[example] TrustedTime.initialize failed: $e\n$s');
      }
      _telemetry.logReconfigureFailure(e.toString());
      if (!_disposed) {
        // Stop the rotation loop and continuous mode so a
        // persistently-failing config doesn't spin forever firing
        // the same failure on every advance. The operator can
        // re-arm by pressing Apply Selection or Run Worldwide
        // again with a different chip set.
        _worldwideRotationActive = false;
        _continuousSyncEnabled = false;
        notifyListeners();
        onReconfigureFailure?.call('Reconfigure failed: $e');
      }
    } finally {
      if (!_disposed) {
        _reconfiguring = false;
        notifyListeners();
      }
    }
    if (failed) return;
    // Anchor the rotation clock to reconfigure-completion. This must
    // run after _reconfiguring is cleared so the schedule check
    // inside _scheduleRotationAdvance does not bail out.
    if (!_disposed && _worldwideRotationActive && _continuousSyncEnabled) {
      // Snapshot the DNS pool counters for this slice so the next
      // rotation advance can log the deltas. Captures `inFlight`
      // immediately after reconfigure rather than at the very
      // start of the slice's first NTS calls; the small overlap is
      // acceptable because the deltas are computed across the same
      // boundary on every step.
      _lastSliceDnsSnapshot = _readDnsStatsOrNull();
      _lastSliceDnsOffset = _worldwideRotationOffset;
      _scheduleRotationAdvance();
    }
  }

  /// Reads `package:nts`'s DNS pool snapshot, returning null on any
  /// failure (NtsRustLib not initialised, FFI error). Mirrors the same
  /// guard used by the telemetry panel's live readout so a failure
  /// here cannot crash a benchmark in progress.
  NtsDnsPoolStats? _readDnsStatsOrNull() {
    try {
      return ntsDnsPoolStats();
    } catch (_) {
      return null;
    }
  }
}
