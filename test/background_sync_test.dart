import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/background_sync.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/trusted_time.dart' as public_api;

class _FakeMonotonicClock implements MonotonicClock {
  _FakeMonotonicClock(this.value);
  final int value;
  @override
  Future<int> uptimeMs() async => value;
}

class _FakeSource implements TrustedTimeSource {
  _FakeSource({
    required this.idValue,
    required this.utc,
    this.shouldThrow = false,
  });

  final String idValue;
  final DateTime utc;
  final Duration rtt = const Duration(milliseconds: 30);
  final bool shouldThrow;

  @override
  String get id => idValue;

  @override
  Future<TimeSample> fetch() async {
    if (shouldThrow) throw Exception('source down');
    return TimeSample(
      networkUtc: utc,
      roundTripTime: rtt,
      uncertainty: Duration(milliseconds: rtt.inMilliseconds ~/ 2),
      capturedMonotonicMs: 5000,
      source: TimeSourceMetadata(kind: TimeSourceKind.custom, id: idValue),
      capturedAt: DateTime.now().toUtc(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runBackgroundSync', () {
    final consensusUtc = DateTime.utc(2026, 1, 15, 10);
    final config = TrustedTimeConfig(
      ntpServers: const [],
      httpsSources: const [],
      ntsServers: const [],
      minimumQuorum: 2,
      additionalSources: [
        _FakeSource(idValue: 'fake-a', utc: consensusUtc),
        _FakeSource(
          idValue: 'fake-b',
          utc: consensusUtc.add(const Duration(milliseconds: 5)),
        ),
      ],
    );

    test('persists fresh anchor when sync succeeds', () async {
      final store = InMemoryAnchorStorage();
      final result = await runBackgroundSync(
        config: config,
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
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          additionalSources: [
            _FakeSource(idValue: 'a', utc: consensusUtc, shouldThrow: true),
            _FakeSource(idValue: 'b', utc: consensusUtc, shouldThrow: true),
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
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          persistState: false,
          additionalSources: [
            _FakeSource(idValue: 'a', utc: consensusUtc),
            _FakeSource(idValue: 'b', utc: consensusUtc),
          ],
        ),
        store: store,
        clock: _FakeMonotonicClock(5000),
      );
      expect(result, isA<BackgroundSyncSuccess>());
      expect(await store.load(), isNull);
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
      // desktop/web so the platform short-circuit fires before
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
    final consensusUtc = DateTime.utc(2026, 1, 15, 10);
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'notifies native of completion with success=true on a passing run',
      () async {
        final result = await public_api.TrustedTime.runBackgroundSync(
          config: TrustedTimeConfig(
            ntpServers: const [],
            httpsSources: const [],
            ntsServers: const [],
            minimumQuorum: 2,
            // persistState=false so the run does not touch real
            // flutter_secure_storage from the test process.
            persistState: false,
            additionalSources: [
              _FakeSource(idValue: 'fake-a', utc: consensusUtc),
              _FakeSource(
                idValue: 'fake-b',
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
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          persistState: false,
          additionalSources: [
            _FakeSource(idValue: 'a', utc: consensusUtc, shouldThrow: true),
            _FakeSource(idValue: 'b', utc: consensusUtc, shouldThrow: true),
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
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          persistState: false,
          additionalSources: [
            _FakeSource(idValue: 'a', utc: consensusUtc),
            _FakeSource(idValue: 'b', utc: consensusUtc),
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
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          persistState: false,
          additionalSources: [
            _FakeSource(idValue: 'a', utc: consensusUtc, shouldThrow: true),
            _FakeSource(idValue: 'b', utc: consensusUtc, shouldThrow: true),
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
}

@pragma('vm:entry-point')
void _registerableTopLevelCallback() {}
