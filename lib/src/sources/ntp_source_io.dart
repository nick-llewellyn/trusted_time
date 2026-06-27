import 'dart:io' show InternetAddress;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ntp/ntp.dart';
import '../data/asn_resolver.dart';
import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';

/// Resolves [host] to its addresses. Injectable so tests can supply a
/// deterministic mapping without real DNS.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// NTP time source — IO-only (uses UDP sockets via `dart:io`).
final class NtpSource implements TimeSource {
  /// Creates an NTP source for [host].
  ///
  /// [asnResolver] and [hostResolver] are injection seams for tests; in
  /// production they default to the shared offline ASN snapshot and real
  /// DNS resolution respectively.
  NtpSource(this._host, {AsnResolver? asnResolver, HostResolver? hostResolver})
    : _asn = asnResolver ?? _sharedAsn,
      _resolveHost = hostResolver ?? InternetAddress.lookup;

  /// Shared across all NTP sources so the bundled ASN table is
  /// decompressed and held in memory exactly once per isolate.
  static final AsnResolver _sharedAsn = AsnResolver();

  final String _host;
  final AsnResolver _asn;
  final HostResolver _resolveHost;

  @override
  String get id => '${TimeSource.prefixNtp}$_host';

  @override
  String get groupId => _host
      .split('.')
      .reversed
      .skip(1)
      .take(2)
      .toList()
      .reversed
      .join('.')
      .replaceFirst('pool.ntp.org', 'ntp-pool'); // Basic group heuristic

  /// Best-effort ASN-based group ID (`as<asn>`) derived from the host's
  /// resolved IP, falling back to the host-based [groupId] heuristic on
  /// any DNS/ASN miss or failure. See ADR 0007.
  @visibleForTesting
  Future<String> resolveGroupId() async {
    try {
      final addrs = await _resolveHost(
        _host,
      ).timeout(const Duration(seconds: 2));
      if (addrs.isEmpty) return groupId;
      final asn = await _asn.lookup(addrs.first);
      return asn == null ? groupId : 'as$asn';
    } catch (_) {
      return groupId;
    }
  }

  @override
  Future<TimeSample> getTime() async {
    // Resolve the ASN concurrently with the NTP round-trip so the
    // best-effort lookup stays off the critical latency path.
    final groupFuture = resolveGroupId();
    final sw = Stopwatch()..start();
    final offset = await NTP.getNtpOffset(
      lookUpAddress: _host,
      timeout: const Duration(seconds: 10),
    );
    sw.stop();

    final utc = DateTime.now().toUtc().add(Duration(milliseconds: offset));
    final u = sw.elapsedMilliseconds ~/ 2;

    return TimeSample(
      interval: TimeInterval(
        startMs: utc.millisecondsSinceEpoch - u,
        endMs: utc.millisecondsSinceEpoch + u,
      ),
      sourceId: id,
      groupId: await groupFuture,
      // Whole round-trip delay δ; the interval still uses u = δ/2.
      delayMs: sw.elapsedMilliseconds,
    );
  }
}
