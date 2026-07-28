import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show NtsDnsPoolStats;

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
class DnsPoolStatsBar extends StatelessWidget {
  /// Creates a readout for the supplied DNS pool [stats] snapshot.
  const DnsPoolStatsBar({super.key, required this.stats});

  /// Most recent DNS pool snapshot, or null when unavailable.
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
