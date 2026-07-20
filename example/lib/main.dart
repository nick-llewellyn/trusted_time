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
import 'sync_telemetry.dart';

/// Builds the NTS-exclusive stress-test configuration.
///
/// NTP and HTTPS sources are disabled so the engine relies solely on
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
    httpsSources: const [],
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await TrustedTime.initialize(config: buildStressConfig());

  // Pre-register the background callback so subsequent calls to
  // `enableBackgroundSync` perform a real headless anchor refresh rather
  // than the back-compat HTTPS-HEAD connectivity fallback.
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
  // syncs). The very first bootstrap sync is missed because the engine
  // instance does not exist until initialize() returns.
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
  // Null until the engine has reached its first trusted anchor. Reading
  // TrustedTime.now() before isTrusted == true throws, so we defer the
  // first read to the ticker (or the initState probe below).
  DateTime? _now;
  Timer? _ticker;
  IntegrityEvent? _lastEvent;
  TrustedTimeEstimate? _estimate;
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
  // Stored so the Section 2 forensics subscription can be cancelled
  // in dispose(). Without an explicit cancel the broadcast stream
  // keeps the listener alive for the lifetime of the engine, which
  // outlives this widget on hot reload / nested-Navigator pop /
  // any future scenario that swaps the home page out — and the
  // listener body calls setState, which throws after dispose.
  StreamSubscription<IntegrityEvent>? _integritySub;

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
  // via [_DnsPoolStatsBar] (rising `refused`) versus genuine
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

    // Probe in case the engine reached trust before this widget mounted
    // (warm-start path with a persisted anchor).
    if (TrustedTime.isTrusted) {
      _now = TrustedTime.now();
    }

    // Section 1: UI clock ticking every second. Skip the read until the
    // engine has established a trusted anchor; the ticker will pick up
    // the first sample within a second of isTrusted flipping to true.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!TrustedTime.isTrusted) {
        // Force a rebuild so the badge / placeholder text refreshes
        // even while we don't yet have a trusted reading.
        setState(() {});
        return;
      }
      setState(() {
        _now = TrustedTime.now();
      });
    });

    // Section 2: Forensics subscription. Stored for cancellation in
    // dispose() so a late event (broadcast streams keep emitting for
    // the lifetime of the engine, which outlives this widget on hot
    // reload or any nested-Navigator scenario) cannot fire setState
    // after the State has been torn down. The mounted guard inside
    // the callback is belt-and-braces for the window between event
    // emission and the cancel propagating through the broadcast
    // stream's internal scheduler.
    _integritySub = TrustedTime.onIntegrityLost.listen((event) {
      if (!mounted) return;
      setState(() {
        _lastEvent = event;
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
    unawaited(_integritySub?.cancel());
    _integritySub = null;
    _tzController.dispose();
    unawaited(_benchmarkLogger.dispose());
    super.dispose();
  }

  Future<void> _forceSync() async {
    await TrustedTime.forceResync();
  }

  void _getEstimate() {
    setState(() {
      _estimate = TrustedTime.nowEstimated();
    });
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
          httpsSources: const [],
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
    final isTrusted = TrustedTime.isTrusted;

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
                    isTrusted && _now != null
                        ? _now!.toIso8601String()
                        : 'Waiting for trusted time…',
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
                        // Disabled until the engine reaches its first
                        // trusted anchor; tapping before would throw
                        // TrustedTimeNotReadyException.
                        onPressed: isTrusted
                            ? () => setState(() => _now = TrustedTime.now())
                            : null,
                        child: const Text('Get Time'),
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
            _sectionHeader('Section 2 — Tamper Forensics (F1)'),
            _card(
              child: _lastEvent == null
                  ? const Text('No tampering detected')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reason: ${_lastEvent!.reason.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Drift: ${_lastEvent!.drift?.inMilliseconds ?? 'N/A'} ms',
                        ),
                        Text('Detected At: ${_lastEvent!.detectedAt}'),
                      ],
                    ),
            ),
            _sectionHeader('Section 3 — Offline Estimate (F2)'),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_estimate != null) ...[
                    Text('Est. Time: ${_estimate!.estimatedTime}'),
                    Text(
                      'Confidence: ${(_estimate!.confidence * 100).toStringAsFixed(1)}%',
                    ),
                    Text('Error: ±${_estimate!.estimatedError.inSeconds}s'),
                  ] else
                    const Text('No anchor persisted yet or currently trusted'),
                  const SizedBox(height: 8),
                  Center(
                    child: ElevatedButton(
                      onPressed: _getEstimate,
                      child: const Text('Get Estimate'),
                    ),
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
            _card(child: const _BackgroundSyncLogPanel()),
            _sectionHeader('Section 6 — Sync Telemetry'),
            _card(child: _SyncTelemetryPanel(recorder: widget.telemetry)),
            _sectionHeader('Section 7 — Benchmarking Configuration'),
            _card(
              child: _BenchmarkingPanel(
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
                  // _BenchmarkingPanel) so the user can't fire this
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

/// Reads the on-disk background-sync transcript
/// ([BackgroundSyncFileLog]) back into the UI so the headless path is
/// observable in-app, without a `logcat` capture.
///
/// The headless isolate that writes this file is a separate process the
/// foreground telemetry stack never sees, so this panel is the in-app
/// window onto it. It loads on mount and on demand (there is no live
/// stream across the isolate boundary — a background fire happens while
/// this widget may not even be alive — so an explicit refresh is the
/// honest model). The resolved file path is shown so the same transcript
/// can be pulled off-device with `adb pull <path>`.
class _BackgroundSyncLogPanel extends StatefulWidget {
  const _BackgroundSyncLogPanel();

  @override
  State<_BackgroundSyncLogPanel> createState() =>
      _BackgroundSyncLogPanelState();
}

class _BackgroundSyncLogPanelState extends State<_BackgroundSyncLogPanel> {
  List<String> _lines = const [];
  String? _path;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final path = await BackgroundSyncFileLog.resolvePath();
    final lines = await BackgroundSyncFileLog.readLatest();
    if (!mounted) return;
    setState(() {
      _path = path;
      _lines = lines;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await BackgroundSyncFileLog.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _loading
                  ? 'Loading…'
                  : '${_lines.length} entr${_lines.length == 1 ? 'y' : 'ies'} '
                        '(newest first)',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _reload,
                ),
                IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _loading || _lines.isEmpty ? null : _clear,
                ),
              ],
            ),
          ],
        ),
        if (_path != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              'adb pull $_path',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        Container(
          width: double.infinity,
          height: 180,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
          ),
          child: _lines.isEmpty
              ? Center(
                  child: Text(
                    // Distinguish "logging is compiled out" from "no fires
                    // yet" — otherwise a release build without the
                    // BG_SYNC_LOG define looks identical to a build whose
                    // background path never ran.
                    BackgroundSyncFileLog.enabled
                        ? 'No background fires recorded yet.\n'
                              'Trigger one, then Refresh.'
                        : 'Transcript logging is disabled in this build.\n'
                              'Rebuild with --dart-define=BG_SYNC_LOG=true '
                              'to enable it.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: _lines.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: SelectableText(
                      _lines[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Terminal-style telemetry log: dark background, monospaced font,
/// auto-scrolls to the bottom whenever a new event is appended so the
/// most recent activity stays in view during long-running benchmarking
/// sessions. The scroll attachment piggy-backs on the recorder's
/// ChangeNotifier callback so we do not need a second listener layer.
class _SyncTelemetryPanel extends StatefulWidget {
  const _SyncTelemetryPanel({required this.recorder});

  final TelemetryRecorder recorder;

  @override
  State<_SyncTelemetryPanel> createState() => _SyncTelemetryPanelState();
}

class _SyncTelemetryPanelState extends State<_SyncTelemetryPanel> {
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
            _DnsPoolStatsBar(stats: _dnsStats),
            const SizedBox(height: 4),
            _TrustStatusBar(status: _trustStatus),
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

/// Section 7 panel: server selection, continuous-resync toggle, and a
/// readout of the per-session log file path. Stateless because all
/// mutation lives on [_HomePageState] — this panel just renders the
/// current snapshot and pipes user gestures back through callbacks.
class _BenchmarkingPanel extends StatelessWidget {
  const _BenchmarkingPanel({
    required this.pool,
    required this.worldwidePoolSize,
    required this.selected,
    required this.worldwideRotationActive,
    required this.worldwideRotationOffset,
    required this.worldwideSubsetSize,
    required this.continuousEnabled,
    required this.reconfiguring,
    required this.interCycleDelaySeconds,
    required this.maxConcurrentDnsLookupsOverride,
    required this.defaultMaxConcurrentDnsLookups,
    required this.logFilePath,
    required this.onRunWorldwide,
    required this.onDnsCapOverrideChanged,
    required this.onToggleServer,
    required this.onToggleContinuous,
    required this.onDelayChanged,
    required this.onApply,
  });

  final List<String> pool;
  final int worldwidePoolSize;
  final bool worldwideRotationActive;
  final int worldwideRotationOffset;
  final int worldwideSubsetSize;
  final Set<String> selected;
  final bool continuousEnabled;
  final bool reconfiguring;
  final int interCycleDelaySeconds;
  final int? maxConcurrentDnsLookupsOverride;
  final int defaultMaxConcurrentDnsLookups;
  final String? logFilePath;
  final Future<void> Function() onRunWorldwide;
  final ValueChanged<int?> onDnsCapOverrideChanged;
  final void Function(String host, bool picked) onToggleServer;
  final ValueChanged<bool> onToggleContinuous;
  final ValueChanged<int> onDelayChanged;
  final Future<void> Function() onApply;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Worldwide Beauty Parade — one-tap entry to a continuous run
        // against the entire externally-curated worldwide NTS pool, so
        // per-source telemetry can rank every host by latency and
        // reliability without the operator hand-picking chips.
        Card(
          margin: EdgeInsets.zero,
          color: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.public, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'Worldwide Beauty Parade',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Cycles the engine through the worldwide NTS pool '
                  '($worldwidePoolSize hosts) in slices of '
                  '$worldwideSubsetSize host(s) per cycle, so every '
                  'server gets isolated, contention-free measurements '
                  'over time. Per-source telemetry accumulated across '
                  'cycles can then rank hosts by latency and '
                  'reliability. Stop by flipping Continuous Sync off '
                  'or pressing Apply Selection on the manual chips.',
                  style: const TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                if (worldwideRotationActive) ...[
                  const SizedBox(height: 6),
                  _RotationStatusLine(
                    offset: worldwideRotationOffset,
                    subsetSize: worldwideSubsetSize,
                    poolSize: worldwidePoolSize,
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    icon: reconfiguring
                        ? const SizedBox(
                            height: 14,
                            width: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            worldwideRotationActive
                                ? Icons.autorenew
                                : Icons.play_arrow,
                          ),
                    label: Text(
                      reconfiguring
                          ? 'Reconfiguring…'
                          : worldwideRotationActive
                          ? 'Rotation running…'
                          : 'Run Worldwide Beauty Parade',
                    ),
                    onPressed: (reconfiguring || worldwideRotationActive)
                        ? null
                        : onRunWorldwide,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // DNS lookup budget override. Investigative knob for
        // diagnosing whether `NtsError.timeout` failures are caused
        // by the engine's DNS budget throttling lookups (rising
        // `refused` in the Section 6 stats bar) versus real
        // server-side timeouts. Default leaves the override null, so the
        // engine applies its own unified budget
        // (TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups). See
        // ADR 0008.
        _DnsCapOverridePanel(
          capOverride: maxConcurrentDnsLookupsOverride,
          defaultBudget: defaultMaxConcurrentDnsLookups,
          onChanged: onDnsCapOverrideChanged,
        ),
        const SizedBox(height: 12),
        const Text(
          'Or pick the NTS hosts to include in the next sync cycle '
          'manually, then press Apply Selection. Toggle Continuous '
          'Sync to chain a forceResync after every cycle for '
          'long-form benchmarking.',
          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final host in pool)
              FilterChip(
                label: Text(host, style: const TextStyle(fontSize: 12)),
                selected: selected.contains(host),
                onSelected: (val) => onToggleServer(host, val),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Note: Selecting multiple System76 hosts simultaneously may '
          'cause NTS-KE handshake timeouts due to connection '
          'cannibalization.',
          style: TextStyle(
            fontSize: 11,
            fontStyle: FontStyle.italic,
            color: Colors.amberAccent,
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Continuous sync'),
          subtitle: Text(
            continuousEnabled
                ? 'Chains forceResync after every cycle '
                      '(delay: ${interCycleDelaySeconds}s)'
                : 'Single-shot mode (use Force Resync in Section 1)',
            style: const TextStyle(fontSize: 12),
          ),
          value: continuousEnabled,
          // Disabled mid-reconfigure: the toggle handler calls
          // TrustedTime.pauseAutomaticRefresh() / forceResync(),
          // both of which would hit the previous engine instance
          // mid-dispose during initialize(). The handler itself
          // also re-checks _reconfiguring as belt-and-braces.
          onChanged: reconfiguring ? null : onToggleContinuous,
        ),
        const SizedBox(height: 4),
        // Inter-cycle delay slider — investigative knob to avoid
        // tripping NTS-KE rate limits and to observe per-server
        // recovery between cycles. The 60 divisions create 61
        // discrete stops (0–60).
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Inter-cycle delay: ${interCycleDelaySeconds}s '
                '(0–60s)',
                style: const TextStyle(fontSize: 12),
              ),
              Slider(
                min: 0,
                max: 60,
                divisions: 60,
                value: interCycleDelaySeconds.toDouble(),
                label: '${interCycleDelaySeconds}s',
                onChanged: (v) => onDelayChanged(v.round()),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton.icon(
            icon: reconfiguring
                ? const SizedBox(
                    height: 14,
                    width: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(
              reconfiguring
                  ? 'Reconfiguring…'
                  : 'Apply Selection (${selected.length})',
            ),
            onPressed: (reconfiguring || selected.isEmpty) ? null : onApply,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          logFilePath == null
              ? 'Log file: not initialised'
              : 'Log file: $logFilePath',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }
}

/// One-line readout for the worldwide rotation: which slice is running
/// and which cycle we're on within a full pass through the pool.
/// Stateless because all rotation state lives on _HomePageState; this
/// widget renders the current snapshot.
class _RotationStatusLine extends StatelessWidget {
  const _RotationStatusLine({
    required this.offset,
    required this.subsetSize,
    required this.poolSize,
  });

  final int offset;
  final int subsetSize;
  final int poolSize;

  @override
  Widget build(BuildContext context) {
    final endExclusive = offset + subsetSize;
    final wraps = endExclusive > poolSize;
    // Match the wrap-aware slice-label format used for DNS deltas
    // (see _logSliceDnsDeltaIfAvailable in main.dart) so the
    // operator sees the same '76-80, 0-2' shape on screen and in
    // the session log when a slice straddles the pool boundary.
    final String hostsLabel;
    if (wraps) {
      final wrapEnd = endExclusive % poolSize - 1;
      hostsLabel = '$offset–${poolSize - 1}, 0–$wrapEnd';
    } else {
      hostsLabel = '$offset–${endExclusive - 1}';
    }
    final cyclesPerPass = (poolSize / subsetSize).ceil();
    final currentCycle = (offset / subsetSize).floor() + 1;
    return Text(
      'Rotation: hosts $hostsLabel '
      '(cycle $currentCycle / $cyclesPerPass per pass)',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    );
  }
}

/// Single-line readout of the four `package:nts` DNS pool counters
/// (in-flight, high-water mark, cumulative recovered, cumulative
/// refused). The package documents these as the canonical signal for
/// distinguishing cap-bound deployments from libc resolver wedges
/// (both collapse onto `NtsError.timeout` in the hot-path error
/// contract), so surfacing them here lets the operator diagnose
/// per-slice failure modes during a worldwide benchmark without
/// scraping logs.
///
/// Renders a placeholder when stats are null (NTS disabled in the
/// active config or NtsRustLib not initialised).
class _DnsPoolStatsBar extends StatelessWidget {
  const _DnsPoolStatsBar({required this.stats});

  final NtsDnsPoolStats? stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final detail = s == null
        ? 'DNS pool: n/a (NTS disabled or NtsRustLib not initialised)'
        : 'DNS pool — inFlight: ${s.inFlight}  '
              'hwm: ${s.highWaterMark}  '
              'recovered: ${s.recovered}  '
              'refused: ${s.refused}';
    return Text(
      detail,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: s == null ? Colors.grey : Colors.tealAccent.shade100,
      ),
    );
  }
}

/// Single-line readout of `package:nts`'s process-global trust-anchor
/// diagnostic snapshot: the singleton client's most-recent backend,
/// the Android JNI bootstrap success bit, and the Android hybrid-
/// fallback counter. Sibling of [_DnsPoolStatsBar]; same null-stats
/// degradation contract (NTS disabled or NtsRustLib uninitialised).
///
/// `defaultClientBackend` is rendered as `singleton: <name>` (or
/// `singleton: idle` when null, meaning the singleton client has
/// not handshaken yet — every per-source `NtsSource` mints its own
/// `NtsClient` so the singleton stays idle in normal operation).
/// On non-Android platforms the JNI / hybrid-fallback fields are
/// rendered with their documented sentinel values (`false` / `0`)
/// rather than hidden, so the readout has a stable shape on every
/// host.
class _TrustStatusBar extends StatelessWidget {
  const _TrustStatusBar({required this.status});

  final NtsTrustStatus? status;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final detail = s == null
        ? 'Trust status: n/a (NTS disabled or NtsRustLib not initialised)'
        : 'Trust status — '
              'singleton: ${s.defaultClientBackend?.name ?? 'idle'}  '
              'androidInit: ${s.androidPlatformInitSucceeded}  '
              'hybridFallbacks: ${s.androidHybridFallbackCount}';
    return Text(
      detail,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: s == null ? Colors.grey : Colors.tealAccent.shade100,
      ),
    );
  }
}

/// Manual override for the engine's unified DNS lookup budget
/// (`TrustedTimeConfig.maxConcurrentDnsLookups`, ADR 0008). "Use
/// default" forwards null and lets the engine apply its fixed
/// `kDefaultMaxConcurrentDnsLookups` default; toggling it off enables
/// a slider that lets the operator pick an explicit budget (4–32) and
/// observe the effect on the [_DnsPoolStatsBar] counters during a
/// run. Stateless — all state lives on _HomePageState; this widget
/// just renders the snapshot and pipes gestures back through
/// [onChanged].
class _DnsCapOverridePanel extends StatelessWidget {
  const _DnsCapOverridePanel({
    required this.capOverride,
    required this.defaultBudget,
    required this.onChanged,
  });

  final int? capOverride;
  final int defaultBudget;
  final ValueChanged<int?> onChanged;

  static const int _minCap = 4;
  static const int _maxCap = 32;

  @override
  Widget build(BuildContext context) {
    final autoOn = capOverride == null;
    // Seed slider value when toggling auto off for the first time:
    // start at the engine's default budget (clamped to slider range)
    // so the manual mode begins from the same effective budget the
    // engine was already using. Subsequent toggles preserve the
    // operator's chosen value.
    final sliderValue = (capOverride ?? defaultBudget)
        .clamp(_minCap, _maxCap)
        .toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Use default DNS lookup budget'),
          subtitle: Text(
            autoOn
                ? 'Engine uses its unified DNS budget (default '
                      '$defaultBudget)'
                : 'Manual override: $capOverride',
            style: const TextStyle(fontSize: 12),
          ),
          value: autoOn,
          onChanged: (val) => onChanged(val ? null : sliderValue.toInt()),
        ),
        if (!autoOn)
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4),
            child: Slider(
              min: _minCap.toDouble(),
              max: _maxCap.toDouble(),
              divisions: _maxCap - _minCap,
              value: sliderValue,
              label: '${sliderValue.toInt()}',
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
      ],
    );
  }
}
