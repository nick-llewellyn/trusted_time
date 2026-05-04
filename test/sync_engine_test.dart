import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_nts/src/exceptions.dart';
import 'package:trusted_time_nts/src/models.dart';
import 'package:trusted_time_nts/src/sync_engine.dart';

class _FakeTimeSource implements TrustedTimeSource {
  _FakeTimeSource({
    required String id,
    required this.networkUtc,
    this.roundTripTime = const Duration(milliseconds: 20),
    this.capturedMonotonicMs = 1000,
    this.shouldThrow = false,
    this.capturedAt,
  }) : _id = id;

  final String _id;
  final DateTime networkUtc;
  final Duration roundTripTime;
  final int capturedMonotonicMs;
  final bool shouldThrow;
  // Optional fixed capturedAt so tests asserting `anchor.wallMs` can pin
  // a deterministic value. When null, falls back to wall-clock now() for
  // tests that only care about `uptimeMs` / consensus shape.
  final DateTime? capturedAt;

  @override
  String get id => _id;

  @override
  Future<TimeSample> fetch() async {
    if (shouldThrow) throw Exception('fake source failure');
    return TimeSample(
      networkUtc: networkUtc,
      roundTripTime: roundTripTime,
      uncertainty: Duration(milliseconds: roundTripTime.inMilliseconds ~/ 2),
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
        // dedicated latency diagnostic the user would see "Every
        // configured time source failed to respond." — misleading,
        // because every source *did* respond. The error must instead
        // name `maxLatency` as the cause and report the responded
        // count so the caller can distinguish a network outage from a
        // tightly configured latency budget.
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
          // Must NOT use the no-response wording.
          expect(e.message, isNot(contains('failed to respond')));
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
