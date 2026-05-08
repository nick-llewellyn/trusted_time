import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../models.dart';
import 'nts_auth_level.dart';

/// RFC 8915-compliant NTS (Network Time Security) time source.
///
/// Uses [package:nts](https://pub.dev/packages/nts) which provides a
/// Rust-based implementation via `flutter_rust_bridge` with proper
/// TLS 1.3 keying material exporter support (RFC 5705).
///
/// This implementation is **fully conformant** with RFC 8915:
/// - Proper AEAD key derivation via TLS exporter
/// - AES-SIV-CMAC-256 authenticated encryption
/// - Secure NTPv4 extension field handling
///
/// **Cookie jar lifecycle:** [warm] runs [ntsWarmCookies] to perform the
/// NTS-KE handshake (TCP + TLS + KE, ~3 RTTs) and prime the cookie jar.
/// [SyncEngine] awaits this in its warming phase before starting the
/// per-query timeout, so the handshake cost falls outside the
/// `maxLatency` budget. The warm result is memoized; subsequent calls
/// share the same completed [Future]. Each successful query receives one
/// fresh cookie in-band, keeping the pool self-sustaining. If warming
/// fails or is skipped, [getTime] still calls [warm] as a JIT fallback;
/// when that fails too, [ntsQuery] performs its own cold-start handshake
/// transparently.
///
/// **Platform support:** Android, iOS, macOS, Windows, Linux.
/// Not available on Web (NTS requires TLS 1.3 with exporters).
///
/// **Zero overhead when unused:** When [TrustedTimeConfig.ntsServers] is
/// empty (the default), no NTS connections are made.
final class NtsSource implements TimeSource, Warmable {
  /// Creates an NTS source for the given NTS-KE server.
  ///
  /// [dnsConcurrencyCap] is forwarded verbatim to every `ntsQuery` and
  /// `ntsWarmCookies` call. Defaults to [nts.kDefaultDnsConcurrencyCap]
  /// (`0`), which inherits the package's built-in cap of 4. [SyncEngine]
  /// overrides this with `ntsServers.length + 2` so multi-host pools do
  /// not lose admission races against the global resolver pool.
  NtsSource(
    this._host, {
    int port = 4460,
    int dnsConcurrencyCap = nts.kDefaultDnsConcurrencyCap,
  }) : _spec = nts.NtsServerSpec(host: _host, port: port),
       _dnsConcurrencyCap = dnsConcurrencyCap;

  final String _host;
  final nts.NtsServerSpec _spec;
  final int _dnsConcurrencyCap;

  /// Memoized NTS-KE warm task. `null` until [warm] is first invoked,
  /// so constructing an [NtsSource] never touches the FFI surface.
  Future<void>? _warmTask;

  @override
  String get id => '${TimeSource.prefixNts}$_host';

  @override
  String get groupId => _host;

  /// Whether this source is cryptographically secure.
  /// Returns `true` — this implementation uses proper RFC 8915 AEAD
  /// authentication via TLS keying material exporters.
  bool get isSecure => true;

  @override
  Future<void> warm() {
    return _warmTask ??= _performWarming();
  }

  @override
  Future<TimeSample> getTime() async {
    // JIT fallback: ensure warming has been kicked off and completed
    // before issuing the timed query. SyncEngine normally awaits warm()
    // in its dedicated warming phase, so this is a no-op in that path.
    await warm();

    final result = await nts.ntsQuery(
      spec: _spec,
      timeoutMs: 5000,
      dnsConcurrencyCap: _dnsConcurrencyCap,
    );

    // Calculate uncertainty from network RTT (convert microseconds to
    // milliseconds).
    final uncertaintyMs = result.roundTripMicros ~/ 2000;
    final timestampMs = result.utcUnixMicros ~/ 1000;

    return TimeSample(
      interval: TimeInterval(
        startMs: timestampMs - uncertaintyMs,
        endMs: timestampMs + uncertaintyMs,
      ),
      sourceId: id,
      groupId: groupId,
      authLevel: NtsAuthLevel.verified,
    );
  }

  Future<void> _performWarming() async {
    try {
      await nts.ntsWarmCookies(
        spec: _spec,
        dnsConcurrencyCap: _dnsConcurrencyCap,
      );
    } catch (_) {
      // Swallow: missing Rust binaries (test envs), TLS failures, etc.
      // ntsQuery handles a cold-start handshake transparently when the
      // cookie jar is empty.
    }
  }
}
