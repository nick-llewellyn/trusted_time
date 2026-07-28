import 'package:flutter/material.dart';

/// Section 7 panel: server selection, continuous-resync toggle, and a
/// readout of the per-session log file path. Stateless because all
/// mutation lives on the host page — this panel just renders the
/// current snapshot and pipes user gestures back through callbacks.
class BenchmarkingPanel extends StatelessWidget {
  /// Creates the Section 7 benchmarking configuration panel.
  const BenchmarkingPanel({
    super.key,
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

  /// Hosts offered as manually selectable chips.
  final List<String> pool;

  /// Size of the full worldwide NTS pool the rotation cycles through.
  final int worldwidePoolSize;

  /// Whether the worldwide rotation is currently running.
  final bool worldwideRotationActive;

  /// Index of the first host in the currently-running rotation slice.
  final int worldwideRotationOffset;

  /// Number of hosts exercised per rotation cycle.
  final int worldwideSubsetSize;

  /// Hosts currently picked via the manual chips.
  final Set<String> selected;

  /// Whether a forceResync is chained after every cycle.
  final bool continuousEnabled;

  /// Whether the engine is mid-reinitialise; disables mutating controls.
  final bool reconfiguring;

  /// Delay inserted between chained cycles, in seconds.
  final int interCycleDelaySeconds;

  /// Operator override for the engine's DNS lookup budget, or null.
  final int? maxConcurrentDnsLookupsOverride;

  /// The engine's own default DNS lookup budget (ADR 0008).
  final int defaultMaxConcurrentDnsLookups;

  /// Resolved per-session log file path, or null before initialisation.
  final String? logFilePath;

  /// Starts a worldwide Beauty Parade run.
  final Future<void> Function() onRunWorldwide;

  /// Reports a change to the DNS budget override (null restores default).
  final ValueChanged<int?> onDnsCapOverrideChanged;

  /// Reports a manual chip toggle for [host].
  final void Function(String host, bool picked) onToggleServer;

  /// Reports a change to the continuous-sync toggle.
  final ValueChanged<bool> onToggleContinuous;

  /// Reports a change to the inter-cycle delay slider.
  final ValueChanged<int> onDelayChanged;

  /// Applies the current manual selection to the engine.
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
/// Stateless because all rotation state lives on the host page; this
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

/// Manual override for the engine's unified DNS lookup budget
/// (`TrustedTimeConfig.maxConcurrentDnsLookups`, ADR 0008). "Use
/// default" forwards null and lets the engine apply its fixed
/// `kDefaultMaxConcurrentDnsLookups` default; toggling it off enables
/// a slider that lets the operator pick an explicit budget (4–32) and
/// observe the effect on the `DnsPoolStatsBar` counters during a
/// run. Stateless — all state lives on the host page; this widget
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
