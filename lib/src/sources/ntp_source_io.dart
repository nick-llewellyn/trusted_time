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

/// Fetches the NTP offset (ms) for the already-chosen [lookUpAddress].
/// Injectable so tests can assert the resolved literal IP is handed
/// through to the exchange without real UDP traffic.
typedef OffsetFetcher = Future<int> Function(String lookUpAddress);

/// NTP time source — IO-only (uses UDP sockets via `dart:io`).
final class NtpSource implements TimeSource {
  /// Creates an NTP source for [host].
  ///
  /// [asnResolver], [hostResolver] and [offsetFetcher] are injection
  /// seams for tests; in production they default to the shared offline
  /// ASN snapshot, real DNS resolution, and `NTP.getNtpOffset`
  /// respectively. All default to `null` and the shared defaults are
  /// resolved lazily via getters so the constructor stays `const` for
  /// the common (no-override) call site.
  const NtpSource(
    this._host, {
    AsnResolver? asnResolver,
    HostResolver? hostResolver,
    OffsetFetcher? offsetFetcher,
  }) : _asnOverride = asnResolver,
       _hostOverride = hostResolver,
       _offsetOverride = offsetFetcher;

  /// Shared across all NTP sources so the bundled ASN table is
  /// decompressed and held in memory exactly once per isolate.
  static final AsnResolver _sharedAsn = AsnResolver();

  final String _host;
  final AsnResolver? _asnOverride;
  final HostResolver? _hostOverride;
  final OffsetFetcher? _offsetOverride;

  AsnResolver get _asn => _asnOverride ?? _sharedAsn;
  HostResolver get _resolveHost => _hostOverride ?? InternetAddress.lookup;
  OffsetFetcher get _fetchOffset => _offsetOverride ?? _defaultFetchOffset;

  static Future<int> _defaultFetchOffset(String lookUpAddress) =>
      NTP.getNtpOffset(
        lookUpAddress: lookUpAddress,
        timeout: const Duration(seconds: 10),
      );

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
  Future<String> resolveGroupId() async => _groupIdFor(await _resolveFirst());

  /// Resolves [_host] to its first address, or `null` when DNS yields
  /// nothing, times out, or throws. Centralised so [getTime] can pin
  /// the same address for both the ASN lookup and the NTP exchange.
  Future<InternetAddress?> _resolveFirst() async {
    try {
      final addrs = await _resolveHost(
        _host,
      ).timeout(const Duration(seconds: 2));
      return addrs.isEmpty ? null : addrs.first;
    } catch (_) {
      return null;
    }
  }

  /// Maps an already-resolved [addr] to its ASN group, falling back to
  /// the host heuristic on a null address, an ASN miss, or a failure.
  Future<String> _groupIdFor(InternetAddress? addr) async {
    if (addr == null) return groupId;
    try {
      final asn = await _asn.lookup(addr);
      return asn == null ? groupId : 'as$asn';
    } catch (_) {
      return groupId;
    }
  }

  @override
  Future<TimeSample> getTime() async {
    // Resolve the host once so the ASN-derived groupId and the NTP
    // exchange describe the *same* server. Round-robin pools (e.g.
    // pool.ntp.org) can hand back a different IP across two separate
    // lookups, so we resolve once and pass the chosen literal IP to
    // both. InternetAddress.lookup on a literal address is a no-op
    // resolve, so handing the IP to the ntp package costs no second
    // DNS query and pins the exact server we grouped. On a resolve
    // miss we fall back to the bare host so time success never depends
    // on ASN resolution succeeding. See ADR 0007.
    final addr = await _resolveFirst();
    // ASN binary-search runs concurrently with the round-trip; the
    // single DNS resolve above is the only part on the critical path.
    final groupFuture = _groupIdFor(addr);

    final sw = Stopwatch()..start();
    final offset = await _fetchOffset(addr?.address ?? _host);
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
