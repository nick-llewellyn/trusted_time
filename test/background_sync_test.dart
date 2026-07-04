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
      expect(await store.load(), isNull);
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
      );
      expect(result.isSuccess, isFalse);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'notifyBackgroundComplete');
      final args = calls.single.arguments as Map;
      expect(args['success'], isFalse);
      expect(args['reason'], isA<String>());
      expect((args['reason'] as String).isNotEmpty, isTrue);
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

    test('forwards intervalHours to the native scheduler on Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 24),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'enableBackgroundSync');
      expect(calls.single.arguments, {'intervalHours': 24});
      expect(TrustedTimeImpl.instance.debugDesktopBgTimer, isNull);
    });

    test('routes iOS through the native scheduler as well', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 12),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'enableBackgroundSync');
      expect(calls.single.arguments, {'intervalHours': 12});
      expect(TrustedTimeImpl.instance.debugDesktopBgTimer, isNull);
    });

    test('clamps sub-hour intervals up to 1 hour for the native '
        'scheduler', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(minutes: 30),
      );

      expect(calls.single.arguments, {'intervalHours': 1});
    });

    test('clamps intervals above one week down to 168 hours', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 400),
      );

      expect(calls.single.arguments, {'intervalHours': 168});
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
/// ±15ms uncertainty interval, optionally scripted to throw.
class _FakeSource implements TimeSource {
  _FakeSource({
    required this.idValue,
    required this.groupIdValue,
    required this.utc,
    this.shouldThrow = false,
  });

  final String idValue;
  final String groupIdValue;
  final DateTime utc;
  final bool shouldThrow;

  @override
  String get id => idValue;

  @override
  String get groupId => groupIdValue;

  @override
  Future<TimeSample> getTime() async {
    if (shouldThrow) throw Exception('source down');
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
