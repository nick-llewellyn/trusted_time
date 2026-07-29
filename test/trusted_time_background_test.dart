import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/background_sync.dart';
import 'package:trusted_time/trusted_time.dart' as public_api;

import 'support/fake_sources.dart';
import 'support/offline_config.dart';

/// Coverage for the public-API entry points into a background sync:
/// `TrustedTime.registerBackgroundCallback` (callback-handle plumbing
/// over the `trusted_time/background` channel) and
/// `TrustedTime.runBackgroundSync` (the facade around the headless
/// unit-of-work, including the `notifyBackgroundComplete` signal).
///
/// **Scope**: these tests pin the Dart-side contract only. They do not
/// drive the real OS scheduler because that requires a device and is
/// platform-specific. To exercise the real OS scheduler manually:
///
/// - Android: `adb shell cmd jobscheduler run -f [package] [jobId]`
///   against a debug-built host app, then inspect logs for the
///   `notifyBackgroundComplete` channel call.
/// - iOS: in Xcode with the simulator paused, run
///   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
///   _simulateLaunchForTaskWithIdentifier:@"com.trustedtime.backgroundsync"]`
///   and observe the headless engine spinning up.
///
/// The `src`-level unit-of-work itself is covered by
/// `background_sync_test.dart`; scheduling and stop-reason reporting by
/// `trusted_time_scheduling_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          config: offlineConfig(
            persistState: false,
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
        config: offlineConfig(
          persistState: false,
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
      // desktop behaviour). The public API must still return the
      // sync result instead of propagating the channel error.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: offlineConfig(
          persistState: false,
          sources: [
            FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
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
      addTearDown(public_api.TrustedTime.resetOverride);

      final result = await public_api.TrustedTime.runBackgroundSync(
        config: offlineConfig(
          persistState: false,
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
        config: offlineConfig(
          persistState: false,
          sources: [
            FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
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
        config: offlineConfig(
          persistState: false,
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
        onResult: (r) async => observed = r,
        retryDelays: const [],
      );
      expect(result, isA<BackgroundSyncFailure>());
      expect(observed, same(result));
    });

    test('a throwing onResult hook is swallowed: sync outcome and '
        'completion signal are unaffected', () async {
      final result = await public_api.TrustedTime.runBackgroundSync(
        config: offlineConfig(
          persistState: false,
          sources: [
            FakeSource(idValue: 'a', groupIdValue: 'g1', utc: consensusUtc),
            FakeSource(idValue: 'b', groupIdValue: 'g2', utc: consensusUtc),
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
      addTearDown(public_api.TrustedTime.resetOverride);

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
}

@pragma('vm:entry-point')
void _registerableTopLevelCallback() {}
