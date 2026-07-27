import 'dart:async' show TimeoutException;
import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:flutter/foundation.dart' show visibleForTesting;
import '../data/asn_bundle_loader.dart';
import '../data/asn_resolver.dart';
import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../infra/dns_budget.dart';
import '../infra/trusted_time_log.dart';
import '../monotonic_clock.dart';
import 'ntp_client.dart';

/// Resolves [host] to its addresses. Injectable so tests can supply a
/// deterministic mapping without real DNS.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// NTP time source — IO-only (uses UDP sockets via `dart:io`).
///
/// Each [getTime] call issues a sequential burst of SNTP exchanges
/// against the resolved server and keeps the sample with the smallest
/// network delay δ — the same burst-and-pick-min strategy [NtsSource]
/// uses, applied to plain NTP. Each exchange computes the RFC 5905
/// pair θ/δ from the four exchange timestamps, so the interval
/// midpoint excludes server processing time and the half-width is the
/// root distance `Λ = δ/2 + rootDelay/2 + rootDispersion`, mirroring
/// the NTS clock-filter shape.
final class NtpSource implements TimeSource {
  /// Creates an NTP source for [host].
  ///
  /// [asnResolver], [hostResolver] and [exchange] are injection seams
  /// for tests; in production they default to the shared offline ASN
  /// snapshot, real DNS resolution, and [defaultNtpExchange]
  /// respectively. All default to `null` and the shared defaults are
  /// resolved lazily via getters.
  ///
  /// [dnsBudget] is the shared SyncEngine-level DNS concurrency budget
  /// (ADR 0008). When supplied, host resolution is admitted through it
  /// cache-first; when `null` (direct callers, tests) resolution runs
  /// ungoverned.
  ///
  /// [maxLatency] is the total wall-clock budget for one [getTime]
  /// call — host resolution plus the whole query burst — shared as
  /// one shrinking deadline: the clock starts before resolution and
  /// each attempt's exchange receives the remaining balance as its
  /// timeout, so the call as a whole completes within [maxLatency].
  /// [SyncEngine] passes [TrustedTimeConfig.maxLatency] so this inner
  /// budget matches the outer `.timeout(_config.maxLatency)` wrapper.
  ///
  /// [burstCount] is the maximum number of sequential exchanges
  /// [getTime] issues per call within the [maxLatency] budget; the
  /// successes are collapsed to the single lowest-δ sample. Must be in
  /// `1..8`, matching [NtsSource]'s burst cap so the two source kinds
  /// share one worst-case wall-time model. Enforced with a
  /// [RangeError] in all build modes for the same reason as
  /// [NtsSource]: the value typically arrives from the public
  /// [TrustedTimeConfig.ntpBurstCount] knob, whose const constructor
  /// can only `assert`. The default of `1` preserves single-query
  /// behaviour for direct callers; [SyncEngine] passes
  /// [TrustedTimeConfig.ntpBurstCount].
  ///
  /// [onStratumObserved] is called with the stratum reported by the
  /// server on the winning exchange of each successful burst. Used by
  /// [SyncEngine] to feed stratum hints into `SourceQualityTracker`
  /// without widening [TimeSample]; optional so callers that don't run
  /// quality scoring need not supply it.
  NtpSource(
    this._host, {
    AsnResolver? asnResolver,
    HostResolver? hostResolver,
    NtpExchange? exchange,
    DnsBudget? dnsBudget,
    Duration maxLatency = const Duration(seconds: 5),
    int burstCount = 1,
    void Function(int)? onStratumObserved,
  }) : _asnOverride = asnResolver,
       _hostOverride = hostResolver,
       _exchangeOverride = exchange,
       _dnsBudget = dnsBudget,
       _timeout = maxLatency,
       _burstCount = RangeError.checkValueInInterval(
         burstCount,
         1,
         8,
         'burstCount',
         'must be in 1..8 (matches the NTS burst cap)',
       ),
       _onStratumObserved = onStratumObserved;

  /// Shared across all NTP sources so the bundled ASN table is
  /// decompressed and held in memory exactly once per isolate.
  static final AsnResolver _sharedAsn = AsnResolver(
    loader: rootBundleAssetLoader,
  );

  final String _host;
  final AsnResolver? _asnOverride;
  final HostResolver? _hostOverride;
  final NtpExchange? _exchangeOverride;
  final DnsBudget? _dnsBudget;
  final Duration _timeout;
  final int _burstCount;
  final void Function(int)? _onStratumObserved;

  AsnResolver get _asn => _asnOverride ?? _sharedAsn;
  HostResolver get _resolveHost => _hostOverride ?? InternetAddress.lookup;
  NtpExchange get _exchange => _exchangeOverride ?? defaultNtpExchange;

  /// Shared sentinel group id used whenever the host's ASN cannot be
  /// determined — a DNS or ASN-table miss, or a resolution failure.
  ///
  /// [MarzulloEngine] counts distinct `groupId`s purely to grade
  /// confidence, so a per-host fallback would let two servers in the same
  /// unknown ASN look like two providers, inflating the diversity count
  /// and over-grading confidence. Collapsing every un-attributable sample
  /// into this one group keeps confidence honest (or conservative), never
  /// inflated, while the sample still counts toward quorum and the
  /// published time. See ADR 0007.
  static const String groupIdUnknown = 'asn-unknown';

  @override
  String get id => '${TimeSource.prefixNtp}$_host';

  /// Synchronous group fallback. The authoritative group is the
  /// ASN-derived id resolved per query (see [resolveGroupId]); absent a
  /// resolved IP this reports the shared [groupIdUnknown] sentinel rather
  /// than guessing a group from the hostname.
  @override
  String get groupId => groupIdUnknown;

  /// Best-effort ASN-based group ID (`as<asn>`) derived from the host's
  /// resolved IP, falling back to the shared [groupIdUnknown] sentinel on
  /// any DNS/ASN miss or failure. See ADR 0007.
  @visibleForTesting
  Future<String> resolveGroupId() async => _groupIdFor(await _resolveFirst());

  /// Resolves [_host] to a single deterministic address, or `null` when DNS
  /// yields nothing, times out, or throws. DNS can return multiple A/AAAA
  /// records in a platform- and run-dependent order, so we pick
  /// deterministically — IPv4 first, then the lowest address literal — to
  /// keep the derived ASN/groupId stable across runs for multi-record hosts.
  /// Centralised so [getTime] pins the same address for both the ASN lookup
  /// and the NTP exchange.
  Future<InternetAddress?> _resolveFirst() async {
    try {
      final addrs = await _lookupAddresses();
      return addrs.isEmpty ? null : addrs.reduce(_preferred);
    } on DnsBudgetSaturation {
      // ADR 0008 answer 5: a lookup that cannot even acquire a DNS slot
      // within the unified budget is dropped from this cycle exactly like
      // a maxLatency timeout. Propagate so SyncEngine's per-source
      // failure path arms the standard exponential cooldown, rather than
      // silently falling back to the bare host as for an ordinary miss.
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Resolves [_host], routed through the shared [DnsBudget] when one is
  /// configured. The budget consults its cache first (a hit never
  /// consumes a slot) and otherwise admits the lookup under the unified
  /// concurrency cap, throwing [DnsBudgetSaturation] when no slot frees
  /// up in time. Without a budget the lookup runs directly, preserving
  /// the behaviour of direct (non-engine) callers and tests.
  Future<List<InternetAddress>> _lookupAddresses() {
    final budget = _dnsBudget;
    // Cap the resolver timeout at the budget's admission window when one
    // is present (ADR 0008): SyncEngine sets acquireTimeout == maxLatency,
    // so the lookup must release its permit within the same window the
    // engine is willing to wait. Without the clamp a maxLatency below 2s
    // lets a stalled lookup keep holding a permit after the engine has
    // already dropped the source, starving its peers.
    final lookupTimeout = budget == null
        ? const Duration(seconds: 2)
        : _minDuration(const Duration(seconds: 2), budget.acquireTimeout);
    Future<List<InternetAddress>> lookup() =>
        _resolveHost(_host).timeout(lookupTimeout);
    return budget == null ? lookup() : budget.guard(_host, lookup);
  }

  /// Deterministic tiebreak between two resolved addresses: prefer IPv4,
  /// then the lexicographically lowest address literal.
  static InternetAddress _preferred(InternetAddress a, InternetAddress b) {
    final aV4 = a.type == InternetAddressType.IPv4;
    final bV4 = b.type == InternetAddressType.IPv4;
    if (aV4 != bV4) return aV4 ? a : b;
    return a.address.compareTo(b.address) <= 0 ? a : b;
  }

  static Duration _minDuration(Duration a, Duration b) => a <= b ? a : b;

  /// Maps an already-resolved [addr] to its ASN group (`as<asn>`), falling
  /// back to the shared [groupIdUnknown] sentinel on a null address, an
  /// ASN miss, or a lookup failure.
  Future<String> _groupIdFor(InternetAddress? addr) async {
    if (addr == null) return groupIdUnknown;
    try {
      final asn = await _asn.lookup(addr);
      return asn == null ? groupIdUnknown : 'as$asn';
    } catch (_) {
      return groupIdUnknown;
    }
  }

  @override
  Future<TimeSample> getTime() async {
    // The whole call — host resolution *and* the query burst — shares
    // one [_timeout] wall-clock budget, measured on the resolved
    // monotonic reader (sleep-aware when the nts bridge is
    // initialized). Starting the clock before resolution keeps the
    // inner budget aligned with SyncEngine's outer
    // `.timeout(_config.maxLatency)` wrapper: a slow DNS lookup eats
    // into the burst's balance instead of letting the outer timeout
    // pre-empt an in-flight exchange (which would discard the
    // underlying protocol error and leave the UDP wait running past
    // the engine's window).
    final clock = resolveMonotonicReader();
    final startMicros = clock.read();

    // Resolve the host once so the ASN-derived groupId and every
    // exchange in the burst describe the *same* server. Round-robin
    // pools (e.g. pool.ntp.org) can hand back a different IP across
    // two separate lookups, so we resolve once and pass the chosen
    // literal IP to every attempt — mixing servers inside a burst
    // would defeat the lowest-δ selection (each server has its own
    // clock and path). On a resolve miss we fall back to the bare
    // host so time success never depends on ASN resolution
    // succeeding. See ADR 0007.
    final addr = await _resolveFirst();
    final address = addr?.address ?? _host;

    // Run the burst sequentially — serial by design, mirroring
    // [NtsSource.getTime]. Concurrent samples fired at one server
    // travel the same path as a dense cluster and share any transient
    // queue spike, defeating the lowest-delay selection; sequential
    // queries let the local interface queue drain between samples so
    // each observes an independent snapshot of the path.
    //
    // The budget acts as a shrinking deadline: every attempt
    // (including the first, whose balance is the configured budget
    // minus whatever resolution consumed) receives the remaining
    // balance as its exchange timeout, and once the balance dips
    // below the floor the remaining attempts are skipped — the burst
    // degrades to fewer samples rather than overrunning the window a
    // single query would have had. A budget exhausted before the
    // first attempt throws [TimeoutException], so an all-fail burst
    // always carries a concrete underlying error. Every attempt
    // guards its own failure; the burst as a whole succeeds when at
    // least one attempt lands. Sequential execution appends successes
    // in attempt-index order, so the lowest-δ pick's "first wins"
    // tie-break stays deterministic.
    var attempts = 0;
    Object? lastError;
    StackTrace? lastStackTrace;

    const floor = Duration(milliseconds: 1);
    final successes = <_BurstSuccess>[];
    for (var attempt = 0; attempt < _burstCount; attempt++) {
      final remaining =
          _timeout - Duration(microseconds: clock.read() - startMicros);
      if (remaining < floor) {
        if (attempt == 0) {
          throw TimeoutException(
            'NTP burst budget exhausted by host resolution',
            _timeout,
          );
        }
        break;
      }
      attempts++;
      try {
        final result = await _exchange(address, timeout: remaining);
        // Capture the receipt instant here — at each attempt's own
        // completion — so per-attempt receivedAtMs stays accurate for
        // the engine's receipt normalization. Stamped on the
        // monotonic receipt timeline so a wall-clock step mid-burst
        // cannot corrupt the deltas normalization consumes.
        successes.add(
          _BurstSuccess(
            raw: result,
            receivedAtMs: TimeSample.monotonicReceiptNowMs(),
          ),
        );
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
      }
    }

    if (TrustedTimeLog.enabled) {
      final delays = successes
          .map((s) => (s.raw.delayMicros / 1000).toStringAsFixed(1))
          .join(', ');
      TrustedTimeLog.log(
        TrustedTimeLogLevel.debug,
        '[TrustedTime] ntp:$_host burst '
        '${successes.length}/$attempts succeeded delays=[$delays]ms',
      );
    }

    if (successes.isEmpty) {
      // Every dispatched attempt failed (budget-skipped attempts do
      // not count); surface the last concrete failure so SyncEngine's
      // standard per-source cooldown path arms.
      Error.throwWithStackTrace(lastError!, lastStackTrace!);
    }

    // Reduce the burst to the single lowest-network-delay sample —
    // the tightest, least path-asymmetric estimate (the
    // burst-and-pick-min strategy the NTS path uses). Ties keep the
    // earliest attempt.
    var winner = successes.first;
    var minDelayMicros = winner.raw.delayMicros;
    var maxDelayMicros = winner.raw.delayMicros;
    for (final s in successes.skip(1)) {
      final d = s.raw.delayMicros;
      if (d < minDelayMicros) {
        minDelayMicros = d;
        winner = s;
      }
      if (d > maxDelayMicros) maxDelayMicros = d;
    }
    _onStratumObserved?.call(winner.raw.stratum);

    // In-cycle burst jitter: the spread (max − min) of the
    // per-attempt network delays δ — the same key the reduction above
    // selects on. Each bound is truncated to ms *before* subtracting,
    // matching [TimeSample.delayMs]'s own µs→ms truncation, so the
    // reported jitter always equals the spread of the per-attempt
    // delayMs values. A spread needs at least two observations;
    // single-success bursts leave jitter null rather than reporting a
    // misleading 0.
    final jitterMs = successes.length < 2
        ? null
        : (maxDelayMicros ~/ 1000) - (minDelayMicros ~/ 1000);

    // Derive the group only *after* the timed exchanges. The first
    // ASN lookup synchronously gunzips and parses the bundled table
    // on this isolate; running it during a UDP round-trip could block
    // the event loop and skew the measured delay/offset. groupId
    // feeds only confidence grading, so keeping it off the timing
    // path is free.
    final group = await _groupIdFor(addr);

    return _toTimeSample(winner.raw, winner.receivedAtMs, group, jitterMs);
  }

  /// Converts one successful exchange into the [TimeSample] shape the
  /// engine consumes, stamped with that attempt's own receipt instant.
  ///
  /// Mirrors the NTS clock-filter shape: the midpoint is the local
  /// receipt wall reading corrected by θ (the server's clock at the
  /// instant the reply arrived), and the half-width is the root
  /// distance `Λ = δ/2 + rootDelay/2 + rootDispersion` — a provably
  /// correct bound that excludes server processing time, so it is
  /// materially tighter than the RTT/2 worst case against distant
  /// servers with fast processing. δ/2, rootDelay/2 and the ms
  /// conversions all round *up* so no division ever shrinks the
  /// budget — Λ is a bound, so conversion error must widen it, not
  /// shrink it.
  TimeSample _toTimeSample(
    NtpExchangeResult result,
    int receivedAtMs,
    String group,
    int? jitterMs,
  ) {
    final timestampMs =
        (result.destinationUtcMicros + result.offsetMicros) ~/ 1000;
    final delayMs = result.delayMicros ~/ 1000;
    final errorBudgetMicros =
        (result.rootDelayMicros + 1) ~/ 2 + result.rootDispersionMicros;
    final dispersionMs = (errorBudgetMicros + 999) ~/ 1000;
    final halfDelayMs = (result.delayMicros + 1999) ~/ 2000;
    final uncertaintyMs = halfDelayMs + dispersionMs;

    return TimeSample(
      interval: TimeInterval(
        startMs: timestampMs - uncertaintyMs,
        endMs: timestampMs + uncertaintyMs,
      ),
      sourceId: id,
      groupId: group,
      // Network delay δ (RTT minus server processing), kept separate
      // from the interval half-width so root distance (Λ = E + δ/2)
      // is computable and burst reduction keys on network delay.
      delayMs: delayMs,
      dispersionMs: dispersionMs,
      // Monotonic receipt instant so the engine can normalize samples
      // received at different points in the cycle before Marzullo
      // intersection.
      receivedAtMs: receivedAtMs,
      // Per-burst telemetry for contributor records: the winning
      // exchange's server stratum and the burst's delay spread.
      stratum: result.stratum,
      jitterMs: jitterMs,
    );
  }
}

/// One successful burst attempt: the raw exchange result paired with
/// the monotonic receipt stamp captured at that attempt's completion.
final class _BurstSuccess {
  const _BurstSuccess({required this.raw, required this.receivedAtMs});

  final NtpExchangeResult raw;
  final int receivedAtMs;
}
