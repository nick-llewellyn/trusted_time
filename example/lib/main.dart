import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show DebugPrintCallback, debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show NtsDnsPoolStats, ntsDnsPoolStats;
import 'package:trusted_time/trusted_time.dart';
import 'background_sync_file_log.dart';
import 'benchmark_logger.dart';
import 'burst/burst_probe_panel.dart';
import 'nts_sources.dart';
import 'panels/background_sync_log_panel.dart';
import 'panels/benchmarking_panel.dart';
import 'panels/sync_telemetry_panel.dart';
import 'sync_telemetry.dart';

/// Builds the NTS-exclusive stress-test configuration.
///
/// NTP sources are disabled so the engine relies solely on
/// cryptographically authenticated samples. minQuorumRatio is 0.4, which
/// (combined with MarzulloEngine's hard floor of requiredQuorum >= 2) means
/// at least three samples must arrive in a cycle before consensus is
/// possible, and at least two of those three must overlap.
///
/// Shared between the foreground engine ([main]) and the headless
/// background callback ([trustedTimeBackgroundCallback]) so a background
/// fire refreshes the anchor against the same source policy the foreground
/// engine uses. The pool is shuffled per call so warming-pipeline ordering
/// effects still surface across launches, but every source is used every
/// cycle so diagnostic comparisons are not confounded by random subset
/// selection.
TrustedTimeConfig buildStressConfig() {
  final ntsSubset = (List<String>.of(
    curatedNtsPool,
  )..shuffle(Random())).toList(growable: false);
  return TrustedTimeConfig(
    ntpServers: const [],
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
/// callback handle persisted in `SharedPreferences`/`UserDefaults` resolves.
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

/// Renders a signed drift rate as parts-per-million, e.g. `+12.3 ppm`
/// or `-4.2 ppm`. Only the plus needs adding: toStringAsFixed already
/// renders the minus for negative values.
String _formatPpm(double rate) {
  final ppm = rate * 1e6;
  final sign = ppm >= 0 ? '+' : '';
  return '$sign${ppm.toStringAsFixed(1)} ppm';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await TrustedTime.initialize(config: buildStressConfig());

  // Pre-register the background callback so subsequent calls to
  // `enableBackgroundSync` perform a real headless anchor refresh rather
  // than no-oping when the OS scheduler fires.
  await TrustedTime.registerBackgroundCallback(trustedTimeBackgroundCallback);

  // Verification hook: --dart-define=BG_SYNC_MINUTES=15 auto-schedules the
  // native periodic background sync at startup (floored to WorkManager's
  // 15-min minimum), so the recurring headless path can be observed
  // unattended without tapping the Section 5 switch. A normal launch
  // (define absent) does nothing here and keeps the switch-driven 24h flow.
  const bgSyncMinutes = int.fromEnvironment('BG_SYNC_MINUTES', defaultValue: 0);
  if (bgSyncMinutes > 0) {
    await TrustedTime.enableBackgroundSync(
      interval: Duration(minutes: bgSyncMinutes),
    );
  }

  // Register telemetry after init so the recorder receives every
  // subsequent sync cycle (refreshes, Force Resync, integrity-triggered
  // syncs). The very first bootstrap sync's onSyncStarted is missed:
  // initialize() resolves without waiting for the detached first
  // cycle, whose start precedes this registration.
  //
  // The recorder is intentionally root-scoped and never disposed: its
  // SyncObserver registration is process-wide, so disposing it from a
  // widget's dispose() would silence the fan-out across hot-reloads
  // and HomePage rebuilds. The custom listener registries (_listeners,
  // _cycleListeners) are disposed by their consumers (the cycle-end
  // disposer in _HomePageState.dispose), and ChangeNotifier listeners
  // attached via ListenableBuilder auto-detach with their parents, so
  // the missing dispose here does not leak per-build subscriptions.
  final telemetry = TelemetryRecorder();
  TrustedTime.registerObserver(telemetry);

  runApp(MyApp(telemetry: telemetry));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.telemetry});

  final TelemetryRecorder telemetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrustedTime V2 Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomePage(telemetry: telemetry),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.telemetry});

  final TelemetryRecorder telemetry;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Refreshed by the ticker (and an initState probe): the single
  // pull-model snapshot driving Sections 1–3. Never null after the
  // first build; getAssessment() is total (no not-ready throw).
  TimeAssessment _assessment = TrustedTime.getAssessment();
  Timer? _ticker;
  bool _bgSyncEnabled = false;

  // Section 7 — Benchmarking Configuration state.
  //
  // [_selectedServers] is seeded from `TrustedTime.config.ntsServers`,
  // i.e. the live engine configuration as it stands when the home
  // page is constructed. Because `main()` awaits
  // `TrustedTime.initialize(...)` before `runApp(...)`, the engine's
  // active host set is always available by the time this field
  // initialiser runs. This decouples the chip selection from the
  // particular bootstrap constant (`curatedNtsPool`) so a future
  // change to the bootstrap pool — or a runtime reconfiguration —
  // automatically propagates to the chip state instead of silently
  // diverging from the live engine. The chip grid itself renders the
  // union of curated and extended pools so every host the operator
  // might reach for is representable.
  // [_continuousSyncEnabled] gates the cycle-end auto-resync hook,
  // which is wired in initState via the recorder's cycle-end listener
  // so it survives reconfiguration cycles without re-subscription.
  final Set<String> _selectedServers = Set<String>.of(
    TrustedTime.config.ntsServers,
  );
  bool _continuousSyncEnabled = false;
  bool _reconfiguring = false;
  // Inter-cycle delay between continuous syncs. Investigative knob for
  // observing per-server recovery behaviour and avoiding KE-server
  // rate-limiting during long-form runs. The 5 s default lines up with
  // the engine's per-source cooldown granularity; 0 reproduces the
  // previous immediate-resync behaviour.
  int _interCycleDelaySeconds = 5;
  Timer? _interCycleTimer;
  VoidCallback? _cycleEndDisposer;
  // Worldwide Beauty Parade rotation state. When [_worldwideRotationActive]
  // is true, every cycle-end advances [_worldwideRotationOffset] by
  // [_worldwideSubsetSize] and reconfigures the engine with the next
  // contiguous slice of [extendedNtsPool] (wrapping at the end). The
  // chip-driven [_selectedServers] is intentionally not touched in this
  // mode; the chips remain the manual-mode UI, and the worldwide card's
  // own status line is the source of truth for what the engine is
  // currently syncing against.
  static const int _worldwideSubsetSize = 8;
  bool _worldwideRotationActive = false;
  int _worldwideRotationOffset = 0;

  // Per-slice DNS pool delta tracking. Snapshot is taken at the tail of
  // every rotation reconfigure; the next advance computes deltas
  // against this snapshot before taking a fresh one. Logged through
  // [TelemetryRecorder.logDnsDelta] so the per-slice DNS-pool
  // behaviour (refusals, recoveries, in-flight high-water mark)
  // appears in the on-screen terminal and the persisted session log
  // alongside the slice's NTS-KE / NTP outcomes. Null until the
  // first reconfigure inside a rotation run.
  NtsDnsPoolStats? _lastSliceDnsSnapshot;
  int? _lastSliceDnsOffset;

  // Optional manual override for the engine's unified DNS lookup
  // budget, forwarded as TrustedTimeConfig.maxConcurrentDnsLookups on
  // the next reconfigure (ADR 0008). Null leaves the engine on its
  // default budget (TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups).
  // Investigative knob for diagnosing DNS-pool starvation observed
  // via `DnsPoolStatsBar` (rising `refused`) versus genuine
  // server-side timeouts.
  int? _maxConcurrentDnsLookupsOverride;

  final BenchmarkLogger _benchmarkLogger = BenchmarkLogger();

  final TextEditingController _tzController = TextEditingController(
    text: 'America/New_York',
  );
  String _tzResult = 'Enter timezone and press Convert';

  @override
  void initState() {
    super.initState();

    // Section 1/2: pull-model clock. One assessment per second drives
    // the live clock, the trust badge, and the status forensics card —
    // getAssessment() is total, so no trusted-state pre-check is
    // needed and an unanchored engine simply yields time == null with
    // the explanatory reason.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _assessment = TrustedTime.getAssessment();
      });
    });

    // Section 7: continuous benchmarking — schedule a forceResync at
    // the end of every cycle, after the configurable inter-cycle
    // delay. The recorder fires onCycleEnd from both
    // onMetricsReported (success) and onSyncFailed (failure), so this
    // covers every cycle outcome. The Timer (rather than a microtask)
    // gives us a cancellation handle so toggling continuous mode off
    // mid-delay, applying a new server selection, or disposing the
    // widget cannot race a forceResync against a torn-down engine.
    _cycleEndDisposer = widget.telemetry.addCycleEndListener(
      _scheduleNextCycle,
    );

    // Open the per-session log file and mirror every TelemetryEvent
    // through it. Failures (sandboxed test envs, denied storage, etc.)
    // are swallowed so the UI still functions when path_provider has
    // no platform implementation.
    unawaited(_startBenchmarkLogger());
  }

  Future<void> _startBenchmarkLogger() async {
    try {
      await _benchmarkLogger.start(widget.telemetry);
    } catch (_) {
      // Logger remains disposed; UI is unaffected.
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
  /// onCycleEnd well before [_interCycleDelaySeconds]) cannot reset
  /// the rotation timer and stall it on a slice whose hosts are all
  /// failing.
  void _scheduleNextCycle() {
    if (_worldwideRotationActive) return;
    _cancelInterCycleTimer();
    if (!_continuousSyncEnabled || _reconfiguring) return;
    final seconds = _interCycleDelaySeconds;
    if (seconds > 0) {
      widget.telemetry.logCycleDelay(seconds);
    }
    _interCycleTimer = Timer(Duration(seconds: seconds), () {
      _interCycleTimer = null;
      if (!mounted) return;
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
  /// When the timer fires it advances [_worldwideRotationOffset] and
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
      widget.telemetry.logCycleDelay(seconds);
    }
    _interCycleTimer = Timer(Duration(seconds: seconds), () {
      _interCycleTimer = null;
      if (!mounted) return;
      if (!_continuousSyncEnabled ||
          !_worldwideRotationActive ||
          _reconfiguring) {
        return;
      }
      _logSliceDnsDeltaIfAvailable();
      setState(() {
        _worldwideRotationOffset =
            (_worldwideRotationOffset + _worldwideSubsetSize) %
            extendedNtsPool.length;
      });
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
    final size = _worldwideSubsetSize;
    final String sliceLabel;
    if (prevOffset + size <= poolLen) {
      sliceLabel = 'slice $prevOffset–${prevOffset + size - 1}';
    } else {
      final wrapEnd = (prevOffset + size) % poolLen - 1;
      sliceLabel = 'slice $prevOffset–${poolLen - 1}, 0–$wrapEnd';
    }
    widget.telemetry.logDnsDelta(
      '$sliceLabel '
      'refused+$refusedDelta recovered+$recoveredDelta '
      'hwmΔ$hwmDelta inFlight=${now.inFlight}',
    );
  }

  void _cancelInterCycleTimer() {
    _interCycleTimer?.cancel();
    _interCycleTimer = null;
  }

  @override
  void dispose() {
    _cancelInterCycleTimer();
    _cycleEndDisposer?.call();
    _ticker?.cancel();
    _tzController.dispose();
    unawaited(_benchmarkLogger.dispose());
    super.dispose();
  }

  Future<void> _forceSync() async {
    await TrustedTime.forceResync();
  }

  void _convertTimezone() {
    try {
      final local = TrustedTime.trustedLocalTimeIn(_tzController.text.trim());
      setState(() {
        _tzResult = 'Local Time: ${local.toString()}';
      });
    } catch (e) {
      setState(() {
        _tzResult = 'Error: $e';
      });
    }
  }

  /// Starts the Worldwide Beauty Parade: rotation mode that cycles the
  /// engine through fixed-size subsets of [extendedNtsPool] so every
  /// host gets isolated, contention-free measurements over a long-form
  /// run. Each cycle reconfigures the engine with the next contiguous
  /// slice of the pool (wrapping at the end); per-source telemetry
  /// accumulated by the recorder can then be aggregated to rank hosts
  /// by latency and reliability.
  ///
  /// Leaves [_selectedServers] (the chip selection) untouched so the
  /// operator's manual subset is preserved for an immediate switch
  /// back via Apply Selection. To stop the rotation: flip Continuous
  /// Sync off via the toggle below the chip grid, or press Apply
  /// Selection on the manual chip set.
  Future<void> _runWorldwideBenchmark() async {
    if (_reconfiguring) return;
    setState(() {
      _worldwideRotationActive = true;
      _worldwideRotationOffset = 0;
      _continuousSyncEnabled = true;
    });
    await _reconfigureEngine(_currentWorldwideSubset());
  }

  /// Returns the current rotation slice of [extendedNtsPool] starting
  /// at [_worldwideRotationOffset]. Wraps around so the slice always
  /// has [_worldwideSubsetSize] hosts even when the offset is near the
  /// end of the pool, which keeps cycle-to-cycle quorum availability
  /// uniform.
  List<String> _currentWorldwideSubset() {
    final pool = extendedNtsPool;
    final size = _worldwideSubsetSize;
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
  Future<void> _applySelectedServers() async {
    if (_selectedServers.isEmpty || _reconfiguring) return;
    if (_worldwideRotationActive) {
      setState(() => _worldwideRotationActive = false);
    }
    await _reconfigureEngine(_selectedServers.toList());
  }

  /// Disposes the previous TrustedTime instance and re-initialises it
  /// against [servers]. TrustedTimeImpl's internal init() disposes the
  /// previous instance before constructing a new one, so timers,
  /// integrity subscriptions, and source warm state all reset
  /// cleanly. The observer set lives on the instance and is therefore
  /// lost across re-init; we re-register the telemetry recorder
  /// afterwards. [_reconfiguring] gates the continuous-sync hook so a
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
    setState(() => _reconfiguring = true);
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
      TrustedTime.registerObserver(widget.telemetry);
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
      widget.telemetry.logReconfigureFailure(e.toString());
      if (mounted) {
        // Stop the rotation loop and continuous mode so a
        // persistently-failing config doesn't spin forever firing
        // the same failure on every advance. The operator can
        // re-arm by pressing Apply Selection or Run Worldwide
        // again with a different chip set.
        setState(() {
          _worldwideRotationActive = false;
          _continuousSyncEnabled = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reconfigure failed: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reconfiguring = false);
    }
    if (failed) return;
    // Anchor the rotation clock to reconfigure-completion. This must
    // run after _reconfiguring is cleared so the schedule check
    // inside _scheduleRotationAdvance does not bail out.
    if (mounted && _worldwideRotationActive && _continuousSyncEnabled) {
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

  @override
  Widget build(BuildContext context) {
    final assessment = _assessment;
    final isTrusted = assessment.isTrusted;

    return Scaffold(
      appBar: AppBar(title: const Text('TrustedTime V2 Features')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader('Section 1 — Live Clock'),
            _card(
              child: Column(
                children: [
                  Text(
                    assessment.time?.toIso8601String() ??
                        'Waiting for trusted time…',
                    style: const TextStyle(
                      fontSize: 20,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shield,
                        color: isTrusted ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isTrusted ? 'TRUSTED' : 'NOT TRUSTED / SYNCING',
                        style: TextStyle(
                          color: isTrusted ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => setState(() {
                          _assessment = TrustedTime.getAssessment();
                        }),
                        child: const Text('Assess Now'),
                      ),
                      ElevatedButton(
                        onPressed: _forceSync,
                        child: const Text('Force Resync'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _sectionHeader('Section 2 — Trust Status Forensics (F1)'),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reason: ${assessment.reason.name}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('Auth Level: ${assessment.authLevel.name}'),
                  Text('Confidence: ${assessment.confidence.name}'),
                  Text(
                    'Uncertainty: '
                    '${assessment.uncertainty?.inMilliseconds ?? 'N/A'} ms',
                  ),
                  Text(
                    'Anchor Age: '
                    '${assessment.anchorAge?.inSeconds ?? 'N/A'} s',
                  ),
                  if (assessment.driftRate != null) ...[
                    Text(
                      'Drift Rate: '
                      '${_formatPpm(assessment.driftRate!)}',
                    ),
                    Text(
                      'Drift-Corrected Time: '
                      '${assessment.driftCorrectedTime!.toIso8601String()}',
                    ),
                  ] else
                    const Text(
                      'No drift rate yet '
                      '(needs ≥1h observed span this boot)',
                    ),
                ],
              ),
            ),
            _sectionHeader('Section 4 — Timezone-Proof Local Time (F6)'),
            _card(
              child: Column(
                children: [
                  TextField(
                    controller: _tzController,
                    decoration: const InputDecoration(
                      labelText: 'IANA Timezone (e.g. Asia/Tokyo)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _tzResult,
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _convertTimezone,
                    child: const Text('Convert'),
                  ),
                ],
              ),
            ),
            _sectionHeader('Section 5 — Background Sync (F4)'),
            _card(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _bgSyncEnabled
                        ? 'Background sync enabled (24h)'
                        : 'Background sync off',
                  ),
                  Switch(
                    value: _bgSyncEnabled,
                    onChanged: (val) {
                      setState(() {
                        _bgSyncEnabled = val;
                      });
                      if (val) {
                        // Verification hook: --dart-define=BG_SYNC_MINUTES=15
                        // requests a fast cadence (floored to WorkManager's
                        // 15-min minimum) so the periodic headless path can be
                        // observed over a short window. Defaults to 24h — a
                        // normal launch is unaffected.
                        const overrideMinutes = int.fromEnvironment(
                          'BG_SYNC_MINUTES',
                          defaultValue: 0,
                        );
                        TrustedTime.enableBackgroundSync(
                          interval: overrideMinutes > 0
                              ? Duration(minutes: overrideMinutes)
                              : const Duration(hours: 24),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            _sectionHeader('Section 5b — Background Sync Log (headless)'),
            _card(child: const BackgroundSyncLogPanel()),
            _sectionHeader('Section 6 — Sync Telemetry'),
            _card(child: SyncTelemetryPanel(recorder: widget.telemetry)),
            _sectionHeader('Section 7 — Benchmarking Configuration'),
            _card(
              child: BenchmarkingPanel(
                pool: benchmarkChipPool,
                worldwidePoolSize: extendedNtsPool.length,
                worldwideRotationActive: _worldwideRotationActive,
                worldwideRotationOffset: _worldwideRotationOffset,
                worldwideSubsetSize: _worldwideSubsetSize,
                selected: _selectedServers,
                continuousEnabled: _continuousSyncEnabled,
                reconfiguring: _reconfiguring,
                interCycleDelaySeconds: _interCycleDelaySeconds,
                maxConcurrentDnsLookupsOverride:
                    _maxConcurrentDnsLookupsOverride,
                // The unified DNS budget (ADR 0008) defaults to a fixed
                // TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups
                // rather than the former NTS-only `ntsServers.length + 2`
                // auto-size, so the displayed default is stable across
                // the chip selection and rotation slices.
                defaultMaxConcurrentDnsLookups:
                    TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups,
                logFilePath: _benchmarkLogger.filePath,
                onRunWorldwide: _runWorldwideBenchmark,
                onDnsCapOverrideChanged: (val) {
                  setState(() => _maxConcurrentDnsLookupsOverride = val);
                },
                onToggleServer: (host, picked) {
                  setState(() {
                    if (picked) {
                      _selectedServers.add(host);
                    } else {
                      _selectedServers.remove(host);
                    }
                  });
                },
                onToggleContinuous: (val) {
                  // Defence in depth: the SwitchListTile passes
                  // null to onChanged while _reconfiguring (see
                  // BenchmarkingPanel) so the user can't fire this
                  // path during a re-init window. Re-check here to
                  // keep the contract enforced even if the parent
                  // forgets to wire the disable, since the body
                  // calls into TrustedTime methods that would hit a
                  // disposed engine instance during initialize().
                  if (_reconfiguring) return;
                  setState(() {
                    _continuousSyncEnabled = val;
                    if (!val) {
                      // Stopping continuous sync also stops the
                      // worldwide rotation; the rotation cannot
                      // advance without the cycle-end hook firing.
                      _worldwideRotationActive = false;
                    }
                  });
                  if (val) {
                    // Suppress the engine's internal refresh timer
                    // for the duration of continuous mode so the
                    // slider's inter-cycle delay is the sole
                    // scheduler. Without this the engine's
                    // refreshInterval (30 s here) raced the slider,
                    // collapsing the configured cadence to whichever
                    // timer fired first.
                    TrustedTime.pauseAutomaticRefresh();
                    // Kick the loop immediately rather than waiting
                    // for the slider's first inter-cycle delay.
                    _forceResyncSafely();
                  } else {
                    // Restore the engine's automatic cadence so a
                    // long-idle app still refreshes its anchor.
                    TrustedTime.resumeAutomaticRefresh();
                    // Drop any pending inter-cycle timer so the loop
                    // stops right now, not after the current delay.
                    _cancelInterCycleTimer();
                  }
                },
                onDelayChanged: (val) {
                  setState(() => _interCycleDelaySeconds = val);
                },
                onApply: _applySelectedServers,
              ),
            ),
            _sectionHeader('Section 8 — Per-Host Burst Probe (wy3)'),
            _card(
              // Source the host dropdown and port from the live
              // engine config rather than _selectedServers / 4460
              // literals so the probe stays aligned with what the
              // engine is actually syncing against (chip selection
              // only takes effect after Apply, and
              // worldwide-rotation reconfigures the engine
              // independently of the chips). Wiring ntsKePort from
              // TrustedTime.config.ntsPort means a deployment that
              // overrides the default 4460 still gets a probe that
              // hits the same port the engine itself uses.
              child: BurstProbePanel(
                candidateHosts: TrustedTime.config.ntsServers,
                ntsKePort: TrustedTime.config.ntsPort,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.blueAccent,
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}
