import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../exceptions.dart';
import '../models.dart';
import 'nts_auth_level.dart';

/// Collapses the successful samples of one [NtsSource] query burst
/// into the single sample handed to the consensus.
///
/// Invoked with a non-empty list; every sample comes from the same
/// host within one [NtsSource.getTime] call, so cross-source
/// comparability is not a concern. The returned sample must be one of
/// (or derived from) the inputs.
typedef NtsBurstReducer = TimeSample Function(List<TimeSample> samples);

/// Default [NtsBurstReducer]: keeps the sample with the smallest
/// round-trip delay.
///
/// The minimum measured RTT is the tightest, least path-asymmetric
/// estimate in the burst — the burst-and-pick-min strategy
/// `package:nts` documents, and the same reduction the validate tier
/// applies via `SyncEngine.validate()`. The comparison key matches
/// `SyncEngine._rttKey`: [TimeSample.delayMs] when measured, else
/// `2 × uncertaintyMs` (the interval half-width is ≈ δ/2, so doubling
/// keeps the key in RTT units). All samples in a burst come from one
/// source, so the key is internally consistent even when δ is
/// unmeasured.
TimeSample lowestRttReducer(List<TimeSample> samples) {
  assert(samples.isNotEmpty, 'reducer requires at least one sample');
  var best = samples.first;
  for (final s in samples.skip(1)) {
    if (_rttKey(s) < _rttKey(best)) best = s;
  }
  return best;
}

int _rttKey(TimeSample sample) => sample.delayMs ?? (2 * sample.uncertaintyMs);

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
/// **Query burst:** [getTime] issues `burstCount` concurrent queries
/// against the warmed jar and reduces the successes to one sample via
/// the configured [NtsBurstReducer] (lowest RTT by default). Each
/// attempt spends one cookie up-front and each success returns two
/// in-band (net +1), so with the cap of 4 even a total-loss burst
/// leaves half the jar for a retry burst without a mid-window
/// re-handshake.
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
  /// the server after each successful query burst. Used by [SyncEngine]
  /// to feed stratum hints into `SourceQualityTracker` without widening
  /// [TimeSample]. Added in upstream 2.1.0; optional so callers that
  /// don't run quality scoring (e.g. unit tests) need not supply it.
  ///
  /// [burstCount] is the number of concurrent queries [getTime] issues
  /// per call; the successes are collapsed to one sample by [reducer]
  /// (default [lowestRttReducer]). Must be in `1..4` — the cap keeps a
  /// total-loss burst from draining the 8-cookie jar past the point
  /// where a full retry burst can run without a mid-window
  /// re-handshake. The default of `1` preserves single-query behaviour
  /// for direct callers; [SyncEngine] passes
  /// [TrustedTimeConfig.ntsBurstCount].
  ///
  /// [debugQueryOverride] replaces the `client.query` call for tests
  /// that need to script per-attempt outcomes without touching the FFI
  /// surface; when set, no [nts.NtsClient] is minted.
  NtsSource(
    this._host, {
    int port = 4460,
    int dnsConcurrencyCap = nts.kDefaultDnsConcurrencyCap,
    Duration maxLatency = const Duration(seconds: 5),
    nts.TrustMode trustMode = nts.TrustMode.platformWithFallback,
    List<int>? customRoots,
    void Function(int)? onStratumObserved,
    int burstCount = 1,
    NtsBurstReducer reducer = lowestRttReducer,
    @visibleForTesting Future<nts.NtsTimeSample> Function()? debugQueryOverride,
  }) : assert(
         burstCount >= 1 && burstCount <= 4,
         'burstCount must be in 1..4 (NTS cookie-jar economics)',
       ),
       _spec = nts.NtsServerSpec(host: _host, port: port),
       _dnsConcurrencyCap = dnsConcurrencyCap,
       _timeoutMs = maxLatency.inMilliseconds,
       _trustMode = trustMode,
       _customRoots = customRoots,
       _onStratumObserved = onStratumObserved,
       _burstCount = burstCount,
       _reducer = reducer,
       _debugQueryOverride = debugQueryOverride;

  final String _host;
  final nts.NtsServerSpec _spec;
  final int _dnsConcurrencyCap;
  final int _timeoutMs;
  final nts.TrustMode _trustMode;
  final List<int>? _customRoots;
  final void Function(int)? _onStratumObserved;
  final int _burstCount;
  final NtsBurstReducer _reducer;
  final Future<nts.NtsTimeSample> Function()? _debugQueryOverride;

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
    // before issuing the timed queries. SyncEngine normally awaits
    // warm() in its dedicated warming phase (and, since the global
    // warming barrier, before any source's query launches), so this is
    // a no-op in that path.
    await warm();

    // Mint the client here as a fallback if [_performWarming]
    // swallowed a construction failure (e.g. NtsRustLib not yet
    // initialised at warm time, in which case
    // `nts.NtsClient(trustMode: _trustMode)` throws `StateError`).
    // Two distinct failure modes propagate unwrapped from this
    // method, matching the loud-getTime / lossy-warm contract:
    //
    //   - Construction failure: `StateError` from
    //     `nts.NtsClient(trustMode: _trustMode)` below, before any
    //     query attempt is launched. Indicates a structural
    //     problem (NtsRustLib not initialised) rather than a transient
    //     network issue, so it is intentionally not translated into
    //     an `nts.NtsError` subtype.
    //   - Query failure: `nts.NtsError` (or `TransientSourceError`
    //     for the dnsSaturation phase) thrown when every attempt in
    //     the burst fails; see the classification below.
    final override = _debugQueryOverride;
    final Future<nts.NtsTimeSample> Function() runQuery;
    if (override != null) {
      runQuery = override;
    } else {
      final client = _client ??= nts.NtsClient(
        trustMode: _trustMode,
        customRoots: _customRoots,
      );
      runQuery = () => client.query(
        spec: _spec,
        timeoutMs: _timeoutMs,
        dnsConcurrencyCap: _dnsConcurrencyCap,
      );
    }

    // Launch the burst concurrently. All attempts share this source's
    // session table (one cookie per attempt, spent up-front) and each
    // carries its own timeoutMs budget, so a straggler times out
    // inside the same window a single query would have. Every attempt
    // guards its own failure; the burst as a whole succeeds when at
    // least one attempt lands.
    final successes = <_BurstSuccess>[];
    var transientFailures = 0;
    Object? lastError;
    StackTrace? lastStackTrace;
    Object? lastNonTransientError;
    StackTrace? lastNonTransientStackTrace;

    await Future.wait(
      List.generate(_burstCount, (_) async {
        try {
          final result = await runQuery();
          // Capture the receipt instant here — at each attempt's own
          // completion — so per-attempt receivedAtMs stays accurate
          // for the engine's receipt normalization. Stamped on the
          // monotonic receipt timeline so a wall-clock step mid-burst
          // cannot corrupt the deltas normalization consumes.
          successes.add(
            _BurstSuccess(
              raw: result,
              receivedAtMs: TimeSample.monotonicReceiptNowMs(),
            ),
          );
        } on nts.NtsErrorTimeout catch (e, st) {
          // Dns(Saturation) means the bounded DNS resolver pool was at
          // capacity for this attempt. The host itself is healthy;
          // SyncEngine should retry on the next cycle without applying
          // exponential cooldown. Other timeout phases (Connect, Tls,
          // KeRecordIo, Ntp, DnsTimeout) follow the standard cooldown
          // path when the whole burst fails.
          if (e.phase == nts.TimeoutPhase.dnsSaturation) {
            transientFailures++;
            lastError = TransientSourceError(e);
            lastStackTrace = st;
          } else {
            lastError = lastNonTransientError = e;
            lastStackTrace = lastNonTransientStackTrace = st;
          }
        } catch (e, st) {
          lastError = lastNonTransientError = e;
          lastStackTrace = lastNonTransientStackTrace = st;
        }
      }),
    );

    if (kDebugMode) {
      final rtts = successes
          .map((s) => (s.raw.roundTripMicros / 1000).toStringAsFixed(1))
          .join(', ');
      debugPrint(
        '[TrustedTime] nts:$_host burst '
        '${successes.length}/$_burstCount succeeded rtts=[$rtts]ms',
      );
    }

    if (successes.isEmpty) {
      // Every attempt failed. Classify the burst as transient only
      // when every failure was transient — a single hard failure means
      // the standard cooldown path must still arm, so a non-transient
      // error takes precedence over any transient sibling.
      final error = transientFailures == _burstCount
          ? lastError!
          : lastNonTransientError!;
      final stack = transientFailures == _burstCount
          ? lastStackTrace!
          : lastNonTransientStackTrace!;
      Error.throwWithStackTrace(error, stack);
    }

    // Reduce the burst to one sample (lowest RTT by default) and
    // report stratum once, from the winning attempt, so the quality
    // tracker sees exactly one observation per getTime() call as
    // before.
    final samples = successes
        .map((s) => _toTimeSample(s.raw, s.receivedAtMs))
        .toList(growable: false);
    final winner = _reducer(samples);
    final winnerIndex = samples.indexWhere((s) => identical(s, winner));
    final winningRaw = successes[winnerIndex >= 0 ? winnerIndex : 0].raw;
    _onStratumObserved?.call(winningRaw.serverStratum);
    return winner;
  }

  /// Converts one successful raw query result into the [TimeSample]
  /// shape the engine consumes, stamped with that attempt's own
  /// receipt instant.
  TimeSample _toTimeSample(nts.NtsTimeSample result, int receivedAtMs) {
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
      // Local receipt instant, so the engine can normalize samples
      // received at different points in the cycle to one reference
      // instant before Marzullo intersection.
      receivedAtMs: receivedAtMs,
      // Whole round-trip delay δ (RTT), kept separate from the interval
      // half-width so root distance (Λ = E + δ/2) is computable. The
      // interval math above is unchanged.
      delayMs: result.roundTripMicros ~/ 1000,
      // Classify by the trust anchor that authenticated this handshake
      // rather than assuming every successful NTS query is verified: a
      // platform-mediated path (which may chain through a
      // corporate-injected or MDM-installed CA) degrades to
      // NtsAuthLevel.none. See [authLevelForTrustBackend].
      authLevel: authLevelForTrustBackend(result.trustBackend),
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

/// One successful burst attempt: the raw query result paired with the
/// local receipt instant captured at that attempt's completion.
final class _BurstSuccess {
  const _BurstSuccess({required this.raw, required this.receivedAtMs});

  final nts.NtsTimeSample raw;
  final int receivedAtMs;
}

/// Maps the trust-anchor backend that authenticated an NTS handshake to
/// the [NtsAuthLevel] recorded on the resulting [TimeSample].
///
/// [NtsAuthLevel.verified] is reserved for library-controlled trust
/// stores — [nts.TrustBackend.webpkiRoots] (bundled roots) and
/// [nts.TrustBackend.custom] (caller-supplied roots) — where a
/// corporate-injected or MDM-installed CA cannot reach the validation
/// path. Platform-mediated paths ([nts.TrustBackend.platform] and the
/// Android-only [nts.TrustBackend.platformWithHybridFallback]) and the
/// defensive `null` case map to [NtsAuthLevel.none]: the TLS handshake
/// succeeded, but its authenticity is not end-to-end verifiable from the
/// library, so the sample must never anchor the consensus truth box.
///
/// `platformWithHybridFallback` maps to `none` even though the bundle
/// was the authoritative anchor for that particular chain — the *path*
/// still runs through platform machinery, and the contract requires the
/// conservative classification.
///
/// Exposed via [visibleForTesting] for the mapping-table coverage in
/// `test/nts_source_test.dart`; it is not part of the public API. See
/// `doc/design/tiered-trust-implementation.md` section 3.2.
@visibleForTesting
NtsAuthLevel authLevelForTrustBackend(nts.TrustBackend? backend) {
  switch (backend) {
    case nts.TrustBackend.webpkiRoots:
    case nts.TrustBackend.custom:
      return NtsAuthLevel.verified;
    case nts.TrustBackend.platform:
    case nts.TrustBackend.platformWithHybridFallback:
    case null:
      return NtsAuthLevel.none;
  }
}
