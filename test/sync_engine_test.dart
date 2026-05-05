import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_nts/src/exceptions.dart';
import 'package:trusted_time_nts/src/models.dart';
import 'package:trusted_time_nts/src/sync_engine.dart';

class _FakeTimeSource implements TrustedTimeSource {
  _FakeTimeSource({
    required String id,
    required this.networkUtc,
    this.roundTripTime = const Duration(milliseconds: 20),
    this.uncertainty,
    this.capturedMonotonicMs = 1000,
    this.shouldThrow = false,
    this.throwInnerTimeout = false,
    this.throwPostResponse = false,
    this.fetchDelay,
    this.capturedAt,
  }) : _id = id;

  final String _id;
  final DateTime networkUtc;
  final Duration roundTripTime;
  // Optional explicit override for `TimeSample.uncertainty`. When null,
  // falls back to the historical RTT/2 derivation so existing tests that
  // do not care about uncertainty wiring keep their original behaviour.
  // Tests that exercise the "uncertainty drives Marzullo intervals"
  // contract pass a value tighter than RTT/2 and assert that the
  // engine honours it.
  final Duration? uncertainty;
  final int capturedMonotonicMs;
  final bool shouldThrow;
  // Throws a `TimeoutException` *inside* `fetch()` rather than from the
  // outer `.timeout(maxLatency)` wrapper in `_querySafe`. The two
  // exception types reach `_querySafe` identically, so the engine must
  // distinguish them by sentinel rather than by type — exercised by
  // the "inner TimeoutException is bucketed as failed, not timed out"
  // regression. Real-world equivalent: `HttpsSource` enforces its own
  // hard-coded 30 s defensive per-request HTTP ceiling independent of
  // `maxLatency`, and a probe under a `maxLatency` larger than 30 s
  // would surface that inner timeout if the engine were not careful.
  final bool throwInnerTimeout;
  // Throws a generic exception *after* the pre-response delay has
  // resolved, simulating a successful network round trip whose
  // payload could not be parsed or validated. Real-world equivalent:
  // `HttpsSource` throws after capturing the response when the
  // server omits or malforms the `Date` header. The bucket
  // destination is the same catch-all as `shouldThrow`, but the
  // *labeling* in the diagnostic must remain neutral ("yielded no
  // usable sample") rather than implying a transport failure
  // ("failed to respond" / "failed before responding"). Exercised by
  // the "post-response parse failure ends up in `failed` bucket
  // under neutral wording" regression.
  final bool throwPostResponse;
  // Optional pre-response delay. Tests that need to exercise the real
  // `Future.timeout(maxLatency)` path in `_querySafe` set this to a
  // value greater than `maxLatency` so the outer wrapper abandons
  // the await before `fetch()` returns a `TimeSample` — the
  // production case for built-in HTTPS/NTS sources when the network
  // is slow but reachable. `Future.timeout` does not cancel the
  // underlying delay; the fake's `Future.delayed` keeps running in
  // the background after the wrapper has surrendered, which mirrors
  // real source behaviour and is exactly why the engine has to use
  // a sentinel to tell outer-budget abandonment apart from inner
  // `TimeoutException`s.
  final Duration? fetchDelay;
  // Optional fixed capturedAt so tests asserting `anchor.wallMs` can pin
  // a deterministic value. When null, falls back to wall-clock now() for
  // tests that only care about `uptimeMs` / consensus shape.
  final DateTime? capturedAt;

  @override
  String get id => _id;

  @override
  Future<TimeSample> fetch() async {
    if (shouldThrow) throw Exception('fake source failure');
    if (throwInnerTimeout) {
      throw TimeoutException('inner per-request timeout');
    }
    if (fetchDelay != null) {
      await Future<void>.delayed(fetchDelay!);
    }
    if (throwPostResponse) {
      // Mirrors HttpsSource throwing after capturing the response,
      // when e.g. the Date header is missing or malformed.
      throw const FormatException('malformed response payload');
    }
    return TimeSample(
      networkUtc: networkUtc,
      roundTripTime: roundTripTime,
      uncertainty:
          uncertainty ??
          Duration(milliseconds: roundTripTime.inMilliseconds ~/ 2),
      capturedMonotonicMs: capturedMonotonicMs,
      source: TimeSourceMetadata(kind: TimeSourceKind.custom, id: _id),
      capturedAt: capturedAt ?? DateTime.now().toUtc(),
    );
  }
}

void main() {
  group('SyncEngine.withSources', () {
    final baseTime = DateTime.utc(2024, 6, 15, 12);
    final baseMs = baseTime.millisecondsSinceEpoch;
    const config = TrustedTimeConfig(
      httpsSources: [],
      minimumQuorum: 2,
      maxLatency: Duration(seconds: 3),
    );

    test('returns anchor pinned to lowest-RTT sample monotonic', () async {
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'fast',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 10),
            capturedMonotonicMs: 5000,
          ),
          _FakeTimeSource(
            id: 'slow',
            networkUtc: baseTime.add(const Duration(milliseconds: 5)),
            roundTripTime: const Duration(milliseconds: 200),
            capturedMonotonicMs: 9000,
          ),
        ],
      );

      final anchor = await engine.sync();
      // Anchor uptime must come from the fastest sample, not a re-sample
      // taken after slower siblings resolved.
      expect(anchor.uptimeMs, 5000);
      // Network UTC is the consensus midpoint (within tolerance).
      final diff = (anchor.networkUtcMs - baseMs).abs();
      expect(diff, lessThan(50));
    });

    test('uncertainty propagates from Marzullo intersection', () async {
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'a',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 100),
            capturedMonotonicMs: 1000,
          ),
          _FakeTimeSource(
            id: 'b',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 100),
            capturedMonotonicMs: 1100,
          ),
        ],
      );

      final anchor = await engine.sync();
      expect(anchor.uncertaintyMs, greaterThanOrEqualTo(0));
      expect(anchor.uncertaintyMs, lessThanOrEqualTo(100));
    });

    test('published anchor interval covers Marzullo result when midpoint is '
        'mid-millisecond', () async {
      // The internal Marzullo engine resolves at microsecond
      // resolution, but `TrustAnchor.{networkUtcMs, uncertaintyMs}`
      // is a whole-millisecond surface. Flooring the centre via
      // `millisecondsSinceEpoch` shifts it up to 999 µs *left* of
      // the true midpoint; if the half-width is only ceiling-rounded
      // from microseconds (without folding in that truncation
      // residual), the published interval `[c-u, c+u]` excludes up
      // to 999 µs of the true upper bound — silently understating
      // uncertainty even though both knobs were rounded
      // "conservatively" in isolation. This regression pins both
      // sources at `baseTime + 750 µs` with a tight 100 µs advertised
      // bound (floored by the engine to 1000 µs / 1 ms), so the
      // truncation residual is the dominant term: without folding
      // the residual into the half-width, the published
      // `uncertaintyMs` would round to 1 and the upper published
      // bound would land 750 µs short of the true Marzullo upper
      // bound. The fix widens by `(uncertaintyMicros + residual +
      // 999) ~/ 1000`, surfacing as `uncertaintyMs >= 2` here.
      final offset = const Duration(microseconds: 750);
      final shifted = baseTime.add(offset);
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'a',
            networkUtc: shifted,
            roundTripTime: const Duration(milliseconds: 50),
            uncertainty: const Duration(microseconds: 100),
            capturedMonotonicMs: 1000,
          ),
          _FakeTimeSource(
            id: 'b',
            networkUtc: shifted,
            roundTripTime: const Duration(milliseconds: 50),
            uncertainty: const Duration(microseconds: 100),
            capturedMonotonicMs: 1100,
          ),
        ],
      );

      final anchor = await engine.sync();

      // The true Marzullo interval (in microseconds) is centred on
      // `baseMicros + 750` with a half-width floored at 1000 µs by
      // the engine. The published interval — derived from
      // `networkUtcMs` and `uncertaintyMs` — must fully contain that
      // microsecond-resolution window in both directions.
      final trueMidMicros = shifted.microsecondsSinceEpoch;
      const trueHalfWidthMicros = 1000;
      final trueLoMicros = trueMidMicros - trueHalfWidthMicros;
      final trueHiMicros = trueMidMicros + trueHalfWidthMicros;

      final publishedLoMicros =
          (anchor.networkUtcMs - anchor.uncertaintyMs) * 1000;
      final publishedHiMicros =
          (anchor.networkUtcMs + anchor.uncertaintyMs) * 1000;

      expect(publishedLoMicros, lessThanOrEqualTo(trueLoMicros));
      expect(publishedHiMicros, greaterThanOrEqualTo(trueHiMicros));
      // The fix surfaces as `uncertaintyMs >= 2` for a 750 µs
      // residual + 1000 µs floored half-width; a regression that
      // dropped the residual term would land at 1 ms and fail the
      // upper-bound assertion above. Pin the value directly so the
      // intent is visible in the diagnostic on regression.
      expect(anchor.uncertaintyMs, greaterThanOrEqualTo(2));
    });

    test('published anchor interval covers Marzullo result for pre-epoch '
        'midpoint', () async {
      // The residual-compensation path uses `~/ 1000` to project the
      // microsecond-resolution midpoint onto the millisecond grid.
      // Truncating division rounds *toward zero*, so for a pre-epoch
      // `midMicros = -1500` it would yield `networkUtcMs = -1` and a
      // *negative* `residualMicros = -500`, silently *narrowing* the
      // published interval below the true Marzullo window. The fix
      // uses Euclidean modulo (`%` on int with a positive divisor
      // returns a value in `[0, 1000)`) so the residual stays
      // non-negative and the containment guarantee holds for any
      // `DateTime` the engine could legitimately resolve to,
      // including pre-1970 timestamps. This regression pins two
      // sources at `1969-12-31 23:59:59.999250 UTC` (i.e. 750 µs
      // before the epoch) so the truncation residual is the
      // dominant term and a regression that reverted to
      // truncating-toward-zero division would fail the containment
      // assertion below.
      final preEpoch = DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 250);
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'a',
            networkUtc: preEpoch,
            roundTripTime: const Duration(milliseconds: 50),
            uncertainty: const Duration(microseconds: 100),
            capturedMonotonicMs: 1000,
          ),
          _FakeTimeSource(
            id: 'b',
            networkUtc: preEpoch,
            roundTripTime: const Duration(milliseconds: 50),
            uncertainty: const Duration(microseconds: 100),
            capturedMonotonicMs: 1100,
          ),
        ],
      );

      final anchor = await engine.sync();

      // The true Marzullo interval is centred on
      // `preEpoch.microsecondsSinceEpoch` with a half-width floored
      // at 1000 µs by the engine. The published interval (in µs)
      // must fully contain that window in both directions.
      final trueMidMicros = preEpoch.microsecondsSinceEpoch;
      const trueHalfWidthMicros = 1000;
      final trueLoMicros = trueMidMicros - trueHalfWidthMicros;
      final trueHiMicros = trueMidMicros + trueHalfWidthMicros;

      final publishedLoMicros =
          (anchor.networkUtcMs - anchor.uncertaintyMs) * 1000;
      final publishedHiMicros =
          (anchor.networkUtcMs + anchor.uncertaintyMs) * 1000;

      expect(publishedLoMicros, lessThanOrEqualTo(trueLoMicros));
      expect(publishedHiMicros, greaterThanOrEqualTo(trueHiMicros));
    });

    test('throws when no sources respond', () async {
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(id: 'a', networkUtc: baseTime, shouldThrow: true),
          _FakeTimeSource(id: 'b', networkUtc: baseTime, shouldThrow: true),
        ],
      );
      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
    });

    test(
      'throws a configuration-shaped exception when no sources are configured',
      () async {
        // An engine constructed with zero sources is a configuration
        // bug, not a runtime budget miss. Without an explicit guard,
        // `_queryConcurrently()` returns all-zero counters and the
        // pure-timeout branch in `sync()` reports
        // `0 sources timed out after maxLatency=...` — a bogus
        // diagnosis that points the caller at network behaviour
        // rather than their own config. The empty-source guard must
        // fire first and surface the real cause.
        final engine = SyncEngine.withSources(
          config: config,
          sources: const <TrustedTimeSource>[],
        );
        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          expect(e.message, contains('No time sources configured'));
          expect(e.message, contains('ntsServers'));
          expect(e.message, contains('httpsSources'));
          expect(e.message, contains('additionalSources'));
          // Regression guard: must NOT degenerate into the bogus
          // "0 sources timed out" wording from the pure-timeout
          // branch of the diagnostic dispatch.
          expect(e.message, isNot(contains('timed out')));
          expect(e.message, isNot(contains('maxLatency')));
        }
      },
    );

    test('throws when quorum cannot be reached (single source)', () async {
      final engine = SyncEngine.withSources(
        config: config,
        sources: [_FakeTimeSource(id: 'a', networkUtc: baseTime)],
      );
      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
    });

    test('filters out samples exceeding maxLatency', () async {
      const fastConfig = TrustedTimeConfig(
        httpsSources: [],
        minimumQuorum: 2,
        maxLatency: Duration(milliseconds: 50),
      );
      final engine = SyncEngine.withSources(
        config: fastConfig,
        sources: [
          _FakeTimeSource(
            id: 'a',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 30),
          ),
          _FakeTimeSource(
            id: 'b',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 500),
          ),
        ],
      );
      // Only one sample survives the latency filter — quorum fails.
      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
    });

    test('rejects negative-RTT samples from anchor selection', () async {
      // A malformed source returns a negative RTT. Two well-behaved
      // sources agree on the consensus midpoint, with monotonic uptimes
      // 5000 and 9000. The malformed source has the smallest (negative)
      // RTT and would win the lowest-RTT reduce if it were not filtered,
      // pinning anchor.uptimeMs to its 1 ms reference.
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'fast',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 10),
            capturedMonotonicMs: 5000,
          ),
          _FakeTimeSource(
            id: 'slow',
            networkUtc: baseTime.add(const Duration(milliseconds: 5)),
            roundTripTime: const Duration(milliseconds: 200),
            capturedMonotonicMs: 9000,
          ),
          _FakeTimeSource(
            id: 'broken',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: -50),
            capturedMonotonicMs: 1,
          ),
        ],
      );

      final anchor = await engine.sync();
      // Anchor must come from `fast` (5000), not the broken source (1).
      expect(anchor.uptimeMs, 5000);
    });

    test(
      'quorum-failure message reports eligible (filtered) sample count',
      () async {
        // Two sources fetch successfully, but one returns a negative RTT
        // and is filtered. With minimumQuorum=2 the message must say "1
        // eligible sample (1 rejected as invalid)" rather than the
        // misleading "2 samples".
        final engine = SyncEngine.withSources(
          config: config,
          sources: [
            _FakeTimeSource(
              id: 'good',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 20),
            ),
            _FakeTimeSource(
              id: 'broken',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: -10),
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          // Assert on structural facts (eligible count, rejected count,
          // the words "eligible" and "rejected") rather than exact
          // wording, so future grammar/format cleanups don't fail the
          // test while the behaviour is unchanged.
          expect(e.message, contains('eligible'));
          expect(e.message, contains('rejected'));
          expect(e.message, matches(RegExp(r'\b1\b.*eligible')));
          expect(e.message, matches(RegExp(r'1 rejected')));
        }
      },
    );

    test('all-malformed run reports zero eligible samples in quorum-failure '
        'message', () async {
      // Two sources respond, both with contract-violating negative RTT.
      // The engine has no dedicated "every source malformed" branch:
      // the standard quorum-failure path reports `0 eligible (2 rejected
      // as invalid)`, which is more accurate than a custom message
      // would be (samples that exceeded `maxLatency` are filtered
      // upstream and never enter the eligible/rejected accounting).
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'a',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: -5),
          ),
          _FakeTimeSource(
            id: 'b',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: -10),
          ),
        ],
      );

      try {
        await engine.sync();
        fail('expected TrustedTimeSyncException');
      } on TrustedTimeSyncException catch (e) {
        expect(e.message, contains('Quorum not reached'));
        expect(e.message, matches(RegExp(r'\b0\b.*eligible')));
        expect(e.message, matches(RegExp(r'2 rejected')));
      }
    });

    test(
      'distinguishes "all over-latency" from "no source responded"',
      () async {
        // Every source returns a sample (no fetch failures), but every
        // RTT exceeds `maxLatency`. The `rawSamples.isEmpty` branch is
        // shared with the genuine no-response case, so without the
        // dedicated latency diagnostic the user would see the
        // pure-failure wording — misleading, because every source
        // *did* respond. The error must instead name `maxLatency` as
        // the cause and report the responded count so the caller can
        // distinguish a network outage from a tightly configured
        // latency budget.
        const tightConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(milliseconds: 50),
        );
        final engine = SyncEngine.withSources(
          config: tightConfig,
          sources: [
            _FakeTimeSource(
              id: 'a',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 200),
            ),
            _FakeTimeSource(
              id: 'b',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 500),
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          // Must NOT use the pure-failure wording (covers both the
          // historical "failed to respond" phrasing and the current
          // "failed to produce a usable sample" phrasing).
          expect(e.message, isNot(contains('failed to respond')));
          expect(
            e.message,
            isNot(contains('failed to produce a usable sample')),
          );
          // Must name the latency cause and the configured budget.
          expect(e.message, contains('maxLatency=50'));
          // Must report how many sources responded.
          expect(e.message, matches(RegExp(r'\b2\b.*responded')));
        }
      },
    );

    test(
      'quorum-failure message includes latency drops alongside invalid count',
      () async {
        // Three sources: one good (eligible), one over-latency (dropped
        // upstream), one negative-RTT (rejected as invalid). With
        // `minimumQuorum=2` the engine fails at quorum and the
        // diagnostic must surface BOTH causes so the caller can tell
        // why their otherwise-healthy run came up short — a regression
        // that elided latency drops would falsely suggest the only
        // problem was malformed data.
        const tightConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(milliseconds: 50),
        );
        final engine = SyncEngine.withSources(
          config: tightConfig,
          sources: [
            _FakeTimeSource(
              id: 'good',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 20),
            ),
            _FakeTimeSource(
              id: 'late',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 500),
            ),
            _FakeTimeSource(
              id: 'broken',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: -10),
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          expect(e.message, contains('Quorum not reached'));
          expect(e.message, matches(RegExp(r'\b1\b.*eligible')));
          expect(e.message, matches(RegExp(r'1 rejected')));
          expect(e.message, contains('1 dropped'));
          expect(e.message, contains('maxLatency=50'));
        }
      },
    );

    test(
      'quorum-failure message includes failed sources alongside invalid count',
      () async {
        // Three sources: one good (eligible), one negative-RTT
        // (rejected as invalid), one outright failure (no sample
        // returned). With `minimumQuorum=2` the engine fails at
        // quorum and the diagnostic must surface the `failed` bucket
        // alongside `invalid` — a regression that omitted `failed`
        // from the parenthetical (as the previous wording did) would
        // make a "1 eligible + 1 invalid + 1 fetch failure" run
        // indistinguishable from "1 eligible + 1 invalid", silently
        // hiding whichever sources never produced a sample at all.
        const tightConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(milliseconds: 50),
        );
        final engine = SyncEngine.withSources(
          config: tightConfig,
          sources: [
            _FakeTimeSource(
              id: 'good',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 20),
            ),
            _FakeTimeSource(
              id: 'broken',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: -10),
            ),
            _FakeTimeSource(
              id: 'down',
              networkUtc: baseTime,
              shouldThrow: true,
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          expect(e.message, contains('Quorum not reached'));
          expect(e.message, matches(RegExp(r'\b1\b.*eligible')));
          expect(e.message, matches(RegExp(r'1 rejected')));
          expect(e.message, contains('1 yielded no usable sample'));
          // Regression guard against the historical wording, which
          // implied a transport failure even when the bucket actually
          // covered post-response payload errors (e.g. an HTTPS
          // response without a usable Date header).
          expect(e.message, isNot(contains('failed before responding')));
        }
      },
    );

    test('latency check rejects samples whose RTT exceeds maxLatency by '
        'sub-millisecond margins', () async {
      // Regression: an earlier revision floored both sides of the
      // latency check to whole milliseconds before comparing
      // (`sample.roundTripTime.inMilliseconds <= maxLatency.inMilliseconds`),
      // which let a 50.5 ms RTT sneak past a 50 ms `maxLatency` —
      // both truncated to 50 ms before the `<=`. The fix compares
      // the `Duration` objects directly so the gate runs at the
      // resolution the inputs carry. With two sources at 50.5 ms
      // each and quorum=2, the engine must reject both as
      // over-budget and surface the pure-over-latency diagnostic
      // rather than admitting either into the eligible pool.
      const tightConfig = TrustedTimeConfig(
        httpsSources: [],
        minimumQuorum: 2,
        maxLatency: Duration(milliseconds: 50),
      );
      final engine = SyncEngine.withSources(
        config: tightConfig,
        sources: [
          _FakeTimeSource(
            id: 'over1',
            networkUtc: baseTime,
            // 50.5 ms — half a millisecond above the budget. Floors
            // to 50 ms under the legacy ms-precision comparison and
            // would falsely pass.
            roundTripTime: const Duration(microseconds: 50500),
          ),
          _FakeTimeSource(
            id: 'over2',
            networkUtc: baseTime,
            roundTripTime: const Duration(microseconds: 50500),
          ),
        ],
      );

      try {
        await engine.sync();
        fail('expected TrustedTimeSyncException');
      } on TrustedTimeSyncException catch (e) {
        // Both samples must land in `droppedForLatency`, not in the
        // eligible pool. The pure-over-latency branch fires when
        // every responder was over budget.
        expect(
          e.message,
          contains(
            '2 sources responded but every sample exceeded '
            'maxLatency=50 ms.',
          ),
        );
        // Negative assertion: the over-budget run must NOT be
        // misattributed as a generic failure or a quorum shortfall.
        expect(e.message, isNot(contains('Quorum not reached')));
        expect(e.message, isNot(contains('failed to produce')));
      }
    });

    test(
      'sub-millisecond maxLatency renders as microseconds in diagnostics',
      () async {
        // `_queryConcurrently` compares RTT against `_config.maxLatency`
        // at full `Duration` precision, but the diagnostic emitter
        // historically formatted that threshold via `inMilliseconds` —
        // truncating a sub-ms budget like `Duration(microseconds: 500)`
        // to `0 ms` and pointing callers at the wrong threshold during
        // triage. The fix routes every diagnostic through
        // `_formatLatency`, which renders sub-ms budgets in
        // microseconds (e.g. `500 µs`) so the advertised threshold
        // matches the value the filter actually compared against.
        const subMsConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(microseconds: 500),
        );
        final engine = SyncEngine.withSources(
          config: subMsConfig,
          sources: [
            _FakeTimeSource(
              id: 'a',
              networkUtc: baseTime,
              // RTT exceeds the 500 µs budget by ~1 µs so both samples
              // land in `droppedForLatency` and the pure-over-latency
              // branch fires (no inner timeouts, no failures).
              roundTripTime: const Duration(microseconds: 501),
              uncertainty: const Duration(microseconds: 250),
              capturedMonotonicMs: 1000,
            ),
            _FakeTimeSource(
              id: 'b',
              networkUtc: baseTime,
              roundTripTime: const Duration(microseconds: 501),
              uncertainty: const Duration(microseconds: 250),
              capturedMonotonicMs: 1100,
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          // The advertised threshold must match the filter's actual
          // comparison: render in microseconds, not as `0 ms`.
          expect(e.message, contains('maxLatency=500 µs'));
          expect(e.message, isNot(contains('maxLatency=0 ms')));
        }
      },
    );

    test(
      'real Future.timeout drops produce the over-latency diagnostic',
      () async {
        // Production case: built-in HTTPS/NTS sources are wrapped in
        // `source.fetch().timeout(maxLatency)` inside `_querySafe`,
        // so a genuinely slow network round trip is abandoned by the
        // outer wrapper *before* a TimeSample is returned (the
        // underlying request is *not* cancelled — `Future.timeout`
        // only stops awaiting it). Without splitting timeouts from
        // generic failures the engine reports the pure-failure
        // wording — false, because the sources were reachable but
        // slower than the configured budget. The fake source delays
        // past `maxLatency` so the real timeout path fires (no
        // synthetic high-RTT TimeSample), pinning the production-case
        // fix rather than just the post-hoc filter that the previous
        // regression covered.
        const tightConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(milliseconds: 50),
        );
        final engine = SyncEngine.withSources(
          config: tightConfig,
          sources: [
            _FakeTimeSource(
              id: 'slow1',
              networkUtc: baseTime,
              fetchDelay: const Duration(milliseconds: 200),
            ),
            _FakeTimeSource(
              id: 'slow2',
              networkUtc: baseTime,
              fetchDelay: const Duration(milliseconds: 200),
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          // Regression guard against any pure-failure wording (covers
          // both the historical phrasing and the current "yielded no
          // usable sample" phrasing).
          expect(e.message, isNot(contains('failed to respond')));
          expect(
            e.message,
            isNot(contains('failed to produce a usable sample')),
          );
          expect(e.message, contains('timed out'));
          expect(e.message, contains('maxLatency=50'));
          expect(e.message, matches(RegExp(r'\b2\b.*timed out')));
        }
      },
    );

    test(
      'inner TimeoutException is bucketed as failed, not as a maxLatency timeout',
      () async {
        // Real-world equivalent: `HttpsSource` enforces its own hard-
        // coded 3 s per-request HTTP timeouts independent of the
        // configured `maxLatency`. When `maxLatency` is more generous
        // than the inner deadline (e.g. 30 s configured, 3 s inner),
        // a slow probe will surface a `TimeoutException` from inside
        // `source.fetch()` — *not* from the outer `.timeout(maxLatency)`
        // wrapper. Catching every `TimeoutException` as a
        // `maxLatency` event would attribute the cause to the wrong
        // budget. The engine distinguishes outer from inner timeouts
        // via a private sentinel raised in the outer `onTimeout`
        // callback, so only that sentinel maps to `timedOut`; inner
        // `TimeoutException`s fall through to the generic `failed`
        // bucket. This regression pins both the categorisation and
        // the message wording.
        const tightConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(milliseconds: 50),
        );
        final engine = SyncEngine.withSources(
          config: tightConfig,
          sources: [
            _FakeTimeSource(
              id: 'inner1',
              networkUtc: baseTime,
              throwInnerTimeout: true,
            ),
            _FakeTimeSource(
              id: 'inner2',
              networkUtc: baseTime,
              throwInnerTimeout: true,
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          // Two sources both threw `TimeoutException` *inside* fetch().
          // They must reach the pure-failure branch ("Every configured
          // time source failed to produce a usable sample.") — not
          // the pure-timeout branch which would falsely name
          // maxLatency=50.
          expect(e.message, contains('failed to produce a usable sample'));
          expect(e.message, isNot(contains('timed out')));
          expect(e.message, isNot(contains('maxLatency=50')));
        }
      },
    );

    test('post-response parse failure reaches the `failed` bucket under '
        'neutral wording', () async {
      // Real-world equivalent: `HttpsSource` captures the response,
      // then throws after detecting a missing or malformed `Date`
      // header. The bucket destination in `_querySafe` is the
      // generic catch-all (same as a transport failure), so
      // labelling the bucket as "failed before responding" /
      // "failed to respond" misattributes a payload error as a
      // network non-response — diagnostically wrong. The fix is
      // purely about wording; the regression pins that the parse-
      // failure path produces the neutral "failed to produce a
      // usable sample" / "yielded no usable sample" wording rather
      // than implying transport non-response. Two `throwPostResponse`
      // sources reach the pure-failure branch, so the test asserts
      // the new pure-failure wording and forbids both legacy and
      // misleading phrasings.
      const tightConfig = TrustedTimeConfig(
        httpsSources: [],
        minimumQuorum: 2,
        maxLatency: Duration(milliseconds: 50),
      );
      final engine = SyncEngine.withSources(
        config: tightConfig,
        sources: [
          _FakeTimeSource(
            id: 'parse1',
            networkUtc: baseTime,
            throwPostResponse: true,
          ),
          _FakeTimeSource(
            id: 'parse2',
            networkUtc: baseTime,
            throwPostResponse: true,
          ),
        ],
      );

      try {
        await engine.sync();
        fail('expected TrustedTimeSyncException');
      } on TrustedTimeSyncException catch (e) {
        expect(e.message, contains('failed to produce a usable sample'));
        // Regression guards against the historical wording that
        // would have implied transport non-response when the
        // actual cause was a payload error.
        expect(e.message, isNot(contains('failed to respond')));
        expect(e.message, isNot(contains('before responding')));
        // Must NOT name maxLatency — these were not budget timeouts.
        expect(e.message, isNot(contains('timed out')));
        expect(e.message, isNot(contains('maxLatency=50')));
      }
    });

    test(
      'mixed timeout + outright failure produces multi-cause diagnostic',
      () async {
        // One source genuinely times out at the outer maxLatency
        // wrapper, one source throws outright before responding. With
        // only the {responded, droppedForLatency, timedOut} buckets a
        // generic-exception drop would silently fall into the
        // pure-timeout branch ("N source(s) timed out after
        // maxLatency=...") and misattribute the half of the outage
        // that wasn't a budget timeout to the budget. The engine now
        // tracks `failed` as a separate bucket, and any combination
        // of {timed out, responded over-budget, failed} reaches a
        // multi-cause diagnostic that names each contributing bucket.
        const tightConfig = TrustedTimeConfig(
          httpsSources: [],
          minimumQuorum: 2,
          maxLatency: Duration(milliseconds: 50),
        );
        final engine = SyncEngine.withSources(
          config: tightConfig,
          sources: [
            _FakeTimeSource(
              id: 'slow',
              networkUtc: baseTime,
              fetchDelay: const Duration(milliseconds: 200),
            ),
            _FakeTimeSource(
              id: 'broken',
              networkUtc: baseTime,
              shouldThrow: true,
            ),
          ],
        );

        try {
          await engine.sync();
          fail('expected TrustedTimeSyncException');
        } on TrustedTimeSyncException catch (e) {
          // Multi-cause framing — neither a pure-timeout nor a pure-
          // failure message would name both buckets.
          expect(e.message, contains('No source produced an in-budget sample'));
          expect(e.message, contains('1 timed out'));
          expect(e.message, contains('1 yielded no usable sample'));
          expect(e.message, contains('maxLatency=50'));
          // Must NOT use the pure-timeout wording that would falsely
          // attribute the entire outage to a budget timeout.
          expect(
            e.message,
            isNot(matches(RegExp(r'\b1 source timed out after maxLatency'))),
          );
          // Regression guard against the historical "failed before
          // responding" wording, which implied a transport failure
          // even when the bucket actually covers post-response
          // payload errors as well.
          expect(e.message, isNot(contains('failed before responding')));
        }
      },
    );

    test('rejects samples with negative TimeSample.uncertainty', () async {
      // The non-negative-uncertainty contract is enforced separately
      // from non-negative RTT — a custom source can violate one
      // without the other (e.g. a misconfigured source advertising
      // a negative dispersion alongside a sane RTT). Without an
      // explicit filter on `TimeSample.uncertainty` in the
      // SyncEngine, a negative value would (a) inject a negative
      // interval width into the Marzullo sweep and crash it, and
      // (b) win the lowest-RTT reduction, pinning the anchor's
      // monotonic/wall reference to a sample that should never have
      // participated. With one good source + minimumQuorum=2 the
      // run must throw, and the diagnostic must surface the
      // rejection count rather than silently elide the malformed
      // sample.
      final engine = SyncEngine.withSources(
        config: config,
        sources: [
          _FakeTimeSource(
            id: 'good',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 100),
          ),
          _FakeTimeSource(
            id: 'bad',
            networkUtc: baseTime,
            roundTripTime: const Duration(milliseconds: 100),
            uncertainty: const Duration(milliseconds: -1),
          ),
        ],
      );

      try {
        await engine.sync();
        fail('expected TrustedTimeSyncException');
      } on TrustedTimeSyncException catch (e) {
        expect(e.message, contains('Quorum not reached'));
        expect(e.message, matches(RegExp(r'\b1\b.*eligible')));
        expect(e.message, matches(RegExp(r'1 rejected')));
      }
    });

    test(
      'TimeSample.uncertainty drives Marzullo intervals, not RTT/2',
      () async {
        // Custom-source contract from `TimeSample.uncertainty` dartdoc:
        // sources with tighter internal estimates may report less than
        // RTT/2 (NTS exposes server stratum + dispersion, for example).
        // Previously `sync()` rebuilt Marzullo intervals from
        // `roundTripTime.inMilliseconds`, silently ignoring an advertised
        // tighter bound. This test pins the new wiring by constructing a
        // scenario where RTT/2 would include `c` in consensus but the
        // advertised uncertainty excludes it:
        //
        //   - a@base, RTT=100 ms, uncertainty=10 ms (RTT/2 would be 50)
        //   - b@base, RTT=200 ms, uncertainty=10 ms (RTT/2 would be 100)
        //   - c@base+50, RTT=20 ms, uncertainty=10 ms (RTT/2 would be 10)
        //
        // With RTT/2: a=[base-50,+50], b=[base-100,+100], c=[base+40,+60].
        // a∩b∩c = [base+40,+50] — three participants, lowest-RTT pick = c
        // (RTT 20), so anchor.uptimeMs would be c's monotonic (1).
        //
        // With advertised uncertainty: a=b=[base-10,+10], c=[base+40,+60].
        // a∩b = [base-10,+10], c disjoint — two participants, lowest-RTT
        // pick = a (RTT 100 < b's 200), so anchor.uptimeMs == 5000.
        //
        // The assertion `expect(anchor.uptimeMs, 5000)` therefore fails
        // both under the previous RTT/2 derivation (would be 1) and
        // under any future regression that re-derives intervals from
        // RTT instead of reading `TimeSample.uncertainty`.
        final aWallAt = DateTime.utc(2024, 6, 15, 12, 0, 1);
        final engine = SyncEngine.withSources(
          config: config,
          sources: [
            _FakeTimeSource(
              id: 'a',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 100),
              uncertainty: const Duration(milliseconds: 10),
              capturedMonotonicMs: 5000,
              capturedAt: aWallAt,
            ),
            _FakeTimeSource(
              id: 'b',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 200),
              uncertainty: const Duration(milliseconds: 10),
              capturedMonotonicMs: 9000,
            ),
            _FakeTimeSource(
              id: 'c',
              networkUtc: baseTime.add(const Duration(milliseconds: 50)),
              roundTripTime: const Duration(milliseconds: 20),
              uncertainty: const Duration(milliseconds: 10),
              capturedMonotonicMs: 1,
            ),
          ],
        );

        final anchor = await engine.sync();
        expect(anchor.uptimeMs, 5000);
        expect(anchor.wallMs, aWallAt.millisecondsSinceEpoch);
      },
    );

    test(
      'anchor uptime comes from a consensus participant, not a fast outlier',
      () async {
        // Three sources, minimumQuorum=2. `good1` and `good2` agree on
        // a UTC near `baseTime` with overlapping uncertainty intervals;
        // `outlier` reports a UTC 1 s in the future with the smallest
        // RTT (and therefore the smallest uncertainty), placing its
        // interval well outside the good1∩good2 intersection. Marzullo
        // resolves consensus on {good1, good2}; without participant
        // filtering the lowest-RTT reduction would still pick `outlier`
        // and pin `anchor.uptimeMs` to its capture monotonic — a
        // capture instant that had nothing to say about consensus UTC.
        // With participant filtering the anchor must come from `good1`
        // (lowest RTT among participants), pinning *both* uptimeMs and
        // wallMs to good1's capture instants — wallMs covers offline
        // estimation and persistence, so a regression that returned
        // good1's uptime but outlier's capturedAt would still corrupt
        // the anchor's wall reference.
        //
        // good1's RTT (50 ms) is strictly less than good2's (100 ms)
        // so the lowest-RTT-among-participants rule has a unique
        // winner — without that gap the test would silently rely on
        // the reducer's tie-break order ("first wins on ties"), and a
        // harmless tie-break refactor could regress the assertion
        // even with outlier exclusion still working correctly.
        final good1WallAt = DateTime.utc(2024, 6, 15, 12, 0, 1);
        final good2WallAt = DateTime.utc(2024, 6, 15, 12, 0, 2);
        final outlierWallAt = DateTime.utc(2024, 6, 15, 12, 0, 3);
        final engine = SyncEngine.withSources(
          config: config,
          sources: [
            _FakeTimeSource(
              id: 'good1',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 50),
              capturedMonotonicMs: 5000,
              capturedAt: good1WallAt,
            ),
            _FakeTimeSource(
              id: 'good2',
              networkUtc: baseTime.add(const Duration(milliseconds: 20)),
              roundTripTime: const Duration(milliseconds: 100),
              capturedMonotonicMs: 9000,
              capturedAt: good2WallAt,
            ),
            _FakeTimeSource(
              id: 'outlier',
              networkUtc: baseTime.add(const Duration(seconds: 1)),
              roundTripTime: const Duration(milliseconds: 10),
              capturedMonotonicMs: 1,
              capturedAt: outlierWallAt,
            ),
          ],
        );

        final anchor = await engine.sync();
        expect(anchor.uptimeMs, 5000);
        expect(anchor.wallMs, good1WallAt.millisecondsSinceEpoch);
      },
    );

    test(
      'anchor uptime ignores same-source-id outliers outside the intersection',
      () async {
        // Two sources happen to share an id (e.g. duplicate config: the
        // same NTS host listed twice in `ntsServers`). The duplicate
        // responds extremely fast (10 ms RTT) but reports a UTC 1 s in
        // the future, placing its interval well outside the consensus
        // window. A third source agrees with the first on baseTime.
        // Filtering anchor candidates by `source.id` would re-admit the
        // fast outlier — both share id `dup` — and pin uptimeMs to its
        // capture instant. Filtering by SourceSample identity (the
        // current contract) excludes the outlier even though another
        // sample from the same id participated in consensus, so the
        // anchor must come from the lowest-RTT *participant* (`good`,
        // monotonic 5000). wallMs is asserted alongside uptimeMs so a
        // regression that re-admitted the same-id outlier into the
        // anchor pick can't sneak through by only producing the right
        // monotonic.
        final dupGoodWallAt = DateTime.utc(2024, 6, 15, 12, 0, 1);
        final dupBadWallAt = DateTime.utc(2024, 6, 15, 12, 0, 2);
        final goodWallAt = DateTime.utc(2024, 6, 15, 12, 0, 3);
        final engine = SyncEngine.withSources(
          config: config,
          sources: [
            _FakeTimeSource(
              id: 'dup',
              networkUtc: baseTime,
              roundTripTime: const Duration(milliseconds: 100),
              capturedMonotonicMs: 7000,
              capturedAt: dupGoodWallAt,
            ),
            _FakeTimeSource(
              id: 'dup',
              networkUtc: baseTime.add(const Duration(seconds: 1)),
              roundTripTime: const Duration(milliseconds: 10),
              capturedMonotonicMs: 1,
              capturedAt: dupBadWallAt,
            ),
            _FakeTimeSource(
              id: 'good',
              networkUtc: baseTime.add(const Duration(milliseconds: 20)),
              roundTripTime: const Duration(milliseconds: 50),
              capturedMonotonicMs: 5000,
              capturedAt: goodWallAt,
            ),
          ],
        );

        final anchor = await engine.sync();
        expect(anchor.uptimeMs, 5000);
        expect(anchor.wallMs, goodWallAt.millisecondsSinceEpoch);
      },
    );
  });
}
