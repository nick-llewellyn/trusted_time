import 'dart:async';
import 'dart:math';
import 'domain/marzullo_engine.dart';
import 'domain/time_sample.dart';
import 'domain/time_source.dart';
import 'domain/time_interval.dart';
import 'exceptions.dart' show TransientSourceError, TrustedTimeSyncException;
import 'models.dart';
import 'monotonic_clock.dart';
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
  }) : _config = config,
       _clock = clock,
       _observer = observer,
       _cache = cache,
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

  /// Synchronous re-entry guard for [_completeSync]. Set to `true`
  /// before [_completeSync] awaits [_createAnchor] and reset to
  /// `false` at the top of each [sync] invocation.
  ///
  /// The completer-completion check on its own is insufficient because
  /// [_completeSync] awaits [_createAnchor] before calling
  /// `completer.complete(...)`, so two concurrent invocations from a
  /// single `sync()` cycle (the early-exit path and the
  /// last-sample/finalize path can both fire on the same listener
  /// event) both pass the `completer.isCompleted` guard, both await,
  /// and both fire `onConsensusReached` + `onMetricsReported` before
  /// either resolves the completer. This synchronous flag is
  /// inspected and set together before that first await so the
  /// second caller bails immediately.
  ///
  /// The flag is engine-instance scoped, which assumes [sync] is not
  /// invoked concurrently. Concurrent `sync()` invocations remain a
  /// separate concern (tracked as `trusted_time-exw`); once that
  /// guard is tight, this engine-scoped flag is unconditionally
  /// correct. Until then it eliminates the intra-`sync()` race that
  /// is the dominant source of duplicate consensus/metrics events.
  bool _completionInFlight = false;

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
    // Reset the synchronous re-entry guard so a fresh `sync()` is not
    // gated by a stale flag from the previous cycle. See the field's
    // dartdoc for the concurrent-`sync()` caveat.
    _completionInFlight = false;
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
    final now = DateTime.now();
    final activeSources = _sources.where((s) {
      final until = _blacklistUntil[s.id];
      return until == null || now.isAfter(until);
    }).toList();
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
                  _completeSync(result, swSync.elapsedMilliseconds, completer),
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
        onTimeout: () {
          if (!completer.isCompleted &&
              samples.length >= _config.minimumQuorum) {
            final result = _engine.resolve(samples);
            if (result != null) {
              return _createAnchor(result);
            }
          }
          throw TrustedTimeSyncException(
            'Synchronization timed out before reaching a stable quorum.',
          );
        },
      );

      _syncAttempts = 0;
      _cache?.update(anchor);
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
    int latencyMs,
    Completer<TrustAnchor> completer,
  ) async {
    // Synchronous re-entry guard: if the completer is already done OR
    // a sibling _completeSync invocation has already started its
    // _createAnchor await, bail before doing any observable work.
    // Both checks must happen together with the [_completionInFlight]
    // assignment, before the first await, so the second caller
    // observes the in-flight flag set by the first.
    if (completer.isCompleted || _completionInFlight) return;
    _completionInFlight = true;

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

      _observer?.onMetricsReported(
        SyncMetrics(
          latencyMs: latencyMs,
          uncertaintyMs: result.uncertaintyMs,
          participantCount: result.participantCount,
          groupCount: result.groupCount,
          confidence: result.confidence,
          confidenceBreakdown: {
            'depth': result.participantCount / _sources.length,
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
    Completer<TrustAnchor> completer, {
    int? elapsedMs,
  }) {
    if (completer.isCompleted) return;

    // All sources responded but we haven't reached stability.
    // Try one final resolve with all samples before failing.
    final finalResult = _engine.resolve(samples);
    if (finalResult != null && samples.length >= _config.minimumQuorum) {
      unawaited(_completeSync(finalResult, elapsedMs ?? 0, completer));
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
