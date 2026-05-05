import 'dart:async';
import 'package:flutter/foundation.dart';
import 'exceptions.dart';
import 'models.dart';
import 'marzullo.dart';
import 'monotonic_clock.dart';
import 'sources/time_sources.dart';

/// Orchestrates parallel queries across multiple time authorities to establish
/// a quorum-based trust anchor.
///
/// The [SyncEngine] builds a list of [TrustedTimeSource] instances from the
/// [TrustedTimeConfig] and queries them concurrently. Valid responses are
/// fed into the [MarzulloEngine] to compute a consensus UTC time with bounded
/// uncertainty.
final class SyncEngine {
  /// Creates a sync engine with the given [config] and [clock].
  ///
  /// Time-source instances are built from the config and the clock is
  /// forwarded to NTS/HTTPS sources so each can pin its monotonic
  /// reference at response receipt.
  SyncEngine({required TrustedTimeConfig config, required MonotonicClock clock})
    : _config = config,
      _engine = MarzulloEngine(minimumQuorum: config.minimumQuorum),
      _sources = [
        for (final host in config.ntsServers) NtsSource(host, clock: clock),
        for (final url in config.httpsSources) HttpsSource(url, clock: clock),
        ...config.additionalSources,
      ];

  /// Test seam: build a SyncEngine with a pre-assembled list of sources.
  /// Bypasses the config-driven source construction so unit tests can
  /// inject [TrustedTimeSource] fakes directly.
  @visibleForTesting
  SyncEngine.withSources({
    required TrustedTimeConfig config,
    required List<TrustedTimeSource> sources,
  }) : _config = config,
       _engine = MarzulloEngine(minimumQuorum: config.minimumQuorum),
       _sources = List.unmodifiable(sources);

  final TrustedTimeConfig _config;
  final MarzulloEngine _engine;
  final List<TrustedTimeSource> _sources;

  /// Executes concurrent sampling and returns a hardware-pinned trust anchor.
  ///
  /// Queries all configured time sources in parallel, filters by maximum
  /// latency, and uses Marzullo's algorithm to find the consensus interval.
  /// Each Marzullo interval is built from the sample's advertised
  /// [TimeSample.uncertainty] — *not* a generic `RTT/2` derivation — so a
  /// custom source with access to tighter bounds (e.g. NTS exposing the
  /// server's stratum and root dispersion) can narrow consensus
  /// accordingly. The anchor's uptime is pinned to the captured monotonic
  /// reference of the lowest-RTT *consensus participant* — the lowest-RTT
  /// sample whose advertised uncertainty interval contained the consensus
  /// midpoint. Filtering on participation (rather than on every eligible
  /// response) keeps a fast outlier whose interval missed the
  /// intersection from winning the reduction, even when another sample
  /// from the same source did participate. Pinning at receipt avoids
  /// drift from a post-aggregation re-sample.
  ///
  /// Throws [TrustedTimeSyncException] if no sources are configured, if
  /// no sources respond, or if quorum cannot be reached.
  Future<TrustAnchor> sync() async {
    // The empty-source configuration is its own failure mode: no
    // queries were attempted, so the post-query diagnostic dispatch
    // below — which is keyed on `responded`/`timedOut`/`failed` —
    // would otherwise hit the pure-timeout branch with all counters
    // at 0 and report "0 sources timed out after maxLatency=...". An
    // engine constructed with no sources is a configuration bug, not
    // a runtime budget miss; surface it explicitly so callers don't
    // chase a phantom timeout.
    if (_sources.isEmpty) {
      throw const TrustedTimeSyncException(
        'No time sources configured: provide at least one of '
        'ntsServers, httpsSources, or additionalSources in '
        'TrustedTimeConfig.',
      );
    }
    final query = await _queryConcurrently();
    final rawSamples = query.eligible;
    if (rawSamples.isEmpty) {
      // No sample survived latency filtering. The empty-eligible path
      // is reached by combinations of three disjoint outcome buckets
      // (`responded`, `timedOut`, `failed`) and needs separate
      // diagnostics so the caller can attribute the cause without
      // parsing free-form prose. Conflating any of these as "failed
      // to respond" — as the engine did historically — misleads
      // callers about why a sync that was really an over-budget run
      // came up empty, and silently re-attributing inner / outright
      // failures to a budget timeout is just as bad. The four
      // categorical branches below pin pure-fail, pure-timeout, and
      // pure post-hoc cases by name, and a single multi-cause branch
      // breaks down whichever buckets contributed for the rest.
      if (query.responded == 0 && query.timedOut == 0 && query.failed > 0) {
        // "Failed to produce a usable sample" deliberately spans the
        // three sub-causes of the `failed` bucket: transport failures
        // before any response (DNS, refused connection), inner
        // request timeouts (e.g. `HttpsSource`'s hard-coded 3 s HTTP
        // limit), and post-response validation/parse failures (e.g.
        // `HttpsSource` throwing after a missing or malformed `Date`
        // header). Wording it as "failed to respond" \u2014 as the engine
        // did historically \u2014 misattributes payload errors as
        // transport non-response and obscures parse failures during
        // production triage.
        throw const TrustedTimeSyncException(
          'Every configured time source failed to produce a usable sample.',
        );
      }
      final maxLatencyMs = _config.maxLatency.inMilliseconds;
      if (query.responded == 0 && query.failed == 0) {
        // Pure-timeout case.
        final word = query.timedOut == 1 ? 'source' : 'sources';
        throw TrustedTimeSyncException(
          '${query.timedOut} $word timed out after maxLatency='
          '$maxLatencyMs ms.',
        );
      }
      if (query.timedOut == 0 && query.failed == 0) {
        // Pure post-hoc-filter case (every source returned a
        // TimeSample, every RTT exceeded the budget).
        final word = query.responded == 1 ? 'source' : 'sources';
        throw TrustedTimeSyncException(
          '${query.responded} $word responded but every sample exceeded '
          'maxLatency=$maxLatencyMs ms.',
        );
      }
      // Multi-cause case: cite each bucket that contributed so the
      // caller can attribute the cause without guessing whether a
      // diagnosis omitted one.
      final notes = <String>[
        if (query.timedOut > 0)
          '${query.timedOut} timed out at maxLatency='
              '$maxLatencyMs ms',
        if (query.responded > 0)
          '${query.responded} responded with RTT > $maxLatencyMs ms',
        if (query.failed > 0) '${query.failed} yielded no usable sample',
      ];
      final total = query.timedOut + query.responded + query.failed;
      final word = total == 1 ? 'source' : 'sources';
      throw TrustedTimeSyncException(
        'No source produced an in-budget sample: $total $word '
        '(${notes.join(', ')}).',
      );
    }

    // Reject samples whose source violated either the non-negative RTT
    // or the non-negative uncertainty contract: admitting a violator
    // would (a) inject a negative interval width into the Marzullo
    // sweep and crash it, and (b) win the lowest-RTT reduction below —
    // pinning the anchor's monotonic/wall reference to a sample that
    // never participated in consensus. Filtering once here keeps
    // consensus, anchor selection, and the quorum-failure message in
    // agreement on the eligible sample set. Latency drops and timeouts
    // are accounted for separately via `query.droppedForLatency` and
    // `query.timedOut` so that the quorum-failure message can surface
    // the real cause when some sources were over-budget and some were
    // malformed.
    final samples = rawSamples
        .where((s) => !s.roundTripTime.isNegative && !s.uncertainty.isNegative)
        .toList(growable: false);

    // Build SourceSamples 1:1 with `samples` so that participating
    // SourceSample instances returned by Marzullo can be mapped back
    // to their TimeSamples by parallel index. `uncertaintyMs` is taken
    // from the sample's advertised `TimeSample.uncertainty` rather than
    // the historical RTT/2 derivation, honouring the documented
    // contract that a custom source may report a tighter bound than
    // half the round-trip.
    final marzulloSamples = [
      for (final s in samples)
        SourceSample(
          sourceId: s.source.id,
          utc: s.networkUtc,
          roundTripMs: s.roundTripTime.inMilliseconds,
          uncertaintyMs: s.uncertainty.inMilliseconds,
        ),
    ];

    final result = _engine.resolve(marzulloSamples);
    if (result == null) {
      final eligible = samples.length;
      final invalid = rawSamples.length - eligible;
      final droppedForLatency = query.droppedForLatency;
      final timedOut = query.timedOut;
      final failed = query.failed;
      final maxLatencyMs = _config.maxLatency.inMilliseconds;
      final eligibleWord = eligible == 1 ? 'sample' : 'samples';
      // Cite every contributing bucket so a reader can attribute the
      // shortfall without re-deriving the source counts. Omitting
      // `failed` would silently hide whichever sources produced no
      // usable sample (DNS, refused connection, inner request
      // timeout, post-response parse/validation error) whenever at
      // least one other sample survived latency filtering — exactly
      // the runs where the quorum-failure path fires. The "yielded
      // no usable sample" wording deliberately covers the
      // post-response payload-error sub-case alongside the transport
      // and inner-timeout sub-causes; "failed before responding" —
      // as previous wording put it — would misattribute payload
      // errors as transport non-response.
      final notes = <String>[
        if (invalid > 0) '$invalid rejected as invalid',
        if (droppedForLatency > 0)
          '$droppedForLatency dropped for exceeding '
              'maxLatency=$maxLatencyMs ms',
        if (timedOut > 0) '$timedOut timed out at maxLatency=$maxLatencyMs ms',
        if (failed > 0) '$failed yielded no usable sample',
      ];
      final notesPart = notes.isEmpty ? '' : ' (${notes.join('; ')})';
      throw TrustedTimeSyncException(
        'Quorum not reached: got $eligible eligible $eligibleWord$notesPart, '
        'need ${_config.minimumQuorum} for intersection.',
      );
    }

    // Pin uptime to the lowest-RTT consensus participant — the tightest
    // reference available among samples whose intervals were *inside*
    // the Marzullo intersection, recorded the instant the response was
    // received (not after slower siblings resolved). Filtering on
    // SourceSample identity (rather than `source.id`) is what keeps a
    // fast outlier — a sample whose interval missed the intersection
    // entirely — from winning the lowest-RTT pick, even when another
    // sample from the same source did participate (duplicate config,
    // future burst sampling, etc.). By construction the participant
    // set is non-empty (`minimumQuorum >= 1`) and every participant
    // came from `marzulloSamples`, so the filtered list is non-empty.
    final participantSamples = <TimeSample>[
      for (var i = 0; i < samples.length; i++)
        if (result.participants.contains(marzulloSamples[i])) samples[i],
    ];
    final best = participantSamples.reduce(
      (a, b) => a.roundTripTime <= b.roundTripTime ? a : b,
    );

    return TrustAnchor(
      networkUtcMs: result.utc.millisecondsSinceEpoch,
      uptimeMs: best.capturedMonotonicMs,
      wallMs: best.capturedAt.millisecondsSinceEpoch,
      uncertaintyMs: result.uncertaintyMs,
    );
  }

  /// Releases resources held by time sources (e.g., open HTTP clients).
  void dispose() {
    for (final source in _sources) {
      if (source is HttpsSource) source.dispose();
    }
  }

  /// Queries all sources concurrently and partitions outcomes.
  ///
  /// Returns the latency-eligible samples alongside four diagnostic
  /// counts that together account for every source the engine queried:
  ///
  /// - `responded`: returned a [TimeSample] regardless of its RTT.
  ///   Includes both samples accepted into `eligible` and samples
  ///   rejected by the `maxLatency` post-hoc filter.
  /// - `droppedForLatency`: of those `responded`, how many had an RTT
  ///   strictly greater than `maxLatency` and were therefore excluded
  ///   from `eligible`. Always `<= responded`.
  /// - `timedOut`: how many were abandoned by the outer
  ///   `timeout(maxLatency)` wrapper in [_querySafe] before yielding a
  ///   sample. `Future.timeout` does not cancel the underlying future;
  ///   it only stops awaiting it, so a timed-out probe may keep
  ///   running in the background — sources that need bounded
  ///   resource lifetimes must enforce their own cancellation
  ///   contract. Distinct from `TimeoutException`s raised *inside*
  ///   `source.fetch()` (e.g. an [HttpsSource]'s own per-request 3 s
  ///   limit) — those are bucketed as `failed`.
  /// - `failed`: returned no usable sample for any reason other than
  ///   the outer `maxLatency` wrapper. Spans transport failures
  ///   before any response (DNS, refused connection), inner
  ///   `TimeoutException`s, and post-response validation/parse
  ///   failures (e.g. an [HttpsSource] response without a usable
  ///   `Date` header). Diagnostics surface this bucket as "yielded
  ///   no usable sample" to avoid implying the source never
  ///   responded.
  ///
  /// `responded + timedOut + failed == _sources.length` by construction.
  /// Without the `failed` bucket, mixed runs like "one source timed out,
  /// one yielded a malformed payload" would silently fall into the
  /// pure-timeout branch in [sync] and misattribute the cause.
  Future<
    ({
      List<TimeSample> eligible,
      int responded,
      int droppedForLatency,
      int timedOut,
      int failed,
    })
  >
  _queryConcurrently() async {
    final outcomes = await Future.wait(_sources.map(_querySafe));
    final maxLatencyMs = _config.maxLatency.inMilliseconds;
    final eligible = <TimeSample>[];
    var responded = 0;
    var droppedForLatency = 0;
    var timedOut = 0;
    var failed = 0;
    for (final outcome in outcomes) {
      final sample = outcome.sample;
      if (sample != null) {
        responded++;
        if (sample.roundTripTime.inMilliseconds <= maxLatencyMs) {
          eligible.add(sample);
        } else {
          droppedForLatency++;
        }
      } else if (outcome.timedOut) {
        timedOut++;
      } else {
        failed++;
      }
    }
    return (
      eligible: eligible,
      responded: responded,
      droppedForLatency: droppedForLatency,
      timedOut: timedOut,
      failed: failed,
    );
  }

  /// Wraps a source query in a try-catch with timeout enforcement.
  ///
  /// Returns a record carrying either the sample (if `fetch()` resolved
  /// inside `maxLatency`) or a `timedOut` flag indicating the *outer*
  /// `maxLatency` wrapper fired. The split matters for diagnostics: a
  /// slow real-world fetch is abandoned by the wrapper *before* a
  /// `TimeSample` is produced, so a generic null return would leave
  /// [_queryConcurrently] unable to distinguish "the network was too
  /// slow for the configured budget" from "every source produced no
  /// usable sample" — and callers would see the latter when the real
  /// cause was the former.
  ///
  /// `Future.timeout` does not cancel the underlying future; it only
  /// stops awaiting it. The original `source.fetch()` work may
  /// continue in the background and complete (or fail) after the
  /// timeout fires, so callers that need bounded resource lifetimes
  /// must enforce their own cancellation contract on top of the
  /// source. The diagnostic split here is about *attribution*, not
  /// *resource cleanup*.
  ///
  /// `TimeoutException`s thrown *inside* `source.fetch()` (for example,
  /// [HttpsSource]'s hard-coded 3 s per-request HTTP timeouts) are
  /// explicitly *not* attributed to the outer `maxLatency` wrapper —
  /// otherwise, when `maxLatency` is larger than the inner deadline,
  /// the diagnostic would name the configured budget as the cause when
  /// a different timeout actually fired. To distinguish the two, the
  /// outer `.timeout(...)` raises a private sentinel
  /// ([_OuterTimeoutException]) via its `onTimeout` callback; only that
  /// sentinel maps to `timedOut: true`. Inner `TimeoutException`s fall
  /// through to the generic catch-all, joining the `failed` bucket
  /// alongside transport errors and post-response validation/parse
  /// failures (e.g. an [HttpsSource] response without a usable `Date`
  /// header).
  Future<({TimeSample? sample, bool timedOut})> _querySafe(
    TrustedTimeSource source,
  ) async {
    try {
      final sample = await source.fetch().timeout(
        _config.maxLatency,
        onTimeout: () => throw const _OuterTimeoutException(),
      );
      return (sample: sample, timedOut: false);
    } on _OuterTimeoutException {
      if (kDebugMode) {
        debugPrint(
          '[TrustedTime] Source ${source.id} exceeded maxLatency='
          '${_config.maxLatency.inMilliseconds} ms (outer timeout fired).',
        );
      }
      return (sample: null, timedOut: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TrustedTime] Source ${source.id} failed: $e');
      }
      return (sample: null, timedOut: false);
    }
  }
}

/// Sentinel raised by [SyncEngine._querySafe]'s outer
/// `timeout(maxLatency)` to distinguish a budget-induced kill from a
/// `TimeoutException` raised inside `source.fetch()` (e.g. an
/// [HttpsSource]'s own per-request HTTP timeouts). Only this sentinel
/// is treated as a `maxLatency` timeout in the diagnostic split; inner
/// `TimeoutException`s fall through to the generic failure bucket.
final class _OuterTimeoutException implements Exception {
  const _OuterTimeoutException();
}
