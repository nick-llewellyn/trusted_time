import 'dart:collection';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:nts/nts.dart' as nts;

import 'burst_engine.dart';
import 'burst_types.dart';

/// Async probe returning the current battery level as a `0..100`
/// percentage, or `null` when the platform doesn't support battery
/// reporting (web, headless test environments) or the underlying
/// query throws. Injected into [BurstProbePanel] so widget tests
/// can avoid the `battery_plus` method channel.
///
/// The default factory [defaultBatteryProbe] wraps
/// `Battery().batteryLevel` and swallows platform exceptions so the
/// panel renders cleanly even when battery data is unavailable.
typedef BatteryProbe = Future<int?> Function();

/// Default [BatteryProbe] backed by `package:battery_plus`. Returns
/// `null` on any platform exception so the panel can render the
/// "battery sampling unavailable" branch instead of crashing the
/// burst flow on a desktop / web run where the plugin isn't wired.
Future<int?> defaultBatteryProbe() async {
  try {
    return await Battery().batteryLevel;
  } on Exception {
    return null;
  }
}

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
/// Surfaces the engine's [BurstResult.budget] alongside a
/// panel-side battery delta sampled before / after the burst window.
/// Etiquette guards (1 burst per host per 10 mins) are deferred to
/// wy3 Slice 4; this panel deliberately fires bursts on demand
/// without throttling so the operator can drive ad-hoc measurements.
class BurstProbePanel extends StatefulWidget {
  const BurstProbePanel({
    super.key,
    required this.candidateHosts,
    this.ntsKePort = 4460,
    this.batteryProbe = defaultBatteryProbe,
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

  /// Battery sampler invoked before and after the burst. Defaults to
  /// the `package:battery_plus`-backed [defaultBatteryProbe]; widget
  /// tests inject a deterministic stub so they don't depend on the
  /// underlying platform plugin.
  final BatteryProbe batteryProbe;

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

  // Battery snapshots taken immediately before and after the most
  // recent burst. Both null until the first burst completes; either
  // can be null individually if the corresponding probe call returned
  // null (web / desktop without battery_plus support, or platform
  // exceptions surfaced as null by the probe wrapper). Carried in
  // panel state rather than on BurstResult because the engine has no
  // dependency on battery_plus and the budget surfaced by the engine
  // is intentionally restricted to data derivable from the per-query
  // NTS sample timings.
  int? _batteryBefore;
  int? _batteryAfter;

  // Cached burst client, keyed by (host, port) via _cachedClientKey.
  // NtsBurstClient is explicitly designed to be long-lived: subsequent
  // bursts against the same host reuse the cached NTS-KE session and
  // freshly-rotated cookies, avoiding the TLS+KE handshake each time.
  // Recreating per burst would skew operator RTT/offset measurements
  // (handshake latency serialises in front of the burst window) and
  // discard the engine's cookie pre-fetch. The cache is invalidated
  // and a new client constructed when the target host or port
  // changes; no manual disposal is required because NtsClient itself
  // is GC-managed (no Dart-side `dispose()` exists in package:nts).
  NtsBurstClient? _cachedClient;
  String? _cachedClientKey;

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

  /// Returns the cached [NtsBurstClient] for `(host, port)`,
  /// constructing and caching a new one if the target changed since
  /// the last call. Caching across same-target calls is what keeps
  /// repeated bursts in this panel honest: without it every run pays
  /// the full NTS-KE handshake cost in front of the burst window.
  NtsBurstClient _clientFor(String host, int port) {
    final key = '$host:$port';
    if (_cachedClient == null || _cachedClientKey != key) {
      _cachedClient = NtsBurstClient(
        spec: nts.NtsServerSpec(host: host, port: port),
      );
      _cachedClientKey = key;
    }
    return _cachedClient!;
  }

  /// Runs a burst against the currently-displayed [host]. Accepting
  /// the host as an argument (rather than recomputing
  /// `_selectedHost ?? candidateHosts.firstOrNull` here) ensures the
  /// burst hits exactly what the dropdown shows, even when
  /// `widget.candidateHosts` is an unordered or non-repeatable
  /// Iterable that could re-yield a different first element on a
  /// second `firstOrNull` call.
  Future<void> _runBurst(String host) async {
    if (_running) return;
    setState(() {
      _running = true;
      _lastError = null;
      _lastErrorStack = null;
      // Clear stale battery snapshots up front so a failed before
      // probe doesn't show last-burst's delta on this burst's card.
      _batteryBefore = null;
      _batteryAfter = null;
    });
    // Probe the battery before the burst so the operator's "battery
    // delta during burst" reading actually brackets the burst window.
    // The probe is allowed to fail (returns null) without aborting
    // the burst — a missing battery reading is strictly less useful
    // than a missing burst.
    final batteryBefore = await widget.batteryProbe();
    final client = _clientFor(host, widget.ntsKePort);
    try {
      final result = await client.burst(
        sampleCount: _sampleCount,
        mode: _mode,
        jitterWindow: _jitterWindow,
        sequentialSpacing: _sequentialSpacing,
      );
      final batteryAfter = await widget.batteryProbe();
      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _batteryBefore = batteryBefore;
        _batteryAfter = batteryAfter;
      });
    } catch (err, st) {
      // Probe the after-battery even on failure so the operator can
      // see what was drained by the failed burst (handshake retries
      // on a flaky network can be expensive).
      final batteryAfter = await widget.batteryProbe();
      if (!mounted) return;
      setState(() {
        _lastError = err;
        _lastErrorStack = st;
        _batteryBefore = batteryBefore;
        _batteryAfter = batteryAfter;
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // De-dupe before handing the list to DropdownButtonFormField,
    // which asserts uniqueness on item values at runtime. Using a
    // LinkedHashSet preserves the candidate order so the operator
    // sees the same first-host default they'd get from the input
    // list's natural ordering. The dedupe also defends against
    // non-repeatable Iterables that yield duplicates across
    // iterations (e.g. a chained .followedBy(...) view that
    // overlaps with its base).
    final hosts =
        LinkedHashSet<String>.of(widget.candidateHosts).toList(growable: false);
    final effectiveHost = _selectedHost ?? hosts.firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BurstControls(
          hosts: hosts,
          selectedHost: effectiveHost,
          onHostChanged: (h) => setState(() => _selectedHost = h),
          sampleCount: _sampleCount,
          // round() not toInt(): the Slider has divisions=7 so it
          // snaps to integers internally, but the callback value is
          // a double and a snap-to-8 can surface as 7.999...; toInt()
          // would floor that to 7 and make sampleCount=8 unselectable.
          onSampleCountChanged: (v) => setState(() => _sampleCount = v.round()),
          mode: _mode,
          onModeChanged: (m) => setState(() => _mode = m),
          jitterWindow: _jitterWindow,
          onJitterWindowChanged: (d) => setState(() => _jitterWindow = d),
          sequentialSpacing: _sequentialSpacing,
          onSequentialSpacingChanged: (d) =>
              setState(() => _sequentialSpacing = d),
          running: _running,
          canRun: effectiveHost != null && !_running,
          onRun: effectiveHost == null ? null : () => _runBurst(effectiveHost),
        ),
        const SizedBox(height: 16),
        _BurstResultCard(
          result: _lastResult,
          error: _lastError,
          errorStack: _lastErrorStack,
          running: _running,
          batteryBefore: _batteryBefore,
          batteryAfter: _batteryAfter,
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
  final VoidCallback? onRun;

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
          // round() not toInt(): the Slider snaps to division-aligned
          // milliseconds (50 ms steps), but a snap-to-max can surface
          // as e.g. 1999.99...; toInt() would clip back below the max
          // and make the highest division unselectable.
          onChanged: onChanged == null
              ? null
              : (v) => onChanged!(Duration(milliseconds: v.round())),
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
    required this.batteryBefore,
    required this.batteryAfter,
  });

  final BurstResult? result;
  final Object? error;
  final StackTrace? errorStack;
  final bool running;
  final int? batteryBefore;
  final int? batteryAfter;

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
    // Whole-burst failures (every query raised, so r.hasResult ==
    // false) use the same error color as the panel-level _lastError
    // path above so the operator can tell at a glance that this was
    // a hard failure rather than a partial success. Partial failures
    // (hasResult == true with non-empty failures) stay green because
    // there is still an aggregated estimate to look at.
    final failed = !r.hasResult;
    return _resultBox(
      title: 'Last burst: ${r.host} (${r.mode.name})',
      titleColor: failed ? Theme.of(context).colorScheme.error : Colors.green,
      body: _BurstResultBody(
        result: r,
        batteryBefore: batteryBefore,
        batteryAfter: batteryAfter,
      ),
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
  const _BurstResultBody({
    required this.result,
    required this.batteryBefore,
    required this.batteryAfter,
  });

  final BurstResult result;
  final int? batteryBefore;
  final int? batteryAfter;

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
        // Mobile-budget subsection. Always rendered (zero-filled on
        // whole-burst failure) so the operator gets a stable layout
        // across success / failure runs and can spot anomalies (e.g.
        // a non-zero handshake total on a repeat burst against the
        // same host means the cookie cache didn't apply).
        const SizedBox(height: 12),
        Text(
          'Mobile budget (wy3):',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _statRow(
          'Radio window',
          '${_us(r.budget.radioWindowMicros)} ms',
        ),
        _statRow(
          'DNS phase total',
          '${_us(r.budget.dnsTotalMicros)} ms '
              '(${r.budget.dnsLookupCount}/${r.queries.length} '
              'queries hit a fresh lookup)',
        ),
        _statRow(
          'KE handshake total',
          '${_us(r.budget.handshakeTotalMicros)} ms '
              '${r.budget.handshakeTotalMicros == 0 ? "(cookie-cached burst)" : "(fresh handshake on ≥1 query)"}',
        ),
        _statRow(
          'Battery delta',
          _formatBatteryDelta(batteryBefore, batteryAfter),
        ),
        if (r.failures.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Failures (issue index → error; tap to expand stack trace):',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // ExpansionTile keeps the common case (just the error
          // message) compact while making the captured stack trace
          // (BurstFailure.stackTrace, populated by the engine's
          // try/catch) one tap away. Without this, the panel would
          // discard the stack trace the wy3 engine deliberately
          // captures, defeating the debuggability invariant the
          // BurstFailure typedef was added for in PR #37.
          for (final f in r.failures)
            ExpansionTile(
              dense: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(left: 16, bottom: 4),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(
                '#${f.index}: ${f.error}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
              children: [
                Text(
                  f.stackTrace == StackTrace.empty
                      ? '(no stack trace captured)'
                      : f.stackTrace.toString(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _statRow(String label, String value) {
    // Flexible columns rather than a fixed 200 px label width so the
    // row stays inside the card on narrow phones (small-form Android,
    // foldables in their portrait pose) and at large accessibility
    // text scales (`MediaQuery.textScaler` > 1.3 makes a 200 px label
    // overflow with the long-form labels here, e.g. "Aggregated
    // uncertainty"). The 2:3 flex ratio gives the value column more
    // room because the monospace numerics it carries are typically
    // wider than the prose label.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: Text(label, softWrap: true)),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              value,
              softWrap: true,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
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

  /// Renders the before/after battery snapshots as a signed delta
  /// alongside the raw endpoints so the operator can tell a "0 pp"
  /// reading from "no sample". Either snapshot may be null when the
  /// platform doesn't expose battery state (web / desktop without
  /// the plugin) or the probe surfaced an exception as null; in
  /// those cases the row degrades to "(unavailable)" rather than
  /// fabricating a delta.
  static String _formatBatteryDelta(int? before, int? after) {
    if (before == null || after == null) {
      return '(unavailable)';
    }
    final delta = after - before;
    final sign = delta > 0 ? '+' : '';
    return '$sign$delta pp ($before% → $after%)';
  }
}
