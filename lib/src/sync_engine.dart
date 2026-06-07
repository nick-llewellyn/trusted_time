import 'dart:async';
import 'dart:math';
import 'domain/marzullo_engine.dart';
import 'domain/time_sample.dart';
import 'domain/time_source.dart';
import 'domain/time_interval.dart';
import 'exceptions.dart' show TransientSourceError, TrustedTimeSyncException;
import 'models.dart';
import 'monotonic_clock.dart';
import 'source_quality_tracker.dart';
import 'sources/time_sources.dart';
import 'infra/sync_observer.dart';
import 'infra/consensus_cache.dart';

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
  /// Documented.
  SyncEngine({
    required TrustedTimeConfig config,
    required MonotonicClock clock,
    SyncObserver? observer,
    ConsensusCache? cache,
    SourceQualityTracker? qualityTracker,
  }) : _config = config,
       _clock = clock,
       _observer = observer,
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
  final ConsensusCache? _cache;
  final MarzulloEngine _engine;

  /// Lazily-initialized list of authoritative time sources.
  ///
  /// NTS sources receive a `dnsConcurrencyCap` of
  /// `ntsServers.length + 2` (or the explicit
  /// [TrustedTimeConfig.ntsDnsConcurrencyCap] override when set) so the
  /// per-cycle burst of resolutions stays under the `package:nts`
  /// process-wide pool ceiling. The `+ 2` margin absorbs incidental
  /// concurrent resolutions (e.g., warming overlapping with the start
  /// of a cycle) without forcing every caller to think about cap
  /// sizing.
  late final List<TimeSource> _sources = [
    for (final host in _config.ntpServers) NtpSource(host),
    for (final url in _config.httpsSources) HttpsSource(url),
    for (final host in _config.ntsServers)
      NtsSource(
        host,
        port: _config.ntsPort,
        dnsConcurrencyCap:
            _config.ntsDnsConcurrencyCap ?? _config.ntsServers.length + 2,
        maxLatency: _config.maxLatency,
        trustMode: _config.ntsTrustMode,
        onStratumObserved: (s) =>
            _qualityTracker.setStratum('${TimeSource.prefixNts}$host', s),
      ),
    ..._config.additionalSources,
  ];

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
  /// Intended to be called during application bootstrap so per-source
  /// setup costs (e.g., the NTS-KE TCP+TLS+key-exchange handshake)
  /// complete before the first [sync] cycle. Without this, those costs
  /// fall inside cycle 1's wall clock and contaminate sample
  /// timestamps with hundreds of milliseconds of skew, preventing
  /// Marzullo intervals from overlapping.
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
    final healthyById = {for (final s in healthySources) s.id: s};
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
          ? const TrustedTimeSyncException(
              'No time sources are configured: ntpServers, httpsSources, '
              'ntsServers, and additionalSources are all empty.',
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

          final result = _engine.resolve(samples);
          if (result != null) {
            // Stability Check: Escalates quorum requirements if high variance
            // is detected, ensuring we don't anchor to a jittery consensus.
            final varianceDetected = samples.any(
              (s) =>
                  (s.interval.midpoint - result.utc.millisecondsSinceEpoch)
                      .abs() >
                  500,
            );
            final requiredStability = varianceDetected ? 3 : 2;

            if (lastStabilityInterval == result.interval) {
              stableCount++;
            } else {
              stableCount = 1;
            }
            lastStabilityInterval = result.interval;

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

      // 2. Launch racing queries.
      //
      // Each source runs a per-source two-phase sequence concurrently
      // with the others:
      //   Phase A — for sources that implement [Warmable], warm() runs
      //     outside the per-query maxLatency budget, so slow handshakes
      //     (e.g., NTS-KE) do not eat into the timed query window.
      //     Sources that don't implement Warmable skip Phase A and
      //     proceed straight to the query, so they are not blocked by
      //     slower siblings.
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

      // Outer safety timeout. The per-source pipeline runs warm()
      // outside the maxLatency budget, so this deadline must cover
      // both phases. Budget = maxLatency (timed query window) + 5s for
      // a slow NTS-KE handshake (TCP + TLS 1.3 + key exchange,
      // typically ~1s but up to ~3s on poor networks) + 1s for stream
      // processing and consensus resolution overhead.
      final anchor = await completer.future.timeout(
        _config.maxLatency + const Duration(seconds: 6),
        onTimeout: () async {
          // Safety-net path: the completion machinery never resolved
          // [completer] within the deadline, yet enough samples arrived
          // to form a consensus. Route through [_completeSync] rather
          // than building a raw anchor inline so this path performs the
          // exact same bookkeeping as the early-exit and finalize paths:
          //  - per-source quality observations are recorded for the
          //    collected samples (flagged against the winning set), so
          //    the advanceCycle() below does not treat sources that
          //    answered this cycle as unqueried — which would otherwise
          //    skew the next cycle's ranking and starvation rescue; and
          //  - [completer] is resolved, so the sample-stream listener
          //    short-circuits instead of running on after sync() returns.
          // The per-cycle re-entry guard makes this a no-op (no
          // double-record, no duplicate observer events) if an
          // early-exit invocation is already in flight for this cycle.
          if (!completer.isCompleted &&
              samples.length >= _config.minimumQuorum) {
            final result = _engine.resolve(samples);
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
      _observer?.onConsensusReached(result);

      // Record one quality observation per source that returned a sample
      // this cycle, flagging whether it landed in the consensus winning
      // set. Iterating the full collected `samples` population (not just
      // `result.participants`) is what lets the tracker tell a
      // consistently-rejected source apart from a consistently-agreeing
      // one; looping participants alone pins every participation rate at
      // 1.0 because every iterated sample is a participant by definition.
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
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
      throw TrustedTimeSyncException(
        'Consensus result has no participant samples',
      );
    }

    final uptimeMs = await _clock.uptimeMs();
    final wallMs = DateTime.now().millisecondsSinceEpoch;

    return TrustAnchor(
      networkUtcMs: result.utc.millisecondsSinceEpoch,
      uptimeMs: uptimeMs,
      wallMs: wallMs,
      uncertaintyMs: result.uncertaintyMs,
      authLevel: result.authLevel,
      confidence: result.confidence,
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
    final finalResult = _engine.resolve(samples);
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

  /// Wraps a source query with timeout and health-tracking logic.
  Future<TimeSample?> _querySafe(TimeSource source) async {
    try {
      final sample = await source.getTime().timeout(_config.maxLatency);
      _sourceHealth[source.id] = 0; // Reset failure count on success
      _sourceTransientStreak.remove(source.id);
      _blacklistUntil.remove(source.id);
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
