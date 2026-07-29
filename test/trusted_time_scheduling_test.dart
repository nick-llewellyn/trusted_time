import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/background_sync.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart' as public_api;

/// Coverage for the background-sync scheduling contract:
/// `TrustedTime.enableBackgroundSync` (native interval clamping and the
/// desktop in-isolate timer fallback) and
/// `TrustedTime.getBackgroundStopReason` (mapping platform replies onto
/// [BackgroundSyncStopInfo], including the best-effort null paths).
///
/// **Scope**: Dart-side only — no real OS scheduler is driven here. See
/// `trusted_time_background_test.dart` for the manual device recipes and
/// `background_sync_test.dart` for the `src`-level unit-of-work.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('maps the iOS expiration-breadcrumb reply shape', () async {
      // iOS reports a previous BGTask expiration as state=EXPIRED(<iso>)
      // with the TIMEOUT stop reason (see TrustedTimePlugin.swift's
      // getBackgroundStopReason branch); the Dart mapping is
      // shape-agnostic and must carry both values through unchanged.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getBackgroundStopReason');
            return {'state': 'EXPIRED(2026-07-07T17:14:05Z)', 'stopReason': 3};
          });

      final info = await public_api.TrustedTime.getBackgroundStopReason();
      expect(info, isNotNull);
      expect(info!.state, 'EXPIRED(2026-07-07T17:14:05Z)');
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

    test(
      'returns null when the platform reply has an unexpected shape',
      () async {
        // A List where a Map is expected makes invokeMapMethod's internal
        // cast throw a TypeError; the best-effort contract requires that
        // to surface as null rather than escaping to the caller.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => [1, 2, 3]);

        expect(await public_api.TrustedTime.getBackgroundStopReason(), isNull);
      },
    );

    test('returns null under an active TrustedTimeMock override', () async {
      final mock = public_api.TrustedTimeMock(initial: DateTime.utc(2026));
      public_api.TrustedTime.overrideForTesting(mock);
      addTearDown(public_api.TrustedTime.resetOverride);
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
      // A live engine is required so the public wrapper can reach
      // TrustedTimeImpl.instance. Empty source pools keep the bootstrap
      // sync network-free (it fails quorum, which initialize tolerates),
      // and backgroundSyncInterval stays null so no scheduling happens
      // until the test drives it explicitly.
      await public_api.TrustedTime.initialize(
        config: const public_api.TrustedTimeConfig(
          ntpServers: [],
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

    test('rounds leftover seconds up to the next whole minute', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(minutes: 15, seconds: 59),
      );

      // Truncation would yield 15 and schedule *more* frequently than
      // requested; battery-sensitive OS work must round up instead.
      expect(calls.single.arguments, {'intervalMinutes': 16});
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
      addTearDown(public_api.TrustedTime.resetOverride);

      await public_api.TrustedTime.enableBackgroundSync(
        interval: const Duration(hours: 24),
      );

      expect(calls, isEmpty);
      expect(TrustedTimeImpl.instance.debugDesktopBgTimer, isNull);
    });
  });
}
