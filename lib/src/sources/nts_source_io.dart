import 'package:nts/nts.dart';
import '../models.dart';
import '../monotonic_clock.dart';

/// IANA-assigned default port for NTS-KE (RFC 8915 §6).
const int _ntsKeDefaultPort = 4460;

/// Test seam: the shape of `package:nts`'s top-level [ntsQuery] function.
///
/// Production code defaults to the real implementation; unit tests inject
/// a fake to exercise [NtsSource] without a live network or the FRB
/// native bridge. Keeping the named-parameter signature identical to
/// [ntsQuery] means we can pass the function reference directly as the
/// default — no adapter wrapper needed.
typedef NtsQueryFn = Future<NtsTimeSample> Function({
  required NtsServerSpec spec,
  required int timeoutMs,
});

/// Lazy, idempotent `RustLib.init()` guard.
///
/// `package:nts` requires the FRB bridge to be bootstrapped exactly once
/// before any `nts*` call. We piggy-back on `Future` memoization so
/// concurrent first-fetches don't race the loader. Skipped entirely
/// when the caller injects a non-default [NtsQueryFn] (tests).
Future<void>? _rustLibInit;
Future<void> _ensureRustLib() => _rustLibInit ??= RustLib.init();

/// NTS time source — IO-only, RFC 8915 authenticated NTPv4 over UDP.
///
/// Wraps `package:nts`, which performs the TLS 1.3 NTS-KE handshake,
/// caches the per-spec session keys + cookie pool, and runs the
/// authenticated NTPv4 exchange in native Rust. The first `fetch()`
/// against a given host pays the KE cost; subsequent fetches reuse the
/// cached session until the cookie jar drains.
final class NtsSource implements TrustedTimeSource {
  /// Creates an NTS source pointing at [host].
  ///
  /// [query] is a test-only seam — leave it `null` in production so the
  /// source uses the real `package:nts` bridge. When a custom [query] is
  /// provided, the FRB bootstrap is skipped (the fake won't call into
  /// native code).
  NtsSource(
    this._host, {
    int port = _ntsKeDefaultPort,
    Duration timeout = const Duration(seconds: 5),
    MonotonicClock? clock,
    NtsQueryFn? query,
  }) : _port = port,
       _timeoutMs = timeout.inMilliseconds,
       _clock = clock ?? PlatformMonotonicClock(),
       _query = query ?? ntsQuery,
       _usingDefaultQuery = query == null;

  final String _host;
  final int _port;
  final int _timeoutMs;
  final MonotonicClock _clock;
  final NtsQueryFn _query;
  final bool _usingDefaultQuery;

  @override
  String get id => 'nts:$_host';

  @override
  Future<TimeSample> fetch() async {
    if (_usingDefaultQuery) {
      await _ensureRustLib();
    }
    final spec = NtsServerSpec(host: _host, port: _port);
    final sample = await _query(spec: spec, timeoutMs: _timeoutMs);
    // Capture monotonic reference immediately on response receipt, before
    // any further aggregation work in the sync engine. The native call has
    // already authenticated and parsed the NTPv4 reply; this is the
    // closest user-space approximation of "instant of receipt".
    final capturedMonotonicMs = await _clock.uptimeMs();
    final capturedAt = DateTime.now().toUtc();
    final networkUtc = DateTime.fromMicrosecondsSinceEpoch(
      sample.utcUnixMicros.toInt(),
      isUtc: true,
    );
    final rttMicros = sample.roundTripMicros.toInt();
    final rtt = Duration(microseconds: rttMicros);
    return TimeSample(
      networkUtc: networkUtc,
      roundTripTime: rtt,
      uncertainty: Duration(microseconds: rttMicros ~/ 2),
      capturedMonotonicMs: capturedMonotonicMs,
      source: TimeSourceMetadata(
        kind: TimeSourceKind.nts,
        id: id,
        host: _host,
        stratum: sample.serverStratum,
        authenticated: true,
      ),
      capturedAt: capturedAt,
    );
  }
}
