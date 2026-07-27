import 'package:flutter/material.dart';
import 'package:trusted_time/trusted_time.dart' show NtsTrustStatus;

/// Single-line readout of `package:nts`'s process-global trust-anchor
/// diagnostic snapshot: the singleton client's most-recent backend,
/// the Android JNI bootstrap success bit, and the Android hybrid-
/// fallback counter. Sibling of `DnsPoolStatsBar`; same null-stats
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
class TrustStatusBar extends StatelessWidget {
  /// Creates a readout for the supplied trust [status] snapshot.
  const TrustStatusBar({super.key, required this.status});

  /// Most recent trust-anchor snapshot, or null when unavailable.
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
