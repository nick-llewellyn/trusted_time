import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../exceptions.dart';
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
/// **Cookie jar lifecycle:** [warm] runs `NtsClient.warmCookies` to
/// perform the NTS-KE handshake (TCP + TLS + KE, ~3 RTTs) and prime
/// the cookie jar. [SyncEngine] awaits this in its warming phase
/// before starting the per-query timeout, so the handshake cost
/// falls outside the `maxLatency` budget. The warm result is
/// memoized; subsequent calls share the same completed [Future].
/// Each successful query receives one fresh cookie in-band, keeping
/// the pool self-sustaining. If warming fails or is skipped,
/// [getTime] still calls [warm] as a JIT fallback; when that fails
/// too, [nts.NtsClient.query] performs its own cold-start handshake
/// transparently.
///
/// **Per-source [nts.NtsClient]:** Each [NtsSource] owns its own
/// [nts.NtsClient] instance, lazily constructed on first [warm] (or
/// first [getTime] if warm fails to mint it). Two sources never
/// share session table, cookie pool, AEAD keys, or KE session
/// state; one host's cookie-jar refill stall (e.g. the bimodal
/// pattern documented in `trusted_time-skj.4`) cannot starve
/// another. This also gives test fakes / stubs that wrap their own
/// [nts.NtsClient] full session-state isolation from any concurrent
/// real source running in the same isolate.
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
  /// (`4` as of `package:nts` 4.0.0; the pre-4.0 `0` sentinel that
  /// inherited the same cap is now rejected by the wrapper's range
  /// validator). [SyncEngine] overrides this with
  /// `ntsServers.length + 2` so multi-host pools do not lose admission
  /// races against the global resolver pool.
  ///
  /// [maxLatency] is forwarded as `ntsQuery`'s `timeoutMs`. [SyncEngine]
  /// passes [TrustedTimeConfig.maxLatency] so the inner per-query budget
  /// matches the outer `.timeout(_config.maxLatency)` wrapper. Without
  /// this, an inner timeout longer than the outer would always be
  /// pre-empted by Dart's `TimeoutException`, swallowing the
  /// phase-tagged `NtsError.timeout(TimeoutPhase)` payload that drives
  /// the [TransientSourceError] cooldown-bypass path. The default of 5 s
  /// preserves the package's pre-coordination behaviour for direct
  /// callers.
  ///
  /// [trustMode] selects the trust-anchor policy applied to the
  /// per-source [nts.NtsClient]. [SyncEngine] passes the mode resolved
  /// by [TrustedTimeConfig.effectiveTrustMode] — `bundledOnly` by
  /// default, `platformOnly` when the consumer opts into platform
  /// trust, or `custom` when caller-supplied roots are configured. The
  /// parameter default of [nts.TrustMode.platformWithFallback] mirrors
  /// `package:nts`'s own constructor default and applies only to direct
  /// (non-engine) callers.
  ///
  /// [customRoots] is forwarded verbatim to the [nts.NtsClient]
  /// constructor and must be non-null and non-empty when (and only
  /// when) [trustMode] is [nts.TrustMode.custom]; `package:nts` throws
  /// `ArgumentError` otherwise. [SyncEngine] satisfies this by passing
  /// [TrustedTimeConfig.customRootCerts] (or `null` when empty)
  /// alongside the resolved mode.
  ///
  /// [onStratumObserved] is called with the NTP stratum reported by
  /// the server after each successful query. Used by [SyncEngine] to
  /// feed stratum hints into `SourceQualityTracker` without widening
  /// [TimeSample]. Added in upstream 2.1.0; optional so callers that
  /// don't run quality scoring (e.g. unit tests) need not supply it.
  NtsSource(
    this._host, {
    int port = 4460,
    int dnsConcurrencyCap = nts.kDefaultDnsConcurrencyCap,
    Duration maxLatency = const Duration(seconds: 5),
    nts.TrustMode trustMode = nts.TrustMode.platformWithFallback,
    List<int>? customRoots,
    void Function(int)? onStratumObserved,
  }) : _spec = nts.NtsServerSpec(host: _host, port: port),
       _dnsConcurrencyCap = dnsConcurrencyCap,
       _timeoutMs = maxLatency.inMilliseconds,
       _trustMode = trustMode,
       _customRoots = customRoots,
       _onStratumObserved = onStratumObserved;

  final String _host;
  final nts.NtsServerSpec _spec;
  final int _dnsConcurrencyCap;
  final int _timeoutMs;
  final nts.TrustMode _trustMode;
  final List<int>? _customRoots;
  final void Function(int)? _onStratumObserved;

  /// Per-source [nts.NtsClient]. Lazily constructed on first [warm]
  /// or first [getTime] call so the [NtsSource] constructor never
  /// touches the FFI surface (matching the lifetime of [_warmTask]
  /// below). Owned exclusively by this source — the session table,
  /// cookie pool, AEAD keys, and KE session live here, isolated from
  /// every other [NtsSource] instance and from `package:nts`'s
  /// process-wide singleton client used by the top-level
  /// `nts.ntsQuery` / `nts.ntsWarmCookies` convenience functions.
  nts.NtsClient? _client;

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

    // Mint the client here as a fallback if [_performWarming]
    // swallowed a construction failure (e.g. NtsRustLib not yet
    // initialised at warm time, in which case
    // `nts.NtsClient(trustMode: _trustMode)` throws `StateError`).
    // Two distinct failure modes propagate unwrapped from this
    // method, matching the loud-getTime / lossy-warm contract:
    //
    //   - Construction failure: `StateError` from
    //     `nts.NtsClient(trustMode: _trustMode)` below, before the
    //     query try/catch is entered. Indicates a structural
    //     problem (NtsRustLib not initialised) rather than a transient
    //     network issue, so it is intentionally not translated into
    //     an `nts.NtsError` subtype.
    //   - Query failure: `nts.NtsError` (or `TransientSourceError`
    //     for the dnsSaturation phase) thrown from `client.query`
    //     below and handled by the existing on-clauses.
    final client = _client ??= nts.NtsClient(
      trustMode: _trustMode,
      customRoots: _customRoots,
    );

    final nts.NtsTimeSample result;
    try {
      result = await client.query(
        spec: _spec,
        timeoutMs: _timeoutMs,
        dnsConcurrencyCap: _dnsConcurrencyCap,
      );
    } on nts.NtsErrorTimeout catch (e) {
      // Dns(Saturation) means the bounded DNS resolver pool was at
      // capacity for this call. The host itself is healthy; SyncEngine
      // should retry on the next cycle without applying exponential
      // cooldown. Other timeout phases (Connect, Tls, KeRecordIo, Ntp,
      // DnsTimeout) propagate as-is and follow the standard cooldown
      // path.
      if (e.phase == nts.TimeoutPhase.dnsSaturation) {
        throw TransientSourceError(e);
      }
      rethrow;
    }

    if (kDebugMode) {
      final p = result.phaseTimings;
      debugPrint(
        '[TrustedTime] nts:$_host '
        'rtt=${(result.roundTripMicros / 1000).toStringAsFixed(1)}ms '
        'dns=${(p.dnsMicros / 1000).toStringAsFixed(1)}ms '
        'connect=${(p.connectMicros / 1000).toStringAsFixed(1)}ms '
        'tls=${(p.tlsHandshakeMicros / 1000).toStringAsFixed(1)}ms '
        'ke=${(p.keRecordIoMicros / 1000).toStringAsFixed(1)}ms',
      );
    }

    // Report stratum to quality tracker if a listener is registered.
    // Added in upstream 2.1.0; SyncEngine wires this to
    // SourceQualityTracker.setStratum so the 20% stratum weight in
    // the quality score has fresh data after every successful query.
    _onStratumObserved?.call(result.serverStratum);

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
      // Surfaced unchanged from the underlying handshake so
      // telemetry consumers can distinguish platform-store
      // authentication from the static webpki-roots fallback (and,
      // on Android, the per-chain hybrid-fallback path). See
      // [TimeSample.trustBackend] for the semantics of each value.
      trustBackend: result.trustBackend,
    );
  }

  Future<void> _performWarming() async {
    try {
      // Lazy-mint the per-source client.
      // `nts.NtsClient(trustMode: _trustMode)` is a synchronous
      // factory backed by an FRB dispatch; it throws `StateError`
      // if `NtsRustLib.init()` has not completed. The outer catch
      // swallows that case so the warm path stays lossy as
      // documented; [getTime] re-attempts construction so the
      // structural failure surfaces with a real query attempt.
      final client = _client ??= nts.NtsClient(
        trustMode: _trustMode,
        customRoots: _customRoots,
      );
      await client.warmCookies(
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
