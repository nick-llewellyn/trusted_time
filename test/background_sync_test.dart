import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/background_sync.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart' as public_api;

/// Coverage for the headless background-sync unit-of-work
/// ([runBackgroundSync]), its public-API wrapper
/// (`TrustedTime.runBackgroundSync` / `registerBackgroundCallback`), and
/// the `TrustedTime.enableBackgroundSync` scheduling contract (native
/// interval clamping and the desktop in-isolate timer fallback).
///
/// **Scope**: these tests pin the Dart-side contract — anchor persistence,
/// failure semantics, callback-handle registration, and the
/// `notifyBackgroundComplete` channel signal. They do **not** drive the
/// real OS scheduler because that requires a device and is
/// platform-specific. To exercise the real OS scheduler manually:
///
/// - Android: `adb shell cmd jobscheduler run -f [package] [jobId]`
///   against a debug-built host app, then inspect logs for the
///   `notifyBackgroundComplete` channel call.
/// - iOS: in Xcode with the simulator paused, run
///   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
///   _simulateLaunchForTaskWithIdentifier:@"com.trustedtime.backgroundsync"]`
///   and observe the headless engine spinning up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runBackgroundSync', () {
    final consensusUtc = DateTime.utc(2026, 1, 15, 10);

    test('persists fresh anchor when sync succeeds', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: _offlineConfig(
          sources: [
            _FakeSource(
              idValue: 'fake-a',
              groupIdValue: 'g1',
              utc: consensusUtc,
            ),
            _FakeSource(
              idValue: 'fake-b',
              groupIdValue: 'g2',
              utc: consensusUtc.add(const Duration(milliseconds: 5)),
            ),
          ],
        ),
        store: store,
        clock: _FakeMonotonicClock(5000),
      );
      expect(result, isA<BackgroundSyncSuccess>());
      expect(result.isSuccess, isTrue);
      final saved = await store.load();
      expect(saved, isNotNull);
      expect(
        saved!.networkUtcMs,
        closeTo(consensusUtc.millisecondsSinceEpoch, 100),
      );
    });

    test('returns failure when quorum is not reached', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: _offlineConfig(
          sources: [
            _FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: consensusUtc,
              shouldThrow: true,
            ),
            _FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: consensusUtc,
              shouldThrow: true,
            ),
          ],
        ),
        store: store,
        clock: _FakeMonotonicClock(5000),
        retryDelays: const [],
      );
      expect(result, isA<BackgroundSyncFailure>());
      expect(result.isSuccess, isFalse);
      expect(await store.load(), isNull);
    });

    test('skips persistence when persistState is false', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            _FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
          ],
        ),
        store: store,
        clock: _FakeMonotonicClock(5000),
      );
      expect(result, isA<BackgroundSyncSuccess>());
      expect(await store.load(), isNull);
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
          config: _offlineConfig(
            sources: [
              _FakeSource(idValue: 'stub-a', groupIdValue: 'g1', utc: freshUtc),
              _FakeSource(
                idValue: 'stub-b',
                groupIdValue: 'g2',
                utc: freshUtc.add(const Duration(milliseconds: 8)),
              ),
            ],
          ),
          store: store,
          clock: _FakeMonotonicClock(7000),
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
        config: _offlineConfig(
          sources: [
            _FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: staleUtc,
              shouldThrow: true,
            ),
            _FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: staleUtc,
              shouldThrow: true,
            ),
          ],
        ),
        store: store,
        clock: _FakeMonotonicClock(7000),
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
        clock: _FakeMonotonicClock(5000),
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
        final a = _FakeSource(
          idValue: 'a',
          groupIdValue: 'g1',
          utc: consensusUtc,
          failuresBeforeSuccess: 1,
        );
        final b = _FakeSource(
          idValue: 'b',
          groupIdValue: 'g2',
          utc: consensusUtc.add(const Duration(milliseconds: 5)),
          failuresBeforeSuccess: 1,
        );
        final result = await runBackgroundSync(
          config: _offlineConfig(sources: [a, b]),
          store: store,
          clock: _FakeMonotonicClock(5000),
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
          final a = _FakeSource(
            idValue: 'a',
            groupIdValue: 'g1',
            utc: consensusUtc,
            shouldThrow: true,
          );
          final b = _FakeSource(
            idValue: 'b',
            groupIdValue: 'g2',
            utc: consensusUtc,
            shouldThrow: true,
          );
          final result = await runBackgroundSync(
            config: _offlineConfig(persistState: false, sources: [a, b]),
            clock: _FakeMonotonicClock(5000),
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
          clock: _FakeMonotonicClock(5000),
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
        _FakeSource(idValue: 'fake-a', groupIdValue: 'g1', utc: consensusUtc),
        _FakeSource(
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
            config: _offlineConfig(
              persistState: false,
              ntsServers: const ['nts.example.test'],
              sources: quorumFakes(),
            ),
            clock: _FakeMonotonicClock(5000),
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
          config: _offlineConfig(persistState: false, sources: quorumFakes()),
          clock: _FakeMonotonicClock(5000),
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
          config: _offlineConfig(
            ntsServers: const ['nts.example.test'],
            sources: quorumFakes(),
          ),
          store: store,
          clock: _FakeMonotonicClock(5000),
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
          config: _offlineConfig(
            ntsServers: const ['nts.example.test'],
            sources: quorumFakes(),
          ),
          store: store,
          clock: _FakeMonotonicClock(5000),
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

  group('TrustedTime.registerBackgroundCallback', () {
    const channel = MethodChannel('trusted_time/background');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      // The default test platform is host-dependent (macOS for the local
      // test runner) which short-circuits registerBackgroundCallback as a
      // no-op. Pin to Android so the channel-call branch is exercised;
      // individual tests below override this where they specifically
      // assert the non-mobile no-op path.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('forwards the callback handle to the native channel', () async {
      await public_api.TrustedTime.registerBackgroundCallback(
        _registerableTopLevelCallback,
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setBackgroundCallbackHandle');
      expect(calls.single.arguments, isA<Map>());
      expect((calls.single.arguments as Map)['handle'], isA<int>());
    });

    test(
      'throws ArgumentError when callback handle cannot be resolved',
      () async {
        // Nested (non-top-level) functions cannot be resolved to a callback
        // handle by the Dart VM, so [PluginUtilities.getCallbackHandle]
        // returns null. The `@pragma('vm:entry-point')` annotation is a
        // separate, build-time concern not exercised here.
        void localCallback() {}
        expect(
          () =>
              public_api.TrustedTime.registerBackgroundCallback(localCallback),
          throwsArgumentError,
        );
      },
    );

    test('swallows MissingPluginException when channel is unmocked', () async {
      // Simulate a host that calls registration before the native plugin
      // is available: clearing the mock handler installed in setUp causes
      // invokeMethod to throw MissingPluginException, which
      // [TrustedTime.registerBackgroundCallback] must swallow so shared
      // startup code can call it unconditionally.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await expectLater(
        public_api.TrustedTime.registerBackgroundCallback(
          _registerableTopLevelCallback,
        ),
        completes,
      );
    });

    test('is a no-op on non-Android/iOS platforms (no channel call, '
        'no ArgumentError for unresolvable callbacks)', () async {
      // Override the per-group Android pin: pretend we're running on
      // desktop so the platform short-circuit fires before
      // PluginUtilities.getCallbackHandle is consulted. A closure (which
      // would normally throw ArgumentError) must complete normally and
      // the channel must receive zero calls because there is no OS
      // scheduler to read the persisted handle on these platforms.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      void localCallback() {}
      await expectLater(
        public_api.TrustedTime.registerBackgroundCallback(localCallback),
        completes,
      );
      expect(calls, isEmpty);
    });
  });

  group('TrustedTime.runBackgroundSync', () {
    const channel = MethodChannel('trusted_time/background');
    const monotonicChannel = MethodChannel('trusted_time/monotonic');
    final consensusUtc = DateTime.utc(2026, 1, 15, 10);
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      // The public API wires the real PlatformMonotonicClock into the
      // engine (no injection seam by design), so the monotonic channel
      // must answer getUptimeMs for the sync to reach consensus.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(monotonicChannel, (call) async {
            if (call.method == 'getUptimeMs') return 5000;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(monotonicChannel, null);
    });

    test(
      'notifies native of completion with success=true on a passing run',
      () async {
        final result = await public_api.TrustedTime.runBackgroundSync(
          // persistState=false so the run does not touch real
          // flutter_secure_storage from the test process.
          config: _offlineConfig(
            persistState: false,
            sources: [
              _FakeSource(
                idValue: 'fake-a',
                groupIdValue: 'g1',
                utc: consensusUtc,
              ),
              _FakeSource(
                idValue: 'fake-b',
                groupIdValue: 'g2',
                utc: consensusUtc.add(const Duration(milliseconds: 5)),
              ),
            ],
          ),
        );
        expect(result.isSuccess, isTrue);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'notifyBackgroundComplete');
        final args = calls.single.arguments as Map;
        expect(args['success'], isTrue);
        expect(args.containsKey('reason'), isFalse);
        expect(args.containsKey('retryable'), isFalse);
      },
    );

    test('notifies native of completion with success=false and reason on '
        'a failing run', () async {
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: consensusUtc,
              shouldThrow: true,
            ),
            _FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: consensusUtc,
              shouldThrow: true,
            ),
          ],
        ),
        retryDelays: const [],
      );
      expect(result.isSuccess, isFalse);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'notifyBackgroundComplete');
      final args = calls.single.arguments as Map;
      expect(args['success'], isFalse);
      expect(args['reason'], isA<String>());
      expect((args['reason'] as String).isNotEmpty, isTrue);
      // Transient (quorum) failure: the Android worker should keep
      // Result.retry() semantics for this interval.
      expect(args['retryable'], isTrue);
    });

    test('notifies native with retryable=false for a non-transient '
        'failure', () async {
      // Invalid trust config throws ArgumentError inside the engine —
      // the classification that must reach the native worker so it
      // returns Result.failure() instead of Result.retry().
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: const public_api.TrustedTimeConfig(
          usePlatformTrust: true,
          customRootCerts: [1, 2, 3],
        ),
        retryDelays: const [],
      );
      expect(result.isSuccess, isFalse);
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map;
      expect(args['success'], isFalse);
      expect(args['retryable'], isFalse);
    });

    test('swallows MissingPluginException when channel is unmocked', () async {
      // The default mock from setUp() is overridden with `null` here so
      // method-channel calls raise MissingPluginException (the realistic
      // desktop/web behaviour). The public API must still return the
      // sync result instead of propagating the channel error.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            _FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
          ],
        ),
      );
      expect(result.isSuccess, isTrue);
    });

    test('honors overrideForTesting: returns synthetic success without '
        'network I/O or channel traffic', () async {
      // Active mock must short-circuit the headless entrypoint identically
      // to enableBackgroundSync / registerBackgroundCallback. A failing
      // additionalSources list is wired in to prove the real sync engine
      // is never reached: if the override path were missed, every source
      // would throw and the result would be BackgroundSyncFailure.
      final mockTime = DateTime.utc(2026, 6, 1, 12);
      final mock = public_api.TrustedTimeMock(initial: mockTime);
      public_api.TrustedTime.overrideForTesting(mock);
      addTearDown(() {
        public_api.TrustedTime.resetOverride();
        mock.dispose();
      });

      final result = await public_api.TrustedTime.runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: consensusUtc,
              shouldThrow: true,
            ),
            _FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: consensusUtc,
              shouldThrow: true,
            ),
          ],
        ),
      );

      expect(result, isA<BackgroundSyncSuccess>());
      expect(result.isSuccess, isTrue);
      final success = result as BackgroundSyncSuccess;
      expect(success.anchor.networkUtcMs, mockTime.millisecondsSinceEpoch);
      expect(success.anchor.wallMs, mockTime.millisecondsSinceEpoch);
      expect(success.elapsed, Duration.zero);
      // Channel must see zero traffic — the override path skips the
      // notifyBackgroundComplete signal entirely (matching how
      // enableBackgroundSync / registerBackgroundCallback short-circuit
      // before any platform-channel call).
      expect(calls, isEmpty);
    });

    test('awaits onResult before sending notifyBackgroundComplete', () async {
      // The teardown-race contract: work done inside onResult must be
      // fully complete before the native completion signal is sent,
      // because the Android worker destroys the headless engine on
      // receipt of that signal. Ordering is pinned by recording events
      // from both the hook and the channel mock into one list.
      final events = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            events.add('channel:${call.method}');
            return null;
          });

      TrustedTimeBackgroundResult? observed;
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            _FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
          ],
        ),
        onResult: (r) async {
          // A real event-loop turn, mimicking async file I/O in the hook.
          await Future<void>.delayed(Duration.zero);
          observed = r;
          events.add('hook:onResult');
        },
      );

      expect(result.isSuccess, isTrue);
      expect(observed, same(result));
      expect(events, ['hook:onResult', 'channel:notifyBackgroundComplete']);
    });

    test('onResult receives the failure result on a failing run', () async {
      TrustedTimeBackgroundResult? observed;
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(
              idValue: 'a',
              groupIdValue: 'g1',
              utc: consensusUtc,
              shouldThrow: true,
            ),
            _FakeSource(
              idValue: 'b',
              groupIdValue: 'g2',
              utc: consensusUtc,
              shouldThrow: true,
            ),
          ],
        ),
        onResult: (r) async => observed = r,
        retryDelays: const [],
      );
      expect(result, isA<BackgroundSyncFailure>());
      expect(observed, same(result));
    });

    test('a throwing onResult hook is swallowed: sync outcome and '
        'completion signal are unaffected', () async {
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: _offlineConfig(
          persistState: false,
          sources: [
            _FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            _FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
          ],
        ),
        onResult: (_) async => throw StateError('observer exploded'),
      );
      expect(result.isSuccess, isTrue);
      // The completion signal must still be sent, with the sync's own
      // outcome — not the observer's failure.
      expect(calls, hasLength(1));
      expect(calls.single.method, 'notifyBackgroundComplete');
      expect((calls.single.arguments as Map)['success'], isTrue);
    });

    test('onResult observes the synthetic result under an active '
        'TrustedTimeMock override', () async {
      final mockTime = DateTime.utc(2026, 6, 1, 12);
      final mock = public_api.TrustedTimeMock(initial: mockTime);
      public_api.TrustedTime.overrideForTesting(mock);
      addTearDown(() {
        public_api.TrustedTime.resetOverride();
        mock.dispose();
      });

      TrustedTimeBackgroundResult? observed;
      final result = await public_api.TrustedTime.runBackgroundSync(
        onResult: (r) async => observed = r,
      );
      expect(observed, same(result));
      expect(observed, isA<BackgroundSyncSuccess>());
      // Still zero channel traffic on the override path.
      expect(calls, isEmpty);
    });
  });

  group('TrustedTime.getBackgroundStopReason', () {
    const channel = MethodChannel('trusted_time/background');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('maps a platform reply onto BackgroundSyncStopInfo', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getBackgroundStopReason');
            return {'state': 'ENQUEUED', 'stopReason': 3};
          });

      final info = await public_api.TrustedTime.getBackgroundStopReason();
      expect(info, isNotNull);
      expect(info!.state, 'ENQUEUED');
      expect(info.stopReason, 3);
      expect(info.stopReasonName, 'TIMEOUT');
    });

    test('returns null when the platform reports no scheduled work', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      expect(await public_api.TrustedTime.getBackgroundStopReason(), isNull);
    });

    test('returns null instead of surfacing platform errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'STOP_REASON_UNAVAILABLE');
          });

      expect(await public_api.TrustedTime.getBackgroundStopReason(), isNull);
    });

    test('returns null when the channel is unmocked (no platform)', () async {
      expect(await public_api.TrustedTime.getBackgroundStopReason(), isNull);
    });

    test('returns null under an active TrustedTimeMock override', () async {
      final mock = public_api.TrustedTimeMock(initial: DateTime.utc(2026));
      public_api.TrustedTime.overrideForTesting(mock);
      addTearDown(() {
        public_api.TrustedTime.resetOverride();
        mock.dispose();
      });
      var channelTouched = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            channelTouched = true;
            return {'state': 'ENQUEUED', 'stopReason': 0};
          });

      expect(await public_api.TrustedTime.getBackgroundStopReason(), isNull);
      expect(channelTouched, isFalse);
    });

    test('stopReasonName covers WorkManager sentinels and unknowns', () {
      const notStopped = BackgroundSyncStopInfo(
        state: 'ENQUEUED',
        stopReason: -256,
      );
      expect(notStopped.stopReasonName, 'NOT_STOPPED');
      const unknown = BackgroundSyncStopInfo(
        state: 'ENQUEUED',
        stopReason: -512,
      );
      expect(unknown.stopReasonName, 'UNKNOWN');
      const future = BackgroundSyncStopInfo(state: 'RUNNING', stopReason: 42);
      expect(future.stopReasonName, 'STOP_REASON_42');
    });
  });

  group('TrustedTime.enableBackgroundSync', () {
    const bgChannel = MethodChannel('trusted_time/background');
    const monotonicChannel = MethodChannel('trusted_time/monotonic');
    const integrityChannel = MethodChannel('trusted_time/integrity');
    final calls = <MethodCall>[];

    setUp(() async {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bgChannel, (call) async {
            calls.add(call);
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(monotonicChannel, (call) async {
            if (call.method == 'getUptimeMs') return 1000;
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(integrityChannel, (call) async => null);
      // A live engine is required so the public wrapper can reach
      // TrustedTimeImpl.instance. Empty source pools keep the bootstrap
      // sync network-free (it fails quorum, which initialize tolerates),
      // and backgroundSyncInterval stays null so no scheduling happens
      // until the test drives it explicitly.
      await public_api.TrustedTime.initialize(
        config: const public_api.TrustedTimeConfig(
          ntpServers: [],
          httpsSources: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      calls.clear();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TrustedTimeImpl.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bgChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(monotonicChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(integrityChannel, null);
    });

    test(
      'forwards intervalMinutes to the native scheduler on Android',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        await public_api.TrustedTime.enableBackgroundSync(
          interval: const Duration(hours: 24),
        );

        expect(calls, hasLength(1));
        expect(calls.single.method, 'enableBackgroundSync');
        expect(calls.single.arguments, {'intervalMinutes': 24 * 60});
        expect(TrustedTimeImpl.instance.debugDesktopBgTimer, isNull);
      },
    );

    test('routes iOS through the native scheduler as well', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 12),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'enableBackgroundSync');
      expect(calls.single.arguments, {'intervalMinutes': 12 * 60});
      expect(TrustedTimeImpl.instance.debugDesktopBgTimer, isNull);
    });

    test('forwards a sub-hour interval at minute resolution (above the '
        'floor)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(minutes: 30),
      );

      expect(calls.single.arguments, {'intervalMinutes': 30});
    });

    test('clamps intervals below the 15-minute WorkManager floor', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(minutes: 10),
      );

      expect(calls.single.arguments, {'intervalMinutes': 15});
    });

    test('clamps intervals above one week down to 168 hours worth of '
        'minutes', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 400),
      );

      expect(calls.single.arguments, {'intervalMinutes': 168 * 60});
    });

    test('arms an in-isolate periodic timer on desktop with no channel '
        'traffic', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 1),
      );

      expect(calls, isEmpty);
      final firstTimer = TrustedTimeImpl.instance.debugDesktopBgTimer;
      expect(firstTimer, isNotNull);
      expect(firstTimer!.isActive, isTrue);

      // Re-enabling replaces (not stacks) the timer and stays channel-free:
      // the first timer must be cancelled and a distinct one armed.
      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 2),
      );
      expect(calls, isEmpty);
      final secondTimer = TrustedTimeImpl.instance.debugDesktopBgTimer;
      expect(secondTimer, isNotNull);
      expect(secondTimer, isNot(same(firstTimer)));
      expect(firstTimer.isActive, isFalse);
      expect(secondTimer!.isActive, isTrue);
    });

    test(
      'swallows native scheduler errors instead of surfacing them',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        var schedulerInvoked = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(bgChannel, (call) async {
              schedulerInvoked = true;
              throw PlatformException(code: 'SCHEDULER_UNAVAILABLE');
            });

        await expectLater(
          public_api.TrustedTime.enableBackgroundSync(
            interval: const Duration(hours: 24),
          ),
          completes,
        );

        // Distinguishes "error swallowed" from "never tried to schedule":
        // the native scheduler must have been reached before the error
        // was absorbed.
        expect(schedulerInvoked, isTrue);
      },
    );

    test('is a no-op under an active test override (no channel call, '
        'no timer)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final mock = public_api.TrustedTimeMock(
        initial: DateTime.utc(2026, 6, 1, 12),
      );
      public_api.TrustedTime.overrideForTesting(mock);
      addTearDown(() {
        public_api.TrustedTime.resetOverride();
        mock.dispose();
      });

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 24),
      );

      expect(calls, isEmpty);
      expect(TrustedTimeImpl.instance.debugDesktopBgTimer, isNull);
    });
  });
}

/// Builds a network-free config whose only sources are the injected fakes.
///
/// [ntsServers] defaults to empty so the config stays fully offline. The
/// y81 regression tests pass a non-empty list to exercise the NTS bootstrap
/// gate; the injected fakes still supply quorum, and any real [NtsSource]
/// built from [ntsServers] is caught per-source by the engine (it throws
/// "not initialised") without aborting the cycle.
TrustedTimeConfig _offlineConfig({
  required List<TimeSource> sources,
  bool persistState = true,
  List<String> ntsServers = const [],
}) => TrustedTimeConfig(
  ntpServers: const [],
  httpsSources: const [],
  ntsServers: ntsServers,
  minimumQuorum: 2,
  persistState: persistState,
  additionalSources: sources,
);

class _FakeMonotonicClock implements MonotonicClock {
  _FakeMonotonicClock(this.value);
  final int value;
  @override
  Future<int> uptimeMs() async => value;
}

/// A deterministic [TimeSource] centred on a fixed UTC instant with a
/// ±15ms uncertainty interval, optionally scripted to throw — always
/// ([shouldThrow]) or for the first [failuresBeforeSuccess] queries only
/// (modelling a transient outage that recovers, e.g. a just-woken radio).
class _FakeSource implements TimeSource {
  _FakeSource({
    required this.idValue,
    required this.groupIdValue,
    required this.utc,
    this.shouldThrow = false,
    this.failuresBeforeSuccess = 0,
  });

  final String idValue;
  final String groupIdValue;
  final DateTime utc;
  final bool shouldThrow;
  final int failuresBeforeSuccess;

  /// Total [getTime] invocations, across engine instances.
  int calls = 0;

  @override
  String get id => idValue;

  @override
  String get groupId => groupIdValue;

  @override
  Future<TimeSample> getTime() async {
    calls++;
    if (shouldThrow || calls <= failuresBeforeSuccess) {
      throw Exception('source down');
    }
    final mid = utc.millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(startMs: mid - 15, endMs: mid + 15),
      sourceId: idValue,
      groupId: groupIdValue,
      delayMs: 30,
    );
  }
}

@pragma('vm:entry-point')
void _registerableTopLevelCallback() {}
