import 'package:flutter/material.dart';
import 'package:nts/nts.dart' as nts;

import 'burst_engine.dart';
import 'burst_types.dart';

/// Operator-driven UI for firing a single per-host NTS burst against a
/// chosen server with configurable size and inter-burst spacing mode,
/// surfacing the [BurstResult] aggregated by [NtsBurstClient].
///
/// Intentionally wy3 / example-only (matches the
/// [NtsBurstClient] dartdoc's "lives under example/ only" scope):
/// the panel is the human-driven counterpart to the burst engine
/// landed in PR #37, used to gather empirical numbers that will tune
/// ADR 0006 (cadence) / 0007 (trust tiers) defaults before any
/// library-side burst API is considered.
///
/// Etiquette guards (1 burst per host per 10 mins) and mobile-budget
/// instrumentation are deferred to wy3 Slices 4 and 3 respectively;
/// this panel deliberately fires bursts on demand without throttling
/// so the operator can drive ad-hoc measurements.
class BurstProbePanel extends StatefulWidget {
  const BurstProbePanel({
    super.key,
    required this.candidateHosts,
    this.ntsKePort = 4460,
  });

  /// Hosts the dropdown will offer. Typically the live engine's NTS
  /// server selection so the probe targets stay aligned with what the
  /// engine itself is syncing against, but any non-empty iterable is
  /// accepted (the panel falls back to a "no hosts available"
  /// placeholder when empty so the layout stays stable across
  /// reconfigurations).
  final Iterable<String> candidateHosts;

  /// TCP port forwarded to [nts.NtsServerSpec]. RFC 8915 §6 specifies
  /// 4460 as the IANA-assigned NTS-KE default; override only for
  /// deployments running on a non-standard port.
  final int ntsKePort;

  @override
  State<BurstProbePanel> createState() => _BurstProbePanelState();
}

class _BurstProbePanelState extends State<BurstProbePanel> {
  String? _selectedHost;
  int _sampleCount = 4;
  BurstMode _mode = BurstMode.parallel;
  Duration _jitterWindow = const Duration(milliseconds: 200);
  Duration _sequentialSpacing = const Duration(milliseconds: 500);

  bool _running = false;
  BurstResult? _lastResult;
  Object? _lastError;
  StackTrace? _lastErrorStack;

  @override
  void didUpdateWidget(BurstProbePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Drop the selected host if the parent's candidate list changes
    // and the previous selection is no longer offered (e.g. the
    // operator removed it from the engine's NTS selection in
    // Section 7). Falling back to null re-uses the default-pick
    // branch in build() and avoids surfacing a stale host that the
    // dropdown can no longer represent.
    final hosts = widget.candidateHosts.toSet();
    if (_selectedHost != null && !hosts.contains(_selectedHost)) {
      _selectedHost = null;
    }
  }

  Future<void> _runBurst() async {
    final host = _selectedHost ?? widget.candidateHosts.firstOrNull;
    if (host == null || _running) return;
    setState(() {
      _running = true;
      _lastError = null;
      _lastErrorStack = null;
    });
    final client = NtsBurstClient(
      spec: nts.NtsServerSpec(host: host, port: widget.ntsKePort),
    );
    try {
      final result = await client.burst(
        sampleCount: _sampleCount,
        mode: _mode,
        jitterWindow: _jitterWindow,
        sequentialSpacing: _sequentialSpacing,
      );
      if (!mounted) return;
      setState(() => _lastResult = result);
    } catch (err, st) {
      if (!mounted) return;
      setState(() {
        _lastError = err;
        _lastErrorStack = st;
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = widget.candidateHosts.toList(growable: false);
    final effectiveHost = _selectedHost ?? hosts.firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BurstControls(
          hosts: hosts,
          selectedHost: effectiveHost,
          onHostChanged: (h) => setState(() => _selectedHost = h),
          sampleCount: _sampleCount,
          onSampleCountChanged: (v) => setState(() => _sampleCount = v.toInt()),
          mode: _mode,
          onModeChanged: (m) => setState(() => _mode = m),
          jitterWindow: _jitterWindow,
          onJitterWindowChanged: (d) => setState(() => _jitterWindow = d),
          sequentialSpacing: _sequentialSpacing,
          onSequentialSpacingChanged: (d) =>
              setState(() => _sequentialSpacing = d),
          running: _running,
          canRun: effectiveHost != null && !_running,
          onRun: _runBurst,
        ),
        const SizedBox(height: 16),
        _BurstResultCard(
          result: _lastResult,
          error: _lastError,
          errorStack: _lastErrorStack,
          running: _running,
        ),
      ],
    );
  }
}

class _BurstControls extends StatelessWidget {
  const _BurstControls({
    required this.hosts,
    required this.selectedHost,
    required this.onHostChanged,
    required this.sampleCount,
    required this.onSampleCountChanged,
    required this.mode,
    required this.onModeChanged,
    required this.jitterWindow,
    required this.onJitterWindowChanged,
    required this.sequentialSpacing,
    required this.onSequentialSpacingChanged,
    required this.running,
    required this.canRun,
    required this.onRun,
  });

  final List<String> hosts;
  final String? selectedHost;
  final ValueChanged<String?> onHostChanged;
  final int sampleCount;
  final ValueChanged<double> onSampleCountChanged;
  final BurstMode mode;
  final ValueChanged<BurstMode> onModeChanged;
  final Duration jitterWindow;
  final ValueChanged<Duration> onJitterWindowChanged;
  final Duration sequentialSpacing;
  final ValueChanged<Duration> onSequentialSpacingChanged;
  final bool running;
  final bool canRun;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hosts.isEmpty)
          const Text(
            'No NTS hosts available — pick at least one in Section 7.',
            style: TextStyle(fontStyle: FontStyle.italic),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: selectedHost,
            decoration: const InputDecoration(
              labelText: 'Target host',
              border: OutlineInputBorder(),
            ),
            isExpanded: true,
            items: [
              for (final h in hosts)
                DropdownMenuItem<String>(value: h, child: Text(h)),
            ],
            onChanged: running ? null : onHostChanged,
          ),
        const SizedBox(height: 12),
        Text('Sample count: $sampleCount  (clamped to [1, 8])'),
        Slider(
          value: sampleCount.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          label: sampleCount.toString(),
          onChanged: running ? null : onSampleCountChanged,
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<BurstMode>(
          initialValue: mode,
          decoration: const InputDecoration(
            labelText: 'Burst mode',
            border: OutlineInputBorder(),
          ),
          isExpanded: true,
          items: const [
            DropdownMenuItem(
              value: BurstMode.parallel,
              child: Text('parallel — fire all queries at t = 0'),
            ),
            DropdownMenuItem(
              value: BurstMode.jittered,
              child: Text('jittered — random delays within a window'),
            ),
            DropdownMenuItem(
              value: BurstMode.sequential,
              child: Text('sequential — wait between completions'),
            ),
          ],
          onChanged: running
              ? null
              : (m) {
                  if (m != null) onModeChanged(m);
                },
        ),
        const SizedBox(height: 12),
        if (mode == BurstMode.jittered)
          _DurationSlider(
            label: 'Jitter window',
            value: jitterWindow,
            minMs: 50,
            maxMs: 2000,
            onChanged: running ? null : onJitterWindowChanged,
          )
        else if (mode == BurstMode.sequential)
          _DurationSlider(
            label: 'Sequential spacing (between completions)',
            value: sequentialSpacing,
            minMs: 100,
            maxMs: 5000,
            onChanged: running ? null : onSequentialSpacingChanged,
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: canRun ? onRun : null,
              icon: running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(running ? 'Running…' : 'Run Burst'),
            ),
          ],
        ),
      ],
    );
  }
}

class _DurationSlider extends StatelessWidget {
  const _DurationSlider({
    required this.label,
    required this.value,
    required this.minMs,
    required this.maxMs,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final int minMs;
  final int maxMs;
  final ValueChanged<Duration>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ms = value.inMilliseconds.clamp(minMs, maxMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: $ms ms  (range $minMs – $maxMs)'),
        Slider(
          value: ms.toDouble(),
          min: minMs.toDouble(),
          max: maxMs.toDouble(),
          divisions: (maxMs - minMs) ~/ 50,
          label: '$ms ms',
          onChanged: onChanged == null
              ? null
              : (v) => onChanged!(Duration(milliseconds: v.toInt())),
        ),
      ],
    );
  }
}

class _BurstResultCard extends StatelessWidget {
  const _BurstResultCard({
    required this.result,
    required this.error,
    required this.errorStack,
    required this.running,
  });

  final BurstResult? result;
  final Object? error;
  final StackTrace? errorStack;
  final bool running;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return _resultBox(
        title: 'Burst failed',
        titleColor: Theme.of(context).colorScheme.error,
        body: Text(
          '$error\n\n${errorStack ?? StackTrace.empty}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
    }
    final r = result;
    if (r == null) {
      return _resultBox(
        title: running ? 'Burst in flight…' : 'No burst run yet',
        titleColor: Colors.blueGrey,
        body: const Text(
          'Pick a host, choose burst size + mode, then press Run Burst.',
        ),
      );
    }
    return _resultBox(
      title: 'Last burst: ${r.host} (${r.mode.name})',
      titleColor: r.hasResult ? Colors.green : Colors.orange,
      body: _BurstResultBody(result: r),
    );
  }

  Widget _resultBox({
    required String title,
    required Color titleColor,
    required Widget body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: titleColor.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }
}

class _BurstResultBody extends StatelessWidget {
  const _BurstResultBody({required this.result});

  final BurstResult result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final issued = r.queries.length + r.failures.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statRow(
            'Issued',
            '$issued (${r.queries.length} ok, '
                '${r.failures.length} failed)'),
        if (r.hasResult) ...[
          _statRow('Min RTT', '${_us(r.minRttMicros)} ms'),
          _statRow('Median RTT', '${_us(r.medianRttMicros)} ms'),
          _statRow('Max RTT', '${_us(r.maxRttMicros)} ms'),
          _statRow(
            'Aggregated offset',
            '${_signedUs(r.aggregatedOffsetMicros)} ms',
          ),
          _statRow(
            'Aggregated uncertainty',
            '±${_us(r.aggregatedUncertaintyMicros)} ms',
          ),
          _statRow(
            'Intra-burst offset spread',
            '${_us(r.intraOffsetSpreadMicros)} ms',
          ),
        ] else
          const Text(
            'Whole burst failed; no aggregated stats available.',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        if (r.failures.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Failures (issue index → error):',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final f in r.failures)
            Text(
              '  #${f.index}: ${f.error}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
        ],
      ],
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 200, child: Text(label)),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Microseconds → milliseconds with three decimal places.
  static String _us(int micros) => (micros / 1000).toStringAsFixed(3);

  /// Same as [_us] but preserves the sign for offset readouts (a
  /// positive value means the server is ahead of the local clock).
  static String _signedUs(int micros) => (micros >= 0 ? '+' : '') + _us(micros);
}
