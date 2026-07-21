import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'domain/marzullo_engine.dart';
import 'domain/time_sample.dart';
import 'domain/time_source.dart';
import 'domain/time_interval.dart';
import 'exceptions.dart'
    show
        TransientSourceError,
        TrustedTimeFreshnessProbeException,
        TrustedTimeSyncException;
import 'integrity_event.dart';
import 'models.dart';
import 'monotonic_clock.dart';
import 'source_quality_tracker.dart';
import 'sources/nts_auth_level.dart';
import 'sources/time_sources.dart';
import 'infra/dns_budget.dart';
import 'infra/sync_observer.dart';
import 'infra/consensus_cache.dart';
import 'infra/trusted_time_log.dart';

/// ## Absolute Top Tier: Distributed Lifecycle Orchestration
///
/// The [SyncEngine] is the heart of the time integrity subsystem. It implements
/// a self-healing operational state machine designed for adversarial robustness.
///
/// Key Refinements:
/// 1. **Racing Parallelism**: Minimizes cold-start latency through concurrent
///    multi-source querying.
/// 2. **Adaptive Stability Escalation**: Dynamically adjusts quorum requirements
///    based on population variance.
/// 3. **Mathematical Outlier Filtering**: Uses median-based guards to neutralize
///    malicious or jittery time authorities.
final class SyncEngine {
  /// Upper bound on any await of [Warmable.warm] inside this engine.
  ///
  /// warm() futures are memoized and not cancellable, so a timed-out
  /// await abandons the wait without aborting the handshake — the same
  /// future is re-joined by getTime()'s JIT warm, where the per-query
  /// maxLatency bound applies. Used by [sync]'s global warming barrier
  /// and [validate]'s Phase A, so a hung handshake can never stall a
  /// cycle (or a headless OS budget) beyond this cap.
  @visibleForTesting
  static const warmBarrierCap = Duration(seconds: 10);

  /// Documented.
  SyncEngine({
    required TrustedTimeConfig config,
    required MonotonicClock clock,
    SyncObserver? observer,
    ConsensusCache? cache,
    SourceQualityTracker? qualityTracker,
    void Function(IntegrityEvent event)? onIntegrityEvent,
  }) : _config = config,
       _clock = clock,
       _observer = observer,
       _onIntegrityEvent = onIntegrityEvent,
       _cache = cache,
       _qualityTracker = qualityTracker ?? SourceQualityTracker(),
       _engine = MarzulloEngine(
         minQuorumRatio: config.minQuorumRatio,
         maxAllowedUncertaintyMs: config.maxAllowedUncertaintyMs,
         minGroupCount: config.minGroupCount,
       );

  final TrustedTimeConfig _config;
  final MonotonicClock _clock;
  final SyncObserver? _observer;

  /// Sink for engine-originated integrity events (currently
  /// [TamperReason.degradedTier]). `TrustedTimeImpl` wires this to
  /// `IntegrityMonitor.report` so the event reaches the public
  /// `onIntegrityLost` stream; tests may pass a recorder directly.
  final void Function(IntegrityEvent event)? _onIntegrityEvent;
  final ConsensusCache? _cache;
  final MarzulloEngine _engine;

  /// Shared DNS concurrency budget (ADR 0008).
  ///
  /// One budget governs all uncached host resolutions the engine can see
  /// in-process: it is handed to every [NtpSource] and [HttpsSource]
  /// (the latter pre-resolves its host through it to warm the platform
  /// cache, ADR 0008) and its value is forwarded as each [NtsSource]'s
  /// `dnsConcurrencyCap`. Built lazily
  /// from [TrustedTimeConfig.effectiveMaxConcurrentDnsLookups] so the
  /// migration ladder (and its one-time deprecation warning) runs exactly
  /// once, the first time the source list is materialised.
  late final DnsBudget _dnsBudget = _buildDnsBudget();

  /// Process-wide guard so the [ntsDnsConcurrencyCap] deprecation notice
  /// is emitted at most once regardless of how many engines are built.
  static bool _deprecationWarned = false;

  /// Lazily-initialized list of authoritative time sources.
  ///
  /// DNS concurrency is governed by the shared [_dnsBudget] (ADR 0008):
  /// NTP and HTTPS sources resolve through it cache-first (HTTPS via a
  /// pre-resolve step that warms the platform cache), and its value is
  /// forwarded as each NTS source's `dnsConcurrencyCap` so all source
  /// kinds draw on one unified cold-start budget rather than the former
  /// NTS-only `ntsServers.length + 2` auto-size.
  late final List<TimeSource> _sources = _buildSources();

  /// Resolves the unified DNS budget and emits the one-time
  /// [ntsDnsConcurrencyCap] deprecation warning when the legacy NTS-only
  /// knob is what supplies the value (ADR 0008 migration).
  DnsBudget _buildDnsBudget() {
    final cap = _config.effectiveMaxConcurrentDnsLookups;
    // ignore: deprecated_member_use_from_same_package
    final legacyCap = _config.ntsDnsConcurrencyCap;
    if (_config.maxConcurrentDnsLookups == null &&
        legacyCap != null &&
        !_deprecationWarned) {
      _deprecationWarned = true;
      TrustedTimeLog.log(
        TrustedTimeLogLevel.warning,
        '[TrustedTime] TrustedTimeConfig.ntsDnsConcurrencyCap is '
        'deprecated; use maxConcurrentDnsLookups. Honouring the legacy '
        'value ($cap) as the unified DNS budget. See ADR 0008.',
      );
    }
    return DnsBudget(cap, acquireTimeout: _config.maxLatency);
  }

  /// Builds the authoritative source list for this engine.
  ///
  /// [TrustedTimeConfig.effectiveTrustMode] is resolved once up front —
  /// before any source is constructed — so an invalid trust
  /// configuration (`usePlatformTrust: true` together with a non-empty
  /// `customRootCerts`) fails closed with [ArgumentError] regardless of
  /// whether any NTS servers are configured. Resolving it inside the
  /// `ntsServers` comprehension would skip the check whenever that list
  /// is empty, letting an invalid config build NTP/HTTPS/additional
  /// sources and silently bypass the "fail closed" guarantee. The
  /// resolved mode is then reused for every [NtsSource].
  List<TimeSource> _buildSources() {
    final trustMode = _config.effectiveTrustMode;
    // Reuse the already-constructed budget's cap rather than re-reading
    // effectiveMaxConcurrentDnsLookups: the migration ladder (and its
    // one-time deprecation warning) then runs exactly once, in
    // _buildDnsBudget, and the NTS forwarding cap can never drift from
    // the budget actually handed to the NTP sources. See ADR 0008.
    final dnsCap = _dnsBudget.maxConcurrent;
    return [
      for (final host in _config.ntpServers)
        NtpSource(host, dnsBudget: _dnsBudget),
      for (final url in _config.httpsSources)
        HttpsSource(url, dnsBudget: _dnsBudget),
      for (final host in _config.ntsServers)
        NtsSource(
          host,
          port: _config.ntsPort,
          dnsConcurrencyCap: dnsCap,
          maxLatency: _config.maxLatency,
          trustMode: trustMode,
          customRoots: _config.customRootCerts.isEmpty
              ? null
              : _config.customRootCerts,
          onStratumObserved: (s) =>
              _qualityTracker.setStratum('${TimeSource.prefixNts}$host', s),
          burstCount: _config.ntsBurstCount,
        ),
      ..._config.additionalSources,
    ];
  }

  /// Tracks consecutive failures for each source to implement exponential cooldown.
  final _sourceHealth = <String, int>{};

  /// Precise timestamps until which a source is considered "blacklisted."
  final _blacklistUntil = <String, DateTime>{};

  /// Counts consecutive [TransientSourceError] failures from a single
  /// source so a sustained "transient" condition (e.g. permanent DNS
  /// pool saturation) eventually escalates to the regular cooldown
  /// ladder rather than retrying every cycle indefinitely. Reset on a
  /// successful query, on a regular (non-transient) failure, and on
  /// each escalation. The escalation threshold is
  /// [TrustedTimeConfig.transientStreakThreshold].
  final _sourceTransientStreak = <String, int>{};

  /// Per-source quality tracker introduced by upstream 2.1.0. Ranks
  /// healthy sources by a weighted score (RTT/uncertainty 40% +
  /// consensus participation 40% + NTP stratum 20%) so high-quality
  /// sources are queried first. Paired with a starvation rescue in
  /// [sync] that force-includes a source the cooldown filter excluded
  /// once it has gone unqueried for 5 consecutive successful cycles.
  /// Composes with our outer-fast-path source filtering: the fast-path
  /// still bails the cycle when `_sources` is empty or every cooled-down
  /// source is also not yet starved; ranking re-orders what survives the
  /// cooldown filter, and the rescue re-admits a long-ignored cooled
  /// source so it cannot be starved indefinitely.
  ///
  /// Constructor-injectable so tests can observe the recorded
  /// observations; defaults to a fresh instance in production.
  final SourceQualityTracker _qualityTracker;

  int _syncAttempts = 0;

  /// Eagerly invokes [Warmable.warm] on every source that supports it,
  /// in parallel.
  ///
  /// Called during application bootstrap so per-source setup costs
  /// (e.g., the NTS-KE TCP+TLS+key-exchange handshake) complete before
  /// the first [sync] cycle, and again by [sync] itself as the global
  /// warming barrier so every cycle's queries — foreground or
  /// background — launch against fully-warmed state with converged
  /// start times. Without this, those costs fall inside the cycle's
  /// wall clock and contaminate sample timestamps with hundreds of
  /// milliseconds of skew, preventing Marzullo intervals from
  /// overlapping.
  ///
  /// Each [Warmable.warm] is itself idempotent and memoized, so calling
  /// this method multiple times is safe and cheap. Failures from
  /// individual sources are swallowed: warming is best-effort, and
  /// [sync] retains its existing JIT-warm fallback path.
  Future<void> warmAllSources() async {
    final warmables = _sources.whereType<Warmable>().toList(growable: false);
    if (warmables.isEmpty) return;
    await Future.wait(
      warmables.map((s) async {
        try {
          await s.warm();
        } catch (_) {
          // Same semantics as the warm-phase failure handling in
          // sync(): swallow so a single misbehaving source cannot
          // block bootstrap.
        }
      }),
    );
  }

  /// Performs a single-source freshness probe for the validate tier
  /// (ADR 0006) and returns the resulting [TimeSample].
  ///
  /// Unlike [sync], this runs no Marzullo consensus and builds no truth
  /// box: it bursts a short series of authenticated NTS queries against
  /// the highest-quality healthy NTS source and returns the single
  /// sample with the smallest round-trip delay. The burst size is
  /// [TrustedTimeConfig.validateBurstCount]; each query past the first
  /// spends one in-band-refilled cookie (a single UDP round-trip, no
  /// new NTS-KE handshake), and the lowest-RTT sample is the tightest,
  /// least path-asymmetric estimate (the burst-and-pick-min strategy
  /// package:nts documents). The caller
  /// (`TrustedTimeImpl.validateFreshness`) compares that sample against
  /// the live anchor to decide whether the anchor is still fresh.
  ///
  /// Source selection mirrors [sync]'s cooldown + quality-ranking
  /// composition, restricted to NTS sources — those whose id carries
  /// the [TimeSource.prefixNts] prefix, so fakes injected via
  /// [TrustedTimeConfig.additionalSources] remain eligible in tests.
  /// The probe is read-only with respect to cooldown and quality state:
  /// a single lightweight freshness check must not blacklist an
  /// establish-pool source or perturb its ranking.
  ///
  /// Throws [TrustedTimeFreshnessProbeException] when no NTS source is
  /// configured, every NTS source is in cooldown, or every query in the
  /// burst fails or times out.
  Future<TimeSample> validate() async {
    final now = DateTime.now();
    final ntsSources = _sources
        .where((s) => s.id.startsWith(TimeSource.prefixNts))
        .toList(growable: false);
    if (ntsSources.isEmpty) {
      throw const TrustedTimeFreshnessProbeException(
        'The validate tier requires an NTS source, but none is '
        'configured (ntsServers is empty and no nts: additionalSources '
        'were supplied). Configure NTS to use validateFreshness().',
      );
    }

    final healthy = ntsSources
        .where((s) {
          final until = _blacklistUntil[s.id];
          return until == null || now.isAfter(until);
        })
        .toList(growable: false);
    if (healthy.isEmpty) {
      throw const TrustedTimeFreshnessProbeException(
        'All configured NTS sources are currently in exponential '
        'cooldown due to persistent failures; cannot run a freshness '
        'probe this cycle.',
      );
    }

    // Reuse sync()'s quality ordering (read-only): index the healthy
    // pool by id, rank the ids, and pick the top survivor. putIfAbsent
    // keeps the first-seen source for a colliding id, matching
    // ranked()'s first-seen dedup.
    final healthyById = <String, TimeSource>{};
    for (final s in healthy) {
      healthyById.putIfAbsent(s.id, () => s);
    }
    final rankedIds = _qualityTracker.ranked(healthy.map((s) => s.id));
    final source = rankedIds.isNotEmpty
        ? (healthyById[rankedIds.first] ?? healthy.first)
        : healthy.first;

    // Phase A (warm) runs outside the query budget, exactly as in
    // sync(); a warm failure is non-fatal and the cold getTime() still
    // runs under the maxLatency budget in Phase B. Unlike sync(), no
    // outer safety timeout wraps this method, so the warm await must
    // carry its own bound — without it, a hung handshake would stall
    // validateFreshness() indefinitely. The cap matches sync()'s
    // warming-barrier cap; on timeout the probe proceeds and Phase B's
    // per-query maxLatency bound covers the still-cold source (getTime's
    // JIT warm await re-joins the same memoized warm future inside that
    // budget).
    if (source is Warmable) {
      try {
        await Future.sync(
          () => (source as Warmable).warm(),
        ).timeout(warmBarrierCap);
      } catch (e) {
        // Best-effort, mirroring sync()'s warm-phase handling: surface
        // the failure to the observer so a Warmable that violates the
        // "must not throw" contract is diagnosable, then proceed to the
        // cold getTime() burst regardless.
        _observer?.onSourceFailed(source.id, 'warm: $e');
      }
    }

    // Phase B (burst): query the selected source up to
    // [TrustedTimeConfig.validateBurstCount] times and keep the
    // lowest-RTT sample. After warming, each query spends one
    // in-band-refilled cookie — a single UDP round-trip, no new NTS-KE
    // handshake — so the marginal cost of extra samples is small, and
    // the minimum measured delay is the tightest, least path-asymmetric
    // estimate (the burst-and-pick-min strategy package:nts documents).
    // Queries run sequentially so each cookie is refilled before the
    // next is spent. Individual failures are tolerated: a probe surfaces
    // as failed only when every attempt in the burst fails.
    final burst = _config.validateBurstCount < 1
        ? 1
        : _config.validateBurstCount;
    TimeSample? best;
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < burst; attempt++) {
      try {
        final sample = await source.getTime().timeout(_config.maxLatency);
        if (best == null || _rttKey(sample) < _rttKey(best)) {
          best = sample;
        }
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
        // Mirror sync()'s _querySafe and hand the observer the raw error
        // object (not a pre-stringified message) so consumers can inspect
        // the error type — e.g. TimeoutException vs other failures.
        _observer?.onSourceFailed(source.id, e);
      }
    }
    if (best != null) return best;
    // Every attempt in the burst failed. Wrap the outcome as "freshness
    // unknown", but preserve the originating stack trace so callers
    // retain debugging context for the underlying error.
    final probeFailure = TrustedTimeFreshnessProbeException(
      'Freshness probe against ${source.id} failed across all $burst '
      'attempt(s): $lastError',
    );
    if (lastStackTrace != null) {
      Error.throwWithStackTrace(probeFailure, lastStackTrace);
    }
    throw probeFailure;
  }

  /// Lowest-RTT sort key for the [validate] burst, in milliseconds of
  /// round-trip delay. Prefers the whole measured RTT [TimeSample.delayMs]
  /// (δ) and falls back to `2 * `[TimeSample.uncertaintyMs] when a source
  /// did not time the round trip — the interval half-width is ≈ δ/2, so
  /// doubling it keeps the key in RTT units and avoids mixing δ with δ/2
  /// across samples. All samples in a burst come from one source, so the
  /// key is internally consistent even when δ is unmeasured.
  static int _rttKey(TimeSample sample) =>
      sample.delayMs ?? (2 * sample.uncertaintyMs);

  /// Executes a full synchronization cycle across all healthy sources.
  ///
  /// This method is the primary driver of trust establishment. It races sources,
  /// performs adaptive outlier filtering, and requires stability across
  /// multiple samples before finalizing an anchor.
  Future<TrustAnchor> sync() async {
    // Per-cycle synchronous re-entry guard for [_completeSync].
    // Allocated fresh on every [sync] call and captured by the sample
    // listener closure, so the guard's lifetime is exactly one sync
    // cycle. This is the deliberate alternative to an engine-instance
    // flag with a top-of-`sync()` reset: a per-cycle holder is robust
    // against overlapping `sync()` invocations (which would otherwise
    // race on the engine-scoped reset).
    //
    // [SyncEngine] itself does not gate against concurrent `sync()`
    // entries — that responsibility lives in the public-API wrapper
    // (`TrustedTimeImpl._performSync` in `lib/src/trusted_time_impl.dart`,
    // which uses a `_syncInProgress` Completer to coalesce concurrent
    // callers into a single in-flight cycle). That guard is currently
    // imperfect under tight retry/timer scheduling (tracked as
    // `trusted_time-exw`), but even if two `sync()` invocations slip
    // past it, each cycle's `_completeSync` pair operates on its own
    // [_CompletionGuard] and cannot reset the other's in-flight state.
    final completionGuard = _CompletionGuard();
    _observer?.onSyncStarted();
    final swSync = Stopwatch()..start();

    // Empty-pool fast path: bail out *before* allocating the
    // StreamController. A single-subscription StreamController whose
    // listener is never attached has a `close()` future that does not
    // complete on the test event loop, so awaiting it from the finally
    // block of the try/catch below would hang the whole sync cycle
    // (and the bootstrap that waits on it). Surfacing the failure
    // through the observer here keeps the no-op cycle's telemetry
    // shape identical to a populated cycle that produced zero
    // eligible samples.
    //
    // Source ordering composes cooldown filtering (this code path)
    // with upstream 2.1.0's quality-ranked + starvation-guarded
    // composition from `_qualityTracker`: the cooldown filter
    // determines which sources are even eligible this cycle, then
    // the quality tracker re-orders the survivors so high-quality
    // sources are queried first (for early-exit latency). A
    // starvation rescue then re-admits any source the cooldown filter
    // excluded that has gone unqueried for too long, so a source stuck
    // in exponential cooldown cannot be permanently ignored. Empty-pool
    // detection stays here so the actionable error distinguishing "no
    // sources configured" from "all in cooldown" is preserved — it now
    // fires only when no cooled-down source is yet due for rescue.
    final now = DateTime.now();
    final healthySources = _sources.where((s) {
      final until = _blacklistUntil[s.id];
      return until == null || now.isAfter(until);
    }).toList();
    // Index healthy sources by id so the ranked-order construction below
    // is O(n) (one map lookup per id) instead of O(n^2) (a firstWhere
    // scan per id). Doubles as the O(1) membership test for the
    // starvation rescue pass.
    //
    // putIfAbsent keeps the first-seen source for a colliding id, which
    // must agree with ranked()'s toSet() dedup (also first-seen): the
    // ranked slot for a duplicated id and the source actually queried for
    // it have to resolve to the same instance. A map literal would instead
    // keep the last-seen source, making that choice depend on _sources
    // construction order.
    final healthyById = <String, TimeSource>{};
    for (final s in healthySources) {
      healthyById.putIfAbsent(s.id, () => s);
    }
    final rankedIds = _qualityTracker.ranked(healthySources.map((s) => s.id));
    final activeSources = <TimeSource>[
      // High-quality sources first, in ranked order.
      for (final id in rankedIds) healthyById[id]!,
      // Starvation rescue: a source the cooldown filter excluded that has
      // gone unqueried for _kStarvationCycles successful cycles is
      // force-included for a single query, so a source stuck in
      // exponential cooldown cannot be permanently ignored and its
      // quality estimate stays fresh. Iterating _sources (rather than
      // healthySources, which are all already in rankedIds) is what makes
      // this branch reachable; the healthyById membership check prevents
      // double-inclusion.
      for (final s in _sources)
        if (!healthyById.containsKey(s.id) && _qualityTracker.isStarved(s.id))
          s,
    ];
    if (activeSources.isEmpty) {
      // Distinguish "no sources configured" from "all sources in
      // cooldown" so the surfaced error is actionable. Both collapse
      // to the same fast-path here, but the operator's next step is
      // very different — adding sources vs. waiting for the
      // exponential cooldown to expire.
      final emptyError = _sources.isEmpty
          // An empty source configuration fails identically on every
          // attempt — non-transient, so retry schedulers give up rather
          // than loop the same failure forever. Cooldown, by contrast,
          // expires with time, so a retry can plausibly recover.
          ? const TrustedTimeSyncException(
              'No time sources are configured: ntpServers, httpsSources, '
              'ntsServers, and additionalSources are all empty.',
              transient: false,
            )
          : const TrustedTimeSyncException(
              'All configured time sources are currently in exponential '
              'cooldown due to persistent failures.',
            );
      _markSyncFailed(emptyError);
      throw emptyError;
    }

    final samples = <TimeSample>[];
    final completer = Completer<TrustAnchor>();
    var streamClosed = false;
    StreamSubscription<TimeSample?>? streamSub;
    final sampleController = StreamController<TimeSample?>();

    try {
      var pendingQueries = activeSources.length;

      TimeInterval? lastStabilityInterval;
      var stableCount = 0;
      var rejectedInvalid = 0;

      // 1. Process samples sequentially via a stream to preserve determinism
      // and prevent race conditions during list mutation. This ensures that
      // outlier filtering and consensus resolution always happen on a consistent
      // snapshot of the sample population.
      streamSub = sampleController.stream.listen((sample) {
        if (completer.isCompleted) return;

        if (sample != null) {
          // Filter samples with negative uncertainty early, before both Marzullo
          // and the anchor reduce. Negative uncertainty indicates clock errors.
          if (sample.uncertaintyMs < 0) {
            rejectedInvalid++;
            _observer?.onSourceFailed(
              sample.sourceId,
              'Sample rejected: negative uncertainty (RTT)',
            );
            pendingQueries--;
            if (pendingQueries == 0 && !completer.isCompleted) {
              _finalizeSync(
                samples,
                rejectedInvalid,
                activeSources.length,
                completer,
                completionGuard,
              );
            }
            return;
          }

          samples.add(sample);
          _observer?.onSampleReceived(sample);

          // Adaptive Outlier Filtering: Uses a median-based guard to identify
          // and exclude sources that deviate significantly from the population.
          if (samples.length >= 3) {
            final uncertainties = samples.map((s) => s.uncertaintyMs).toList()
              ..sort();
            final medianU = uncertainties[uncertainties.length ~/ 2];

            // Heuristic: If a sample's uncertainty is > 3x the median, it is
            // likely malicious or experiencing extreme network jitter.
            if (sample.uncertaintyMs > max(medianU * 3, 500)) {
              samples.remove(sample);
              _observer?.onSourceFailed(
                sample.sourceId,
                'Adaptive exclusion: statistical outlier detected',
              );
            }
          }

          final (normalized, refMs) = _normalizedToLatestReceipt(samples);
          final result = _engine.resolve(normalized);
          if (result != null) {
            // Stability Check: Escalates quorum requirements if high variance
            // is detected, ensuring we don't anchor to a jittery consensus.
            final varianceDetected = normalized.any(
              (s) =>
                  (s.interval.midpoint - result.utc.millisecondsSinceEpoch)
                      .abs() >
                  500,
            );
            final requiredStability = varianceDetected ? 3 : 2;

            // Compare intervals relative to the normalization reference:
            // the reference advances as later samples arrive, so the
            // absolute consensus interval shifts by the receipt delta
            // between resolves even when the consensus itself is stable.
            final absoluteInterval = result.interval;
            final relativeInterval = absoluteInterval == null
                ? null
                : TimeInterval(
                    startMs: absoluteInterval.startMs - refMs,
                    endMs: absoluteInterval.endMs - refMs,
                  );
            if (lastStabilityInterval == relativeInterval) {
              stableCount++;
            } else {
              stableCount = 1;
            }
            lastStabilityInterval = relativeInterval;

            if (stableCount >= requiredStability) {
              // Early Exit: If configured, we return as soon as a stable quorum
              // is reached to minimize power and network consumption.
              if (_config.earlyExit || samples.length == activeSources.length) {
                swSync.stop();
                unawaited(
                  _completeSync(
                    result,
                    List<TimeSample>.of(samples),
                    swSync.elapsedMilliseconds,
                    completer,
                    completionGuard,
                  ),
                );
              }
            }
          }
        }

        pendingQueries--;
        if (pendingQueries == 0 && !completer.isCompleted) {
          _finalizeSync(
            samples,
            rejectedInvalid,
            activeSources.length,
            completer,
            completionGuard,
            elapsedMs: swSync.elapsedMilliseconds,
          );
        }
      });

      // 2. Warming barrier: complete every Warmable's warm() before the
      // first timed query is issued, so all queries launch against
      // fully-warmed state (e.g. primed NTS cookie jars) with converged
      // start times. Without the barrier, each source queries the
      // moment its own handshake finishes, and the receipt spread
      // between the fastest and slowest handshake widens the
      // normalization shifts the consensus must absorb. The barrier is
      // a completion gate, not a fixed delay: when handshakes are fast
      // (or already memoized, as after initialize()'s explicit
      // warmAllSources()) it costs nothing. The warmBarrierCap only
      // bounds a pathological hang — warmAllSources() already swallows
      // per-source failures, so on timeout the cycle proceeds and the
      // per-source Phase A warm below covers any laggard.
      await warmAllSources().timeout(warmBarrierCap, onTimeout: () {});

      // 3. Launch racing queries.
      //
      // Each source runs a per-source two-phase sequence concurrently
      // with the others:
      //   Phase A — for sources that implement [Warmable], warm() runs
      //     outside the per-query maxLatency budget, so slow handshakes
      //     (e.g., NTS-KE) do not eat into the timed query window.
      //     After the barrier above, warm() is memoized and Phase A is
      //     a no-op for every source the barrier reached; it remains
      //     the JIT fallback for a source whose handshake outlived the
      //     barrier cap. Sources that don't implement Warmable skip
      //     Phase A and proceed straight to the query, so they are not
      //     blocked by slower siblings.
      //   Phase B — _querySafe() runs the timed getTime() under
      //     _config.maxLatency.
      // warm() is wrapped in Future.sync to capture both synchronous
      // and asynchronous throws so a misbehaving source cannot abort
      // its own query (we still proceed to _querySafe) nor the batch.
      for (final source in activeSources) {
        unawaited(() async {
          if (source is Warmable) {
            try {
              await Future.sync(() => (source as Warmable).warm());
            } catch (e) {
              _observer?.onSourceFailed(source.id, 'warm: $e');
            }
          }

          final sample = await _querySafe(source);
          if (!streamClosed && !sampleController.isClosed) {
            sampleController.add(sample);
          }
        }());
      }

      // Outer safety timeout. The warming barrier above completes (or
      // caps out) before this deadline starts counting, so the common
      // case consumes none of this budget on handshakes. The 5 s
      // handshake allowance is retained for the residual path where a
      // handshake outlived the barrier cap and Phase A re-awaits the
      // same memoized warm() inside this window. Budget = maxLatency
      // (timed query window) + 5s for that residual NTS-KE completion
      // + 1s for stream processing and consensus resolution overhead.
      final anchor = await completer.future.timeout(
        _config.maxLatency + const Duration(seconds: 6),
        onTimeout: () async {
          // Safety-net path: [completer] was not resolved within the
          // deadline. The per-cycle re-entry guard splits this into two
          // sub-cases that must be handled differently.
          //
          // (1) A sibling _completeSync is already in flight: an
          // early-exit or finalize invocation set guard.inFlight and is
          // awaiting _createAnchor. It owns this cycle's completion — it
          // will record the per-source quality observations and resolve
          // [completer] with the anchor momentarily. Defer to it by
          // returning [completer.future]. Calling _completeSync here
          // would no-op on the guard, and then throwing would discard an
          // anchor that resolves microtasks later (the functional
          // regression flagged in r3369282558). The only way the guard
          // is still in flight this far past the query window is a
          // stalled monotonic _createAnchor read, in which case no path
          // can produce an anchor anyway; we do not trade that reachable
          // discard-a-success regression for an unreachable hang.
          if (completionGuard.inFlight) {
            return completer.future;
          }
          // (2) No completion is in flight: the machinery never resolved
          // [completer], yet enough samples arrived to form a consensus.
          // Drive completion ourselves, routing through [_completeSync]
          // rather than building a raw anchor inline so this path
          // performs the same bookkeeping as the early-exit and finalize
          // paths:
          //  - per-source quality observations are recorded for the
          //    collected samples (flagged against the winning set), so
          //    the advanceCycle() below does not treat sources that
          //    answered this cycle as unqueried — which would otherwise
          //    skew the next cycle's ranking and starvation rescue; and
          //  - [completer] is resolved, so the sample-stream listener
          //    short-circuits instead of running on after sync() returns.
          if (!completer.isCompleted &&
              samples.length >= _config.minimumQuorum) {
            final (normalized, _) = _normalizedToLatestReceipt(samples);
            final result = _engine.resolve(normalized);
            if (result != null) {
              await _completeSync(
                result,
                List<TimeSample>.of(samples),
                swSync.elapsedMilliseconds,
                completer,
                completionGuard,
              );
              // _completeSync resolved [completer] with the anchor (or
              // errored it if _createAnchor threw); surface that same
              // outcome as the timeout result so the returned/raised
              // value and the bookkeeping match the non-timeout paths.
              if (completer.isCompleted) return completer.future;
            }
          }
          throw TrustedTimeSyncException(
            'Synchronization timed out before reaching a stable quorum.',
          );
        },
      );

      _syncAttempts = 0;
      _cache?.update(anchor);
      _qualityTracker.advanceCycle();
      return anchor;
    } catch (e) {
      _markSyncFailed(e);
      // The local `completer` has exactly one consumer: the
      // `completer.future.timeout(...)` await at the top of this
      // method. The rethrow below already propagates the error to
      // that awaiter (or to the catch site if the throw happened
      // before we reached the await). Calling completer.completeError
      // here would error a future whose only listener is the derived
      // timeout-wrapped future — which is already done by the time we
      // reach this catch in the timeout / quorum-failure paths —
      // resulting in an unhandled async error that flutter_test's
      // FakeAsync zone surfaces as a test failure. Leaving the
      // completer pending lets it be collected without leaking.
      rethrow;
    } finally {
      streamClosed = true;
      // Cancel subscription first to prevent hanging when controller closes
      await streamSub?.cancel();
      await sampleController.close();
    }
  }

  Future<void> _completeSync(
    ConsensusResult result,
    List<TimeSample> samples,
    int latencyMs,
    Completer<TrustAnchor> completer,
    _CompletionGuard guard,
  ) async {
    // Synchronous re-entry guard: if the completer is already done OR
    // a sibling _completeSync invocation in *this same cycle* has
    // already started its _createAnchor await, bail before doing any
    // observable work. Both checks must happen together with the
    // [guard] assignment, before the first await, so the second
    // caller observes the in-flight flag set by the first.
    //
    // [guard] is per-cycle (allocated in [sync] and captured by the
    // sample-stream listener), so this guard cannot be reset by an
    // overlapping `sync()` invocation on the same engine instance.
    if (completer.isCompleted || guard.inFlight) return;
    guard.inFlight = true;

    try {
      final anchor = await _createAnchor(result);
      // Defensive re-check after the await: no public path currently
      // completes [completer] while [_createAnchor] is in-flight (the
      // no-quorum branch of [_finalizeSync] is unreachable once
      // early-exit has fired, and the outer timeout wraps
      // [completer.future] rather than the completer itself), but a
      // future code change that introduces such a path would
      // otherwise cause `success` observer events to be emitted for
      // a cycle that ultimately failed. Bail before any observable
      // work if the completer has been resolved (or errored)
      // out-of-band.
      if (completer.isCompleted) return;
      // Winning-set ids, shared by the consensus attribution log below
      // and the per-source quality bookkeeping further down.
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
      if (TrustedTimeLog.enabled) {
        // Cross-source receipt spread at consensus time: how far apart
        // (on the monotonic receipt timeline) the population's samples
        // arrived, i.e. the exact shift _normalizedToLatestReceipt
        // absorbed for this resolve. `n/m` counts samples carrying a
        // receipt stamp out of the population.
        final receipts = samples
            .map((s) => s.receivedAtMs)
            .whereType<int>()
            .toList(growable: false);
        final spread = receipts.isEmpty
            ? 'n/a'
            : '${receipts.reduce(max) - receipts.reduce(min)}ms';
        // Attribution: which of the collected population the anchor is
        // actually standing on (won) versus which entered consensus but
        // were filtered by Marzullo / the tier truth box (rejected).
        // Both lists are sorted (and rejected de-duplicated) so the
        // structured line is stable for log parsers and tests.
        final truthBoxDropped = result.droppedOutsideTruthBox
            .map((s) => s.sourceId)
            .toSet();
        final won = participantIds.toList()..sort();
        final rejected = <String>{
          for (final s in samples)
            if (!participantIds.contains(s.sourceId))
              truthBoxDropped.contains(s.sourceId)
                  ? '${s.sourceId} (outside truth box)'
                  : '${s.sourceId} (outlier)',
        }.toList()..sort();
        TrustedTimeLog.log(
          TrustedTimeLogLevel.debug,
          '[TrustedTime] consensus won=[${won.join(', ')}] '
          'rejected=[${rejected.join(', ')}] '
          'receiptSpread=$spread '
          '(${receipts.length}/${samples.length} stamped) '
          'authLevel=${result.authLevel.name}',
        );
      }
      _observer?.onConsensusReached(result);

      // Tier-aware admission bookkeeping. A degraded cycle (no Tier 1 truth
      // box) raises a degradedTier integrity event so the public
      // onIntegrityLost stream learns the published anchor is best-effort
      // (authLevel: none); lower-tier samples dropped for falling outside
      // the truth box are surfaced as per-source failures for telemetry.
      if (result.degradedTier) {
        // Human-readable companion to the degradedTier integrity event:
        // without it, a cycle that minted an authLevel-none anchor looks
        // identical to a fully-verified success in the logs, and the
        // requireSecure failure only surfaces later where getTime()
        // throws — far from the cycle that caused it.
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] anchor DEGRADED: consensus reached without a '
          'verified-NTS quorum; authLevel=none. getTime() will throw '
          'under requireSecure until a verified anchor is minted.',
        );
        _onIntegrityEvent?.call(
          IntegrityEvent(
            reason: TamperReason.degradedTier,
            detectedAt: DateTime.now().toUtc(),
          ),
        );
      }
      for (final dropped in result.droppedOutsideTruthBox) {
        _observer?.onSourceFailed(dropped.sourceId, 'tier2: outside truth box');
      }

      // Record one quality observation per source that returned a sample
      // this cycle, flagging whether it landed in the consensus winning
      // set. Iterating the full collected `samples` population (not just
      // `result.participants`) is what lets the tracker tell a
      // consistently-rejected source apart from a consistently-agreeing
      // one; looping participants alone pins every participation rate at
      // 1.0 because every iterated sample is a participant by definition.
      final recorded = <String>{};
      for (final sample in samples) {
        if (!recorded.add(sample.sourceId)) continue;
        _qualityTracker.record(
          sourceId: sample.sourceId,
          uncertaintyMs: sample.uncertaintyMs,
          participatedInConsensus: participantIds.contains(sample.sourceId),
        );
      }

      _observer?.onMetricsReported(
        SyncMetrics(
          latencyMs: latencyMs,
          uncertaintyMs: result.uncertaintyMs,
          participantCount: result.participantCount,
          quorumDepth: result.quorumDepth,
          groupCount: result.groupCount,
          confidence: result.confidence,
          confidenceBreakdown: {
            // Both 'depth' and 'quorumDepth' are coarse "fraction of
            // the configured source pool that participated" ratios,
            // not the engine's actual quorum-floor comparison. The
            // engine's quorum check is `quorumDepth >= ceil(eligible *
            // minQuorumRatio)`, where `eligible` is the per-cycle
            // count of valid samples (which can be smaller than the
            // configured pool when sources are cooled down or fail to
            // produce a sample). Neither ratio surfaces `eligible`,
            // so they cannot reproduce the engine's quorum-floor
            // decision; consumers that need quorum-floor reasoning
            // should key off the raw integer SyncMetrics.quorumDepth
            // field instead.
            //
            // 'depth' preserves the historical participantCount-based
            // ratio for backward compatibility with existing
            // dashboards. 'quorumDepth' is the additive companion
            // showing the same coarse ratio computed from the
            // sweep-depth integer rather than the midpoint-containment
            // integer; the two diverge under the same conditions
            // documented on ConsensusResult.participantCount.
            'depth': result.participantCount / _sources.length,
            'quorumDepth': result.quorumDepth / _sources.length,
            'diversity': result.groupCount / 2.0,
            'stability': 1.0,
            // Fraction of the configured source pool that contributed a
            // Tier 1 (verified) sample to the published consensus winning
            // set (participants containing the consensus window's
            // midpoint, the engine's structural anchor). 0.0 when no
            // verified sample contained that midpoint; can be
            // low-but-positive on a degraded cycle when verified samples
            // contained the fallback window's midpoint without having
            // formed a truth box. Read alongside degradedTier, not as a
            // degradation discriminant on its own.
            'tier1Quorum': _sources.isEmpty
                ? 0.0
                : result.participants
                          .where((s) => s.authLevel == NtsAuthLevel.verified)
                          .length /
                      _sources.length,
          },
        ),
      );

      if (!completer.isCompleted) completer.complete(anchor);
    } catch (e) {
      // Unlike the redundant `completer.completeError(e)` removed from
      // sync()'s catch block, this one is the *only* path that
      // propagates the failure to the awaiter. _completeSync runs
      // inside the per-source pipeline (via the unawaited fan-out at
      // sync() line ~268 → sample stream listener → _completeSync),
      // so any throw here happens on a future the awaiter never sees
      // directly — the only listener is sync()'s
      // `completer.future.timeout(...)`. Without this completeError,
      // a failure inside _createAnchor (e.g., monotonic clock channel
      // throws, or the consensus result has no participant samples)
      // would be swallowed and sync() would block until its outer
      // timeout fires, masking the real cause behind a generic
      // 'Synchronization timed out' message.
      if (!completer.isCompleted) completer.completeError(e);
    }
  }

  Future<TrustAnchor> _createAnchor(ConsensusResult result) async {
    // Anchor selection validates that consensus has participant samples.
    // This prevents outliers from corrupting the monotonic clock reference.
    final participantSamples = result.participants;
    if (participantSamples.isEmpty) {
      // Structural invariant violation, not network weather: a retry of
      // the same cycle would produce the same empty participant set.
      throw const TrustedTimeSyncException(
        'Consensus result has no participant samples',
        transient: false,
      );
    }

    // Stamp the boot-session identity so warm restore can compare it
    // against the device's current boot ID. Null on platforms without a
    // boot concept (web), where the anchor cannot outlive the session
    // anyway. Read *before* the clock readings below: bootId is a
    // platform-channel round trip whose latency must not fall between
    // the uptime reading and the age measurement, or it would be
    // subtracted from an uptime it never aged (over-backdating).
    final bootId = await _clock.getBootId();
    final uptimeMs = await _clock.uptimeMs();
    final wallMs = DateTime.now().millisecondsSinceEpoch;
    // Age reference stamp, taken synchronously right after the readings
    // it corrects so the interval [receipt reference → this stamp]
    // brackets uptimeMs/wallMs as tightly as possible. Only the
    // uptimeMs channel-return latency remains inside the measurement.
    final currentReceiptMs = TimeSample.monotonicReceiptNowMs();

    // Backdate the anchor readings to the consensus reference instant.
    // The consensus UTC estimates the true time at the normalization
    // reference (the latest receipt stamp, which every normalized
    // participant carries after normalizedTo), while uptimeMs / wallMs
    // above were read moments *later* — after stream processing,
    // consensus resolution, and the awaits. Left uncorrected, that
    // age is baked into the anchor as permanent skew: projection pairs
    // an older UTC with younger clock readings. Subtracting the age
    // makes all three anchor fields describe the same instant.
    //
    // The age is measured on the receipt timeline and accepted only
    // within (0, min(maxLatency, uptimeMs)]: negative ages cannot
    // arise from real stamps (receipts precede anchor creation) but
    // do arise from synthetic fixture stamps on an unrelated scale,
    // an age beyond the whole query budget likewise indicates stamps
    // this arithmetic must not trust, and an age exceeding the device
    // uptime would backdate the anchor to before boot — impossible on
    // a real device (the receipt timeline starts after process start,
    // which starts after boot) and a violation of the "ms since boot"
    // invariant on uptimeMs. All degenerate cases fall back to the
    // pre-existing behaviour (no backdating) rather than corrupting
    // the anchor.
    int? refMs;
    for (final s in participantSamples) {
      final r = s.receivedAtMs;
      if (r != null && (refMs == null || r > refMs)) refMs = r;
    }
    var ageMs = 0;
    if (refMs != null) {
      final rawAge = currentReceiptMs - refMs;
      if (rawAge > 0 &&
          rawAge <= _config.maxLatency.inMilliseconds &&
          rawAge <= uptimeMs) {
        ageMs = rawAge;
      }
    }

    return TrustAnchor(
      networkUtcMs: result.utc.millisecondsSinceEpoch,
      uptimeMs: uptimeMs - ageMs,
      wallMs: wallMs - ageMs,
      uncertaintyMs: result.uncertaintyMs,
      authLevel: result.authLevel,
      confidence: result.confidence,
      bootId: bootId,
    );
  }

  /// Finalizes synchronization when all queries complete.
  void _finalizeSync(
    List<TimeSample> samples,
    int rejectedInvalid,
    int totalSources,
    Completer<TrustAnchor> completer,
    _CompletionGuard guard, {
    int? elapsedMs,
  }) {
    if (completer.isCompleted) return;

    // All sources responded but we haven't reached stability.
    // Try one final resolve with all samples before failing.
    final (normalized, _) = _normalizedToLatestReceipt(samples);
    final finalResult = _engine.resolve(normalized);
    if (finalResult != null && samples.length >= _config.minimumQuorum) {
      unawaited(
        _completeSync(finalResult, samples, elapsedMs ?? 0, completer, guard),
      );
    } else {
      // Improved quorum-failure messaging with accurate counts
      final eligibleCount = samples.length;
      final sampleWord = eligibleCount == 1 ? 'sample' : 'samples';
      final rejectedWord = rejectedInvalid == 1 ? 'source was' : 'sources were';

      completer.completeError(
        TrustedTimeSyncException(
          'Failed to reach quorum: got $eligibleCount eligible $sampleWord '
          '($rejectedInvalid $rejectedWord rejected as invalid) from $totalSources total sources.',
        ),
      );
    }
  }

  /// Shifts every sample carrying a receipt timestamp so all intervals
  /// estimate the true time at one shared reference instant — the
  /// latest receipt in the population — before Marzullo intersection.
  ///
  /// Each sample's interval brackets the true time *at its own receipt
  /// instant*. When a cycle's queries complete seconds apart (typical
  /// on a just-woken radio, where the first responses ride a stalling
  /// link), intersecting the raw intervals under-counts overlap by
  /// exactly the receipt spread: two perfect ±50 ms samples received
  /// 3 s apart share no overlap at all and read as disagreeing
  /// sources. Normalizing to a common instant removes that artificial
  /// disagreement while leaving genuinely conflicting sources apart.
  ///
  /// The latest receipt is chosen (rather than the earliest) so the
  /// consensus midpoint stays as close as possible to the
  /// anchor-creation instant that [_createAnchor] pairs it with.
  /// Samples without a receipt timestamp (legacy fixtures, custom
  /// sources) pass through unshifted, preserving existing behaviour.
  ///
  /// Returns the normalized population together with the reference
  /// instant used (`0` when no sample carried a receipt timestamp, in
  /// which case the population is returned as-is). Callers that
  /// compare successive consensus intervals for stability must
  /// translate them by `-refMs` first: the reference advances as new
  /// samples arrive, so absolute intervals shift between resolves even
  /// when the underlying consensus is unchanged.
  (List<TimeSample>, int) _normalizedToLatestReceipt(List<TimeSample> samples) {
    int? refMs;
    for (final s in samples) {
      final r = s.receivedAtMs;
      if (r != null && (refMs == null || r > refMs)) refMs = r;
    }
    if (refMs == null) return (samples, 0);
    final ref = refMs;
    return (
      samples.map((s) => s.normalizedTo(ref)).toList(growable: false),
      ref,
    );
  }

  /// One structured `sample <id> ok|fail` line per source per query,
  /// symmetric across source kinds (NTP, HTTPS, NTS, additional) so
  /// "is NTP working?" is answerable from the log stream directly
  /// rather than by subtracting NTS burst counts from consensus totals.
  void _logSample(TimeSample sample) {
    if (!TrustedTimeLog.enabled) return;
    // Approximate server-vs-local offset at receipt; diagnostic only.
    final offsetMs =
        sample.utc.millisecondsSinceEpoch -
        DateTime.now().toUtc().millisecondsSinceEpoch;
    final sign = offsetMs < 0 ? '' : '+';
    final rtt = sample.delayMs == null ? 'n/a' : '${sample.delayMs}ms';
    TrustedTimeLog.log(
      TrustedTimeLogLevel.debug,
      '[TrustedTime] sample ${sample.sourceId} ok rtt=$rtt '
      'offset=$sign${offsetMs}ms u=${sample.uncertaintyMs}ms '
      'authLevel=${sample.authLevel.name}',
    );
  }

  /// Failure counterpart of [_logSample].
  void _logSampleFailure(String sourceId, Object reason) {
    if (!TrustedTimeLog.enabled) return;
    TrustedTimeLog.log(
      TrustedTimeLogLevel.info,
      '[TrustedTime] sample $sourceId fail reason=$reason',
    );
  }

  /// Wraps a source query with timeout and health-tracking logic.
  Future<TimeSample?> _querySafe(TimeSource source) async {
    try {
      final sample = await source.getTime().timeout(_config.maxLatency);
      _sourceHealth[source.id] = 0; // Reset failure count on success
      _sourceTransientStreak.remove(source.id);
      _blacklistUntil.remove(source.id);
      _logSample(sample);
      return sample;
    } on TransientSourceError catch (e) {
      // Source classified the failure as transient (e.g. NtsSource saw
      // NtsError.timeout(TimeoutPhase.dnsSaturation): the DNS resolver
      // pool was momentarily full). Notify the observer and skip the
      // exponential cooldown — the next sync cycle is expected to
      // succeed once contention clears.
      //
      // A genuinely transient condition resolves within a cycle or
      // two; a "transient" condition that persists across many cycles
      // is indistinguishable from a sustained outage and should be
      // treated like one. Once the consecutive-streak counter reaches
      // [TrustedTimeConfig.transientStreakThreshold], promote the
      // failure to the regular cooldown ladder so the host gets
      // exponential backoff and surfaces as unhealthy through the
      // standard `_blacklistUntil` path.
      _logSampleFailure(source.id, e);
      _observer?.onSourceFailed(source.id, e);
      // The source was actually queried this cycle (it just failed
      // transiently), so refresh its last-queried cycle for starvation
      // accounting. Without this, a source later escalated to cooldown via
      // the streak path would carry no recorded query, so isStarved() would
      // treat it as never-queried and the starvation rescue would re-admit
      // it on the very next cycle, defeating the cooldown it just entered.
      _qualityTracker.recordFailure(source.id);
      final threshold = _config.transientStreakThreshold;
      // threshold <= 0 disables escalation entirely; skip the streak
      // bookkeeping so the map cannot accumulate unbounded entries
      // for a source that the caller has explicitly opted out of
      // ever escalating.
      if (threshold > 0) {
        final streak = (_sourceTransientStreak[source.id] ?? 0) + 1;
        _sourceTransientStreak[source.id] = streak;
        if (streak >= threshold) {
          _armCooldown(source.id);
        }
      }
      return null;
    } catch (e) {
      _logSampleFailure(source.id, e);
      _observer?.onSourceFailed(source.id, e);
      // Record the failure against the quality score *before*
      // arming the cooldown so the tracker sees the failed
      // observation even if subsequent cycles never query this
      // source again (cooldown could keep it out for a while).
      // _armCooldown is our centralised helper (added in our
      // wy3 / cooldown work) that the transient-streak path
      // also reuses; upstream inlined the cooldown bookkeeping
      // here, but the centralised form is the load-bearing
      // shape on this fork.
      _qualityTracker.recordFailure(source.id);
      _armCooldown(source.id);
      return null;
    }
  }

  /// Increments [sourceId]'s failure score and arms the exponential
  /// `2^min(score, 6)`-minute cooldown via `_blacklistUntil`. Drops any
  /// accumulated transient-streak entry because the source is now on
  /// the regular cooldown ladder; the streak is only meaningful for
  /// sources currently outside cooldown.
  ///
  /// The score is incremented (not reset) so a source that already
  /// accrued unrecovered failure score before this call — for example,
  /// a regular failure that armed a short cooldown which has since
  /// expired, followed by a transient streak that escalated here — is
  /// treated as exhibiting cumulative unhealthiness and progresses
  /// further along the cooldown ladder rather than silently restarting
  /// at the bottom rung (`2^1 = 2` minutes) every time.
  void _armCooldown(String sourceId) {
    _sourceTransientStreak.remove(sourceId);
    final score = (_sourceHealth[sourceId] ?? 0) + 1;
    _sourceHealth[sourceId] = score;
    final cooldownMin = pow(2, min(score, 6)).toInt();
    _blacklistUntil[sourceId] = DateTime.now().add(
      Duration(minutes: cooldownMin),
    );
  }

  /// Records a failed sync cycle: notifies the observer and bumps the
  /// exponential-backoff attempt counter. Centralised so the early-bail
  /// empty-pool path and the main try/catch path stay in lockstep — any
  /// future addition (e.g. metrics, structured logging) only needs to
  /// land here.
  void _markSyncFailed(Object error) {
    _observer?.onSyncFailed(error);
    _syncAttempts++;
  }

  /// Calculates the next retry delay for the entire engine.
  Duration getNextRetryDelay() {
    if (_syncAttempts == 0) return Duration.zero;
    final exponent = min(_syncAttempts, 8);
    final seconds = pow(2, exponent).toInt();
    return Duration(seconds: seconds);
  }

  /// Releases network and platform resources.
  void dispose() {
    for (final source in _sources) {
      if (source is HttpsSource) source.dispose();
    }
  }
}

/// Per-cycle synchronous re-entry guard for [SyncEngine._completeSync].
///
/// Allocated fresh at the top of each [SyncEngine.sync] call and
/// captured by the sample-stream listener closure, so the guard's
/// lifetime is exactly one sync cycle. Both `_completeSync` call
/// sites in the listener (the early-exit path and the
/// finalize-via-`_finalizeSync` path) receive the same instance, so
/// the second invocation observes [inFlight] set by the first and
/// bails before any observable work — exactly like an engine-instance
/// `bool` flag would, but without the cross-cycle reset hazard:
/// overlapping `sync()` invocations on the same engine instance each
/// own a distinct guard and cannot reset each other's state.
class _CompletionGuard {
  bool inFlight = false;
}
