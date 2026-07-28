import 'dart:async';
import 'package:flutter/material.dart';
import 'package:trusted_time/trusted_time.dart';
import 'background_entrypoint.dart';
import 'benchmark_controller.dart';
import 'burst/burst_probe_panel.dart';
import 'nts_sources.dart';
import 'panels/background_sync_log_panel.dart';
import 'panels/benchmarking_panel.dart';
import 'panels/sync_telemetry_panel.dart';
import 'sync_telemetry.dart';

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

  // Section 7 — Benchmarking Configuration. All orchestration (server
  // selection, continuous sync, worldwide rotation, engine
  // reconfigures, session logging) lives in the controller; this state
  // only constructs, starts, and disposes it.
  late final BenchmarkController _benchmark;

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

    _benchmark = BenchmarkController(telemetry: widget.telemetry)
      ..onReconfigureFailure = _showReconfigureFailure
      ..start();
  }

  /// Surfaces a controller-reported reconfigure failure. The controller
  /// has no [BuildContext], so the snack bar stays here.
  void _showReconfigureFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  @override
  void dispose() {
    _benchmark.dispose();
    _ticker?.cancel();
    _tzController.dispose();
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
              child: ListenableBuilder(
                listenable: _benchmark,
                builder: (context, _) => BenchmarkingPanel(
                  pool: benchmarkChipPool,
                  worldwidePoolSize: extendedNtsPool.length,
                  worldwideRotationActive: _benchmark.worldwideRotationActive,
                  worldwideRotationOffset: _benchmark.worldwideRotationOffset,
                  worldwideSubsetSize: BenchmarkController.worldwideSubsetSize,
                  selected: _benchmark.selectedServers,
                  continuousEnabled: _benchmark.continuousSyncEnabled,
                  reconfiguring: _benchmark.reconfiguring,
                  interCycleDelaySeconds: _benchmark.interCycleDelaySeconds,
                  maxConcurrentDnsLookupsOverride:
                      _benchmark.maxConcurrentDnsLookupsOverride,
                  // The unified DNS budget (ADR 0008) defaults to a fixed
                  // TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups
                  // rather than the former NTS-only `ntsServers.length + 2`
                  // auto-size, so the displayed default is stable across
                  // the chip selection and rotation slices.
                  defaultMaxConcurrentDnsLookups:
                      TrustedTimeConfig.kDefaultMaxConcurrentDnsLookups,
                  logFilePath: _benchmark.logFilePath,
                  onRunWorldwide: _benchmark.runWorldwideBenchmark,
                  onDnsCapOverrideChanged:
                      _benchmark.setMaxConcurrentDnsLookupsOverride,
                  onToggleServer: _benchmark.toggleServer,
                  onToggleContinuous: _benchmark.setContinuousSync,
                  onDelayChanged: _benchmark.setInterCycleDelaySeconds,
                  onApply: _benchmark.applySelectedServers,
                ),
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
