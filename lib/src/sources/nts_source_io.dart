import 'package:nts/nts.dart';
import '../models.dart';
import '../monotonic_clock.dart';

/// IANA-assigned default port for NTS-KE (RFC 8915 §6).
const int _ntsKeDefaultPort = 4460;

/// Default number of authenticated samples collected per `fetch()`.
///
/// Mirrors the NTP `burst` count from the reference implementation
/// (RFC 5905 §10): enough samples to make the clock-filter
/// minimum-delay selection statistically meaningful without piling
/// load on the upstream server.
const int _defaultBurstSize = 8;

/// Default spacing between successive samples in a burst.
///
/// Short enough that the whole burst fits inside a single user-perceived
/// sync (~1 s plus measured RTTs); long enough that consecutive samples
/// see distinct queue states on the path so the minimum-delay selection
/// is meaningful.
const Duration _defaultBurstSpacing = Duration(milliseconds: 100);

/// Test seam: the shape of `package:nts`'s top-level [ntsQuery] function.
///
/// Production code defaults to the real implementation; unit tests inject
/// a fake to exercise [NtsSource] without a live network or the FRB
/// native bridge. Keeping the named-parameter signature identical to
/// [ntsQuery] means we can pass the function reference directly as the
/// default — no adapter wrapper needed.
typedef NtsQueryFn =
    Future<NtsTimeSample> Function({
      required NtsServerSpec spec,
      required int timeoutMs,
    });

/// Test seam: the shape of `package:nts`'s [ntsWarmCookies] function.
typedef NtsWarmCookiesFn =
    Future<int> Function({required NtsServerSpec spec, required int timeoutMs});

/// Lazy, idempotent `RustLib.init()` guard.
///
/// `package:nts` requires the FRB bridge to be bootstrapped exactly once
/// before any `nts*` call. We piggy-back on `Future` memoization so
/// concurrent first-fetches don't race the loader. Skipped entirely
/// when the caller injects a non-default bridge function (tests).
Future<void>? _rustLibInit;
Future<void> _ensureRustLib() => _rustLibInit ??= RustLib.init();

/// NTS time source — RFC 8915 authenticated NTPv4 with burst sampling
/// and RFC 5905 clock-filter selection.
///
/// Each `fetch()` performs a single NTS-KE pre-warm (so the first
/// sample's wall time is not inflated by handshake setup from a cold
/// cache) followed by a burst of authenticated NTPv4 queries. The
/// sample with the lowest measured round-trip delay is returned, on
/// the standard NTP rationale that minimum delay correlates with
/// minimum path asymmetry and therefore with minimum offset error.
///
/// The selected sample's monotonic-uptime + wall-clock pair (captured
/// at the instant that sample's response was received) is forwarded
/// to the engine so the resulting trust anchor is pinned to the same
/// instant as the measurement that backs it.
final class NtsSource implements TrustedTimeSource {
  /// Creates an NTS source pointing at [host].
  ///
  /// [query] and [warmCookies] are test-only seams — leave them `null`
  /// in production so the source uses the real `package:nts` bridge.
  /// When either is provided the FRB bootstrap is skipped (the fakes
  /// won't call into native code).
  ///
  /// [burstSize] controls how many authenticated samples are taken per
  /// `fetch()`; the lowest-RTD sample wins. [burstSpacing] is the
  /// inter-sample delay applied between successive queries.
  NtsSource(
    this._host, {
    int port = _ntsKeDefaultPort,
    Duration timeout = const Duration(seconds: 5),
    int burstSize = _defaultBurstSize,
    Duration burstSpacing = _defaultBurstSpacing,
    MonotonicClock? clock,
    NtsQueryFn? query,
    NtsWarmCookiesFn? warmCookies,
  }) : assert(burstSize >= 1, 'burstSize must be >= 1'),
       _port = port,
       _timeoutMs = timeout.inMilliseconds,
       _burstSize = burstSize,
       _burstSpacing = burstSpacing,
       _clock = clock ?? PlatformMonotonicClock(),
       _query = query ?? ntsQuery,
       _warmCookies = warmCookies ?? ntsWarmCookies,
       _usingDefaultBridge = query == null && warmCookies == null;

  final String _host;
  final int _port;
  final int _timeoutMs;
  final int _burstSize;
  final Duration _burstSpacing;
  final MonotonicClock _clock;
  final NtsQueryFn _query;
  final NtsWarmCookiesFn _warmCookies;
  final bool _usingDefaultBridge;

  @override
  String get id => 'nts:$_host';

  @override
  Future<TimeSample> fetch() async {
    if (_usingDefaultBridge) {
      await _ensureRustLib();
    }
    final spec = NtsServerSpec(host: _host, port: _port);

    // Pre-warm the cookie jar so the first burst sample's wall time is
    // not dominated by KE handshake setup from a cold cache. A failure
    // here is non-fatal: `ntsQuery` will retry the handshake itself if
    // the jar is still empty when sample 0 fires.
    try {
      await _warmCookies(spec: spec, timeoutMs: _timeoutMs);
    } on NtsError {
      // Swallowed; the burst loop will surface real failures.
    }

    final samples = <_BurstSample>[];
    NtsError? lastError;
    StackTrace? lastStack;
    for (var i = 0; i < _burstSize; i++) {
      NtsTimeSample? raw;
      try {
        raw = await _query(spec: spec, timeoutMs: _timeoutMs);
      } on NtsError catch (e, s) {
        lastError = e;
        lastStack = s;
      }
      if (raw != null) {
        // Capture the monotonic + wall pair *per sample*, immediately
        // after the native call returns. The selected sample's pair is
        // forwarded so the anchor is pinned to that measurement's
        // instant of receipt rather than to the end of the burst.
        final capturedMonotonicMs = await _clock.uptimeMs();
        final capturedAt = DateTime.now().toUtc();
        samples.add(_BurstSample(raw, capturedMonotonicMs, capturedAt));
      }
      if (i < _burstSize - 1 && _burstSpacing > Duration.zero) {
        await Future<void>.delayed(_burstSpacing);
      }
    }

    if (samples.isEmpty) {
      Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
    }

    // RFC 5905 clock filter: pick the minimum-delay sample. Lower RTD
    // bounds the maximum possible asymmetry-induced offset error.
    samples.sort(
      (a, b) => a.raw.roundTripMicros.toInt().compareTo(
        b.raw.roundTripMicros.toInt(),
      ),
    );
    final best = samples.first;

    final rttMicros = best.raw.roundTripMicros.toInt();
    // `utcUnixMicros` is the raw server transmit timestamp T3. The engine
    // pins this sample to `capturedMonotonicMs` (≈ T4), so to satisfy the
    // `TimeSample.networkUtc` contract ("already RTT-corrected") we need
    // the estimated UTC at that instant. With only T1, T3, and the
    // wall-clock RTT (T4-T1) exposed by `package:nts`, the standard NTP
    // symmetric-path estimator T3 + RTT/2 is the best available proxy.
    // Min-RTD selection is what makes this safe: smaller RTD bounds the
    // worst-case asymmetry-induced offset error.
    final halfRttMicros = rttMicros ~/ 2;
    return TimeSample(
      networkUtc: DateTime.fromMicrosecondsSinceEpoch(
        best.raw.utcUnixMicros.toInt() + halfRttMicros,
        isUtc: true,
      ),
      roundTripTime: Duration(microseconds: rttMicros),
      uncertainty: Duration(microseconds: rttMicros ~/ 2),
      capturedMonotonicMs: best.capturedMonotonicMs,
      source: TimeSourceMetadata(
        kind: TimeSourceKind.nts,
        id: id,
        host: _host,
        stratum: best.raw.serverStratum,
        authenticated: true,
      ),
      capturedAt: best.capturedAt,
    );
  }
}

/// Internal pairing of a raw NTS sample with the monotonic + wall
/// references captured the instant its response was received.
class _BurstSample {
  _BurstSample(this.raw, this.capturedMonotonicMs, this.capturedAt);
  final NtsTimeSample raw;
  final int capturedMonotonicMs;
  final DateTime capturedAt;
}
