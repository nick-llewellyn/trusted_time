import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../infra/trusted_time_log.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../exceptions.dart';
import '../models.dart';
import '../monotonic_clock.dart';
import 'nts_auth_level.dart';

/// Collapses the successful samples of one [NtsSource] query burst
/// into the single sample handed to the consensus.
///
/// Invoked with a non-empty list; every sample comes from the same
/// host within one [NtsSource.getTime] call, so cross-source
/// comparability is not a concern. The returned sample **must be one
/// of the input instances** (an element of `samples`, compared by
/// identity): [NtsSource] maps the winner back to its raw attempt to
/// attribute the server stratum, and a copied or derived instance
/// breaks that mapping — stratum reporting is then skipped for the
/// burst (asserted in debug builds).
typedef NtsBurstReducer = TimeSample Function(List<TimeSample> samples);

/// Default [NtsBurstReducer]: keeps the sample with the smallest
/// measured delay ([TimeSample.delayMs] — the network-only peer delay
/// δ for samples carrying the 7.1 clock-filter fields, else the whole
/// round trip).
///
/// The minimum measured delay is the tightest, least path-asymmetric
/// estimate in the burst — the burst-and-pick-min strategy
/// `package:nts` documents, and the reduction the validate tier
/// relies on via `SyncEngine.validate()`'s single `getTime()` call.
/// The comparison key is [TimeSample.delayMs] when measured, else
/// `2 × uncertaintyMs` (the interval half-width is ≈ δ/2, so doubling
/// keeps the key in delay units). For NTS samples carrying the 7.1
/// clock-filter fields, [TimeSample.delayMs] is the RFC 5905 peer
/// delay δ (round trip minus server processing time), so the key
/// excludes server-side latency and selects on pure network delay;
/// pre-7.1 samples carry the whole RTT there and reduce exactly as
/// before. All samples in a burst come from one source, so the key is
/// internally consistent even when δ is unmeasured.
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
/// **Query burst:** [getTime] issues up to `burstCount` *sequential*
/// queries against the warmed jar and reduces the successes to one
/// sample via the configured [NtsBurstReducer] (lowest RTT by
/// default). The burst is serial by design, mirroring `package:nts`'s
/// own one-call `getTime`: concurrent samples fired at one server
/// travel the same path as a dense cluster and share any transient
/// queue spike, defeating the lowest-delay selection, whereas
/// sequential queries let the local interface queue drain between
/// samples so each observes an independent snapshot of the path.
/// Sequencing also keeps the burst cookie-neutral on success — each
/// reply's in-band refill lands before the next query spends a
/// cookie. The whole burst shares one `maxLatency` wall-clock budget
/// as a shrinking deadline; if the budget depletes mid-burst the
/// remaining attempts are skipped and the best sample gathered so far
/// wins, so slow paths degrade to fewer samples rather than no
/// result. Only a total-loss burst drains the jar (a failed attempt
/// spends its cookie without a refill); at the full-jar burst size of
/// 8 that forces an NTS-KE re-handshake before the next attempt.
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
  /// [maxLatency] is the total wall-clock budget for the whole query
  /// burst, shared across the sequential attempts as one shrinking
  /// deadline measured on the resolved monotonic reader (sleep-aware
  /// when the nts bridge is initialized, matching [NtpSource]): each
  /// attempt's `ntsQuery` receives the remaining balance as its
  /// `timeout`, so the burst as a whole completes within
  /// [maxLatency]. [SyncEngine] passes
  /// [TrustedTimeConfig.maxLatency] so this inner budget matches the
  /// outer `.timeout(_config.maxLatency)` wrapper. Without this, an
  /// inner timeout longer than the outer would always be pre-empted by
  /// Dart's `TimeoutException`, swallowing the phase-tagged
  /// `NtsError.timeout(TimeoutPhase)` payload that drives the
  /// [TransientSourceError] cooldown-bypass path. The default of 5 s
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
  /// [burstCount] is the maximum number of sequential queries
  /// [getTime] issues per call within the [maxLatency] budget; the
  /// successes are collapsed to one sample by [reducer] (default
  /// [lowestRttReducer]). Must be in `1..8`, matching the fixed
  /// 8-sample burst `package:nts`'s own one-call `getTime` uses and
  /// bounding the worst-case jar drain of a total-loss burst (a
  /// failed attempt spends its cookie without an in-band refill) to
  /// one full 8-cookie jar (RFC 8915) — which forces an NTS-KE
  /// re-handshake before the next attempt.
  /// Enforced with a [RangeError] in all build modes:
  /// the value typically arrives from the public
  /// [TrustedTimeConfig.ntsBurstCount] knob, whose const constructor
  /// can only `assert`, so this is where an out-of-range value fails
  /// deterministically in release builds. The default of `1` preserves
  /// single-query behaviour for direct callers; [SyncEngine] passes
  /// [TrustedTimeConfig.ntsBurstCount].
  ///
  /// [debugQueryOverride] replaces the `client.query` call for tests
  /// that need to script per-attempt outcomes without touching the FFI
  /// surface; when set, no [nts.NtsClient] is minted and [warm] is a
  /// no-op (there is no real cookie jar to prime).
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
  }) : _spec = nts.NtsServerSpec(host: _host, port: port),
       _dnsConcurrencyCap = dnsConcurrencyCap,
       _timeout = maxLatency,
       _trustMode = trustMode,
       _customRoots = customRoots,
       _onStratumObserved = onStratumObserved,
       _burstCount = RangeError.checkValueInInterval(
         burstCount,
         1,
         8,
         'burstCount',
         'must be in 1..8 (NTS cookie-jar economics)',
       ),
       _reducer = reducer,
       _debugQueryOverride = debugQueryOverride;

  final String _host;
  final nts.NtsServerSpec _spec;
  final int _dnsConcurrencyCap;
  final Duration _timeout;
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
    // Honour the [debugQueryOverride] contract: the override scripts the
    // query path without touching the FFI surface, so warming must not
    // mint an [nts.NtsClient] either. There is no real cookie jar to
    // prime when the query itself is scripted, so this is a pure no-op
    // rather than a memoized task.
    if (_debugQueryOverride != null) return Future.value();
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
    final Future<nts.NtsTimeSample> Function(Duration timeout) runQuery;
    if (override != null) {
      // The override scripts per-attempt outcomes; the per-attempt
      // budget does not apply to it (tests own their timing), but the
      // shared burst deadline below still bounds how many attempts run.
      runQuery = (_) => override();
    } else {
      final client = _client ??= nts.NtsClient(
        trustMode: _trustMode,
        customRoots: _customRoots,
      );
      runQuery = (timeout) => client.query(
        spec: _spec,
        timeout: timeout,
        dnsConcurrencyCap: _dnsConcurrencyCap,
      );
    }

    // Run the burst sequentially — serial by design, mirroring
    // `package:nts`'s own one-call getTime. Concurrent samples fired
    // at one server travel the same path as a dense cluster and share
    // any transient queue spike, defeating the lowest-delay
    // selection; sequential queries let the local interface queue
    // drain between samples so each observes an independent snapshot
    // of the path. Sequencing also keeps the burst cookie-neutral on
    // success: each reply's in-band refill lands before the next
    // query spends a cookie.
    //
    // The whole burst shares one [_timeout] wall-clock budget as a
    // shrinking deadline, measured on the resolved monotonic reader
    // (sleep-aware when the nts bridge is initialized — the same
    // clock model as [NtpSource.getTime], so a device suspend
    // mid-burst depletes the budget instead of freezing it): the
    // first attempt receives the configured budget verbatim (always
    // dispatching, and preserving the wrapper's own validation of
    // sub-1ms budgets), each later attempt receives the remaining
    // balance, and once the balance dips below the floor the
    // remaining attempts are skipped — the burst degrades to fewer
    // samples rather than overrunning the window a single query
    // would have had. An all-fail burst thus always carries a
    // concrete underlying error. Every attempt guards its own
    // failure; the burst as a whole succeeds when at least one
    // attempt lands.
    // Sequential execution appends successes in attempt-index order,
    // so the reducer's "first wins" tie-break (and thus the winning
    // sample and its stratum attribution) stays deterministic when
    // RTT keys tie.
    var transientFailures = 0;
    var attempts = 0;
    Object? lastError;
    StackTrace? lastStackTrace;
    Object? lastNonTransientError;
    StackTrace? lastNonTransientStackTrace;

    const floor = Duration(milliseconds: 1);
    final clock = resolveMonotonicReader();
    final startMicros = clock.read();
    final successes = <_BurstSuccess>[];
    for (var attempt = 0; attempt < _burstCount; attempt++) {
      final remaining = attempt == 0
          ? _timeout
          : _timeout - Duration(microseconds: clock.read() - startMicros);
      if (attempt > 0 && remaining < floor) break;
      attempts++;
      try {
        final result = await runQuery(remaining);
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
      } on TransientSourceError catch (e, st) {
        // An already-wrapped transient error — e.g. thrown directly by
        // a [debugQueryOverride] script, or by a future refactor that
        // classifies timeouts earlier — must keep its transient
        // semantics so an all-transient burst still bypasses cooldown.
        transientFailures++;
        lastError = e;
        lastStackTrace = st;
      } catch (e, st) {
        lastError = lastNonTransientError = e;
        lastStackTrace = lastNonTransientStackTrace = st;
      }
    }

    if (TrustedTimeLog.enabled) {
      final rtts = successes
          .map((s) => (s.raw.roundTripMicros / 1000).toStringAsFixed(1))
          .join(', ');
      // Per-attempt receipt deltas relative to the burst's earliest
      // receipt, in attempt-index order (failed attempts filtered) —
      // surfaces the intra-burst receipt spread that the engine's
      // normalization absorbs.
      var receipts = '';
      if (successes.isNotEmpty) {
        final earliest = successes
            .map((s) => s.receivedAtMs)
            .reduce((a, b) => a < b ? a : b);
        receipts = successes
            .map((s) => '+${s.receivedAtMs - earliest}')
            .join(', ');
      }
      TrustedTimeLog.log(
        TrustedTimeLogLevel.debug,
        '[TrustedTime] nts:$_host burst '
        '${successes.length}/$attempts succeeded rtts=[$rtts]ms '
        'receipts=[$receipts]ms',
      );
    }

    if (successes.isEmpty) {
      // Every dispatched attempt failed (budget-skipped attempts do
      // not count). Classify the burst as transient only when every
      // failure was transient — a single hard failure means the
      // standard cooldown path must still arm, so a non-transient
      // error takes precedence over any transient sibling.
      final error = transientFailures == attempts
          ? lastError!
          : lastNonTransientError!;
      final stack = transientFailures == attempts
          ? lastStackTrace!
          : lastNonTransientStackTrace!;
      Error.throwWithStackTrace(error, stack);
    }

    // Reduce the burst to one sample (lowest RTT by default) and
    // report stratum once, from the winning attempt, so the quality
    // tracker sees exactly one observation per getTime() call as
    // before. The identity lookup is the [NtsBurstReducer] contract:
    // a reducer that returns a copy or derived instance cannot be
    // mapped back to a raw attempt, so rather than attribute some
    // other attempt's stratum, reporting is skipped for the burst.
    final samples = successes
        .map((s) => _toTimeSample(s.raw, s.receivedAtMs))
        .toList(growable: false);
    final winner = _reducer(samples);
    final winnerIndex = samples.indexWhere((s) => identical(s, winner));
    assert(
      winnerIndex >= 0,
      'NtsBurstReducer must return one of its input samples '
      '(identity-preserved); got a copied or derived instance, so the '
      'winning attempt cannot be identified for stratum attribution.',
    );
    if (winnerIndex >= 0) {
      _onStratumObserved?.call(successes[winnerIndex].raw.serverStratum);
    }
    return winner;
  }

  /// Converts one successful raw query result into the [TimeSample]
  /// shape the engine consumes, stamped with that attempt's own
  /// receipt instant.
  ///
  /// When the 7.1 clock-filter fields are available (peer delay δ
  /// inside its documented plausibility window `(0, roundTripMicros]`),
  /// the interval follows RFC 5905: the midpoint is the server
  /// transmit time compensated by half the network delay
  /// (`utcUnixMicros + δ/2`, the server's clock at the moment the
  /// reply arrived) and the half-width is the root distance
  /// `Λ = δ/2 + rootDelay/2 + rootDispersion` — a provably correct
  /// bound that excludes server processing time, so it is materially
  /// tighter than the RTT/2 worst case against distant servers with
  /// fast processing. A zero or implausible δ means the fields are
  /// unavailable (pre-7.1 fixture) or a local clock step corrupted the
  /// exchange; those samples keep the legacy `utcUnixMicros ± RTT/2`
  /// shape byte-for-byte.
  TimeSample _toTimeSample(nts.NtsTimeSample result, int receivedAtMs) {
    final rttMicros = result.roundTripMicros;
    final peerDelayMicros = result.peerDelayMicros;
    // Upstream's documented plausibility check: δ outside
    // (0, roundTripMicros] signals "not available" (zero sentinel) or
    // a local clock step mid-exchange — fall back to whole-RTT math.
    final hasClockFilter = peerDelayMicros > 0 && peerDelayMicros <= rttMicros;

    final int timestampMs;
    final int uncertaintyMs;
    final int delayMs;
    final int dispersionMs;
    if (hasClockFilter) {
      timestampMs = (result.utcUnixMicros + peerDelayMicros ~/ 2) ~/ 1000;
      delayMs = peerDelayMicros ~/ 1000;
      // Server-side error budget E = rootDelay/2 + rootDispersion,
      // kept on [TimeSample.dispersionMs] so
      // [TimeSample.rootDistanceMs] (Λ = E + δ/2) reproduces the
      // half-width used here. rootDelay/2 and the ms conversion both
      // round *up* so no division ever shrinks the budget — Λ is a
      // bound, so conversion error must widen it, not shrink it.
      final errorBudgetMicros =
          (result.rootDelayMicros + 1) ~/ 2 + result.rootDispersionMicros;
      dispersionMs = (errorBudgetMicros + 999) ~/ 1000;
      uncertaintyMs = peerDelayMicros ~/ 2000 + dispersionMs;
    } else {
      timestampMs = result.utcUnixMicros ~/ 1000;
      delayMs = rttMicros ~/ 1000;
      dispersionMs = 0;
      uncertaintyMs = rttMicros ~/ 2000;
    }

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
      // Network delay δ — peer delay when the clock-filter fields are
      // plausible, else the whole RTT — kept separate from the
      // interval half-width so root distance (Λ = E + δ/2) is
      // computable and burst reduction keys on network delay.
      delayMs: delayMs,
      dispersionMs: dispersionMs,
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
