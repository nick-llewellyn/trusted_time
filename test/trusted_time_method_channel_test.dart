import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('trusted_time/monotonic');

  group('PlatformMonotonicClock', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method == 'getUptimeMs') return 42000;
            if (methodCall.method == 'getBootId') return 'boot-uuid-1';
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('uptimeMs returns value from platform channel', () async {
      final clock = PlatformMonotonicClock();
      final result = await clock.uptimeMs();
      expect(result, 42000);
    });

    test('uptimeMs throws when platform returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async => null);

      final clock = PlatformMonotonicClock();
      expect(() => clock.uptimeMs(), throwsA(isA<StateError>()));
    });

    test('getBootId returns value from platform channel', () async {
      final clock = PlatformMonotonicClock();
      expect(await clock.getBootId(), 'boot-uuid-1');
    });

    test('getBootId returns null when platform returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method == 'getUptimeMs') return 42000;
            return null;
          });

      final clock = PlatformMonotonicClock();
      expect(await clock.getBootId(), isNull);
    });

    test('getBootId returns null when the platform throws '
        '(no boot-session concept)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method == 'getUptimeMs') return 42000;
            throw PlatformException(code: 'UNIMPLEMENTED');
          });

      final clock = PlatformMonotonicClock();
      expect(await clock.getBootId(), isNull);
    });

    test('getBootId returns null when no handler is registered '
        '(older host platform build)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final clock = PlatformMonotonicClock();
      expect(await clock.getBootId(), isNull);
    });

    test('uptimeMs prefers a sleep-aware reader over the channel', () async {
      var channelCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            channelCalls++;
            return 42000;
          });

      final clock = PlatformMonotonicClock(
        readerFactory: () =>
            const MonotonicReader(read: _read7500000, isSleepAware: true),
      );
      expect(await clock.uptimeMs(), 7500);
      expect(channelCalls, 0);
    });

    test('uptimeMs falls back to the channel when the reader is not '
        'sleep-aware', () async {
      var readerReads = 0;
      final clock = PlatformMonotonicClock(
        readerFactory: () => MonotonicReader(
          read: () {
            readerReads++;
            return 7500000;
          },
          isSleepAware: false,
        ),
      );
      expect(await clock.uptimeMs(), 42000);
      expect(readerReads, 0);
    });

    test('getBootId uses the channel even with a sleep-aware reader', () async {
      var bootIdCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method == 'getBootId') {
              bootIdCalls++;
              return 'boot-uuid-1';
            }
            return null;
          });

      var readerResolutions = 0;
      final clock = PlatformMonotonicClock(
        readerFactory: () {
          readerResolutions++;
          return const MonotonicReader(read: _read7500000, isSleepAware: true);
        },
      );
      expect(await clock.getBootId(), 'boot-uuid-1');
      expect(bootIdCalls, 1);
      expect(readerResolutions, 0);
    });
  });
}

int _read7500000() => 7500000;
