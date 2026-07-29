import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/background_sync.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';

import 'support/fake_clocks.dart';
import 'support/fake_sources.dart';
import 'support/offline_config.dart';

/// Coverage for the headless background-sync unit-of-work
/// ([runBackgroundSync]) at the `src` level: anchor persistence, failure
/// semantics, and the per-platform retry schedule.
///
/// The public-API wrappers around this unit of work live in
/// `trusted_time_background_test.dart` (callback registration and
/// `TrustedTime.runBackgroundSync`) and
/// `trusted_time_scheduling_test.dart` (stop-reason reporting and
/// `TrustedTime.enableBackgroundSync`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runBackgroundSync', () {
    final consensusUtc = DateTime.utc(2026, 1, 15, 10);

    test('persists fresh anchor when sync succeeds', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: offlineConfig(
          sources: [
            FakeSource(
              idValue: 'fake-a',
              groupIdValue: 'g1',
              utc: consensusUtc,
            ),
            FakeSource(
              idValue: 'fake-b',
              groupIdValue: 'g2',
              utc: consensusUtc.add(const Duration(milliseconds: 5)),
            ),
          ],
        ),
        store: store,
        clock: FakeMonotonicClock(value: 5000),
      );
      expect(result, isA<BackgroundSyncSuccess>());
      expect(result.isSuccess, isTrue);
      final saved = await store.load();
      expect(saved, isNotNull);
      expect(
        saved!.networkUtcMs,
        closeTo(consensusUtc.millisecondsSinceEpoch, 100),
      );
      // The banked cycle also persists per-source quality stats so the
      // next run ranks servers on accumulated history.
      final stats = await store.loadSourceStats();
      expect(stats.keys, containsAll(['fake-a', 'fake-b']));
    });

    test('returns failure when quorum is not reached', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: offlineConfig(
          sources: [
            FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: consensusUtc,
              shouldThrow: true,
            ),
            FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: consensusUtc,
              shouldThrow: true,
            ),
          ],
        ),
        store: store,
        clock: FakeMonotonicClock(value: 5000),
        retryDelays: const [],
      );
      expect(result, isA<BackgroundSyncFailure>());
      expect(result.isSuccess, isFalse);
      expect(await store.load(), isNull);
    });

    test('skips persistence when persistState is false', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: offlineConfig(
          persistState: false,
          sources: [
            FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
          ],
        ),
        store: store,
        clock: FakeMonotonicClock(value: 5000),
      );
      expect(result, isA<BackgroundSyncSuccess>());
      expect(await store.load(), isNull);
      expect(await store.loadSourceStats(), isEmpty);
    });

    test(
      'advances persisted anchor.networkUtcMs from a stale baseline',
      () async {
        final staleUtc = DateTime.utc(2026, 1, 1);
        final freshUtc = DateTime.utc(2026, 6, 1, 12);
        final store = InMemoryAnchorStorage();

        // Seed a stale anchor mimicking what a previous foreground session
        // would have written.
        final stale = TrustAnchor(
          networkUtcMs: staleUtc.millisecondsSinceEpoch,
          uptimeMs: 1000,
          wallMs: staleUtc.millisecondsSinceEpoch,
          uncertaintyMs: 50,
        );
        await store.save(stale);

        final result = await runBackgroundSync(
          config: offlineConfig(
            sources: [
              FakeSource(idValue: 'stub-a', groupIdValue: 'g1', utc: freshUtc),
              FakeSource(
                idValue: 'stub-b',
                groupIdValue: 'g2',
                utc: freshUtc.add(const Duration(milliseconds: 8)),
              ),
            ],
          ),
          store: store,
          clock: FakeMonotonicClock(value: 7000),
        );

        expect(result, isA<BackgroundSyncSuccess>());
        final after = await store.load();
        expect(after, isNotNull);
        expect(
          after!.networkUtcMs,
          greaterThan(stale.networkUtcMs),
          reason: 'Background sync did not advance the persisted anchor.',
        );
        expect(
          after.networkUtcMs,
          closeTo(freshUtc.millisecondsSinceEpoch, 100),
        );
      },
    );

    test('leaves persisted anchor untouched when sync fails', () async {
      final staleUtc = DateTime.utc(2026, 1, 1);
      final store = InMemoryAnchorStorage();
      final original = TrustAnchor(
        networkUtcMs: staleUtc.millisecondsSinceEpoch,
        uptimeMs: 2000,
        wallMs: staleUtc.millisecondsSinceEpoch,
        uncertaintyMs: 100,
      );
      await store.save(original);

      final result = await runBackgroundSync(
        config: offlineConfig(
          sources: [
            FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: staleUtc,
              shouldThrow: true,
            ),
            FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: staleUtc,
              shouldThrow: true,
            ),
          ],
        ),
        store: store,
        clock: FakeMonotonicClock(value: 7000),
        retryDelays: const [],
      );

      expect(result, isA<BackgroundSyncFailure>());
      expect(await store.load(), original);
    });

    test('returns failure (not a throw) for an invalid trust config', () async {
      // effectiveTrustMode throws ArgumentError from SyncEngine's late-final
      // source-list initializer, so both sync() and a naive dispose() in the
      // finally block would rethrow it — overriding the intended
      // BackgroundSyncFailure return. Guards the try/catch(dispose) shape in
      // runBackgroundSync.
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: const TrustedTimeConfig(
          usePlatformTrust: true,
          customRootCerts: [1, 2, 3],
        ),
        store: store,
        clock: FakeMonotonicClock(value: 5000),
      );
      expect(result, isA<BackgroundSyncFailure>());
      expect(
        (result as BackgroundSyncFailure).reason,
        contains('mutually exclusive'),
      );
      expect(result.retryable, isFalse);
      expect(await store.load(), isNull);
    });

    // Coverage for the in-run retry loop added after the doze
    // maintenance-window failure mode was observed on-device: the OS wakes
    // the device, reports the network CONNECTED, and fires the worker, but
    // the just-woken radio serves degraded latency so the first quorum
    // attempt fails while a retry seconds later succeeds. The loop retries
    // TrustedTimeSyncException per the retryDelays schedule with a fresh
    // engine per attempt, and fails immediately on non-transient errors.
    group('in-run retry', () {
      test('retries a transient quorum failure and succeeds within the '
          'same run', () async {
        final store = InMemoryAnchorStorage();
        // Both sources fail on the first attempt (quorum failure), then
        // succeed — mimicking the settled-radio second attempt.
        final a = FakeSource(
          idValue: 'a',
          groupIdValue: 'g1',
          utc: consensusUtc,
          failuresBeforeSuccess: 1,
        );
        final b = FakeSource(
          idValue: 'b',
          groupIdValue: 'g2',
          utc: consensusUtc.add(const Duration(milliseconds: 5)),
          failuresBeforeSuccess: 1,
        );
        final result = await runBackgroundSync(
          config: offlineConfig(sources: [a, b]),
          store: store,
          clock: FakeMonotonicClock(value: 5000),
          retryDelays: const [Duration.zero],
        );
        expect(result, isA<BackgroundSyncSuccess>());
        expect(a.calls, 2);
        expect(b.calls, 2);
        expect(await store.load(), isNotNull);
      });

      test(
        'exhausts the retry schedule and reports the last failure',
        () async {
          final a = FakeSource(
            idValue: 'a',
            groupIdValue: 'g1',
            utc: consensusUtc,
            shouldThrow: true,
          );
          final b = FakeSource(
            idValue: 'b',
            groupIdValue: 'g2',
            utc: consensusUtc,
            shouldThrow: true,
          );
          final result = await runBackgroundSync(
            config: offlineConfig(persistState: false, sources: [a, b]),
            clock: FakeMonotonicClock(value: 5000),
            retryDelays: const [Duration.zero, Duration.zero],
          );
          expect(result, isA<BackgroundSyncFailure>());
          // retryDelays.length + 1 attempts, each against a fresh engine so
          // per-source cooldowns from a failed attempt cannot short-circuit
          // the next one into "all sources in cooldown".
          expect(a.calls, 3);
          expect(b.calls, 3);
          expect((result as BackgroundSyncFailure).reason, contains('quorum'));
          // Exhausted transient failures stay retryable: the OS
          // scheduler's own backoff remains the outer safety net.
          expect(result.retryable, isTrue);
        },
      );

      test('a non-transient error fails immediately without consuming the '
          'retry schedule', () async {
        // The invalid config throws ArgumentError from the engine's source
        // list initializer. With a long retry delay armed, completing
        // promptly proves the ArgumentError bypassed the retry loop.
        final sw = Stopwatch()..start();
        final result = await runBackgroundSync(
          config: const TrustedTimeConfig(
            usePlatformTrust: true,
            customRootCerts: [1, 2, 3],
          ),
          clock: FakeMonotonicClock(value: 5000),
          retryDelays: const [Duration(seconds: 30)],
        );
        sw.stop();
        expect(result, isA<BackgroundSyncFailure>());
        expect(
          (result as BackgroundSyncFailure).reason,
          contains('mutually exclusive'),
        );
        // Non-transient verdict crosses to the OS scheduler too: Android
        // maps retryable=false to Result.failure() for this interval.
        expect(result.retryable, isFalse);
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      });
    });

    // Regression coverage for trusted_time-y81: the headless isolate is a
    // fresh Dart isolate that does not inherit the foreground isolate's
    // flutter_rust_bridge initialisation, so runBackgroundSync must run the
    // shared NTS bootstrap itself before the engine builds any NtsSource.
    // The production defect (background NTS sync reaching 0 eligible samples
    // and RETRYing forever) went undetected because every existing test
    // injects fake sources with empty ntsServers, so the bootstrap gate was
    // never exercised. These tests drive that gate via the injectable
    // [ntsInit] seam so the real FFI is never touched.
    group('NTS runtime bootstrap (y81)', () {
      final consensusUtc = DateTime.utc(2026, 3, 1, 12);

      List<TimeSource> quorumFakes() => [
        FakeSource(idValue: 'fake-a', groupIdValue: 'g1', utc: consensusUtc),
        FakeSource(
          idValue: 'fake-b',
          groupIdValue: 'g2',
          utc: consensusUtc.add(const Duration(milliseconds: 5)),
        ),
      ];

      test(
        'initialises the NTS runtime when ntsServers is non-empty',
        () async {
          var initCalls = 0;
          final result = await runBackgroundSync(
            config: offlineConfig(
              persistState: false,
              ntsServers: const ['nts.example.test'],
              sources: quorumFakes(),
            ),
            clock: FakeMonotonicClock(value: 5000),
            ntsInit: () async => initCalls++,
          );
          // The fakes still form quorum; the key assertion is that the
          // background path bootstrapped the NTS FFI exactly once before
          // building the engine.
          expect(initCalls, 1);
          expect(result.isSuccess, isTrue);
        },
      );

      test('skips the NTS runtime when ntsServers is empty', () async {
        var initCalls = 0;
        final result = await runBackgroundSync(
          config: offlineConfig(persistState: false, sources: quorumFakes()),
          clock: FakeMonotonicClock(value: 5000),
          ntsInit: () async => initCalls++,
        );
        // Zero-overhead-when-unused: no ntsServers means no bootstrap.
        expect(initCalls, 0);
        expect(result.isSuccess, isTrue);
      });

      test('a genuine init failure degrades to NTS-disabled and still '
          'succeeds via other sources', () async {
        final store = InMemoryAnchorStorage();
        final result = await runBackgroundSync(
          config: offlineConfig(
            ntsServers: const ['nts.example.test'],
            sources: quorumFakes(),
          ),
          store: store,
          clock: FakeMonotonicClock(value: 5000),
          // A non-StateError (or a StateError whose message does not name
          // flutter_rust_bridge) is a real init failure: the bootstrap must
          // strip ntsServers rather than abort the whole cycle.
          ntsInit: () async => throw Exception('native asset missing'),
        );
        expect(result.isSuccess, isTrue);
        expect(await store.load(), isNotNull);
      });

      test('treats an already-initialised StateError as success', () async {
        final store = InMemoryAnchorStorage();
        final result = await runBackgroundSync(
          config: offlineConfig(
            ntsServers: const ['nts.example.test'],
            sources: quorumFakes(),
          ),
          store: store,
          clock: FakeMonotonicClock(value: 5000),
          // Mirrors package:nts's process-wide double-init panic wording;
          // the shared bootstrap must swallow it so a foreground init
          // followed by a background fire in the same process does not
          // silently disable NTS.
          ntsInit: () async => throw StateError(
            'Should not initialize flutter_rust_bridge twice',
          ),
        );
        expect(result.isSuccess, isTrue);
        expect(await store.load(), isNotNull);
      });
    });

    // The OS execution budgets differ by an order of magnitude (Android
    // worker: 9 min; iOS BGAppRefreshTask: ~30 s), so the default in-run
    // retry schedule is selected per platform. The Android 10s+20s waits
    // alone would exhaust the iOS budget before the final attempt began.
    group('default retry schedule platform split', () {
      test('Android gets the doze-tuned 10s+20s schedule', () {
        expect(defaultRetryDelaysFor(TargetPlatform.android), const [
          Duration(seconds: 10),
          Duration(seconds: 20),
        ]);
      });

      test('iOS gets a single short wait that fits the ~30s budget', () {
        final delays = defaultRetryDelaysFor(TargetPlatform.iOS);
        expect(delays, const [Duration(seconds: 2)]);
        // Invariant the schedule exists to protect: total sleep must
        // leave room for at least one full retry attempt (bounded by the
        // engine's 10s warming cap + maxLatency + 6s ≈ 20s) inside the
        // ~30s BGAppRefreshTask budget.
        final totalSleep = delays.fold(Duration.zero, (a, b) => a + b);
        expect(totalSleep, lessThan(const Duration(seconds: 10)));
      });

      test('platforms without an OS budget share the Android schedule', () {
        for (final platform in [
          TargetPlatform.linux,
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.fuchsia,
        ]) {
          expect(
            defaultRetryDelaysFor(platform),
            defaultRetryDelaysFor(TargetPlatform.android),
            reason: '$platform should reuse the Android schedule',
          );
        }
      });
    });
  });
}
