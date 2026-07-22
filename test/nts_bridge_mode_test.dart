// Bridge-mode counterpart to the fallback coverage in
// sync_clock_test.dart and trusted_time_impl_test.dart.
//
// nts 7.0.0 removed the silent Stopwatch fallback for uninitialized
// processes: touching nts.MonotonicClock.instance (or constructing
// NtsSyncedTime) before NtsRustLib.init()/initMock() throws
// StateError. trusted_time's resolveMonotonicReader gates on the
// non-throwing `initialized` signal, so the rest of the suite runs
// bridge-less and deterministically exercises the suspend-frozen
// fallback — leaving the sleep-aware branch untested.
//
// This file is the one isolate where the bridge IS initialized:
// setUpAll installs NtsRustLib.initMock with an API that stubs
// crateApiNtsNtsBoottimeMicros, so nts's structural mock-mode probe
// selects the boottime path (not its own Stopwatch degradation) and
// every default resolution below rides the controllable stub. Bridge
// init is one-way per isolate (initMock throws on double-init and
// MonotonicClock.instance latches), which is why this cannot live in
// the files that assert fallback behaviour.
//
// NtsRustLibApi is intentionally not in nts's public barrel; stubbing
// it requires the implementation import below — the same pattern as
// package:nts's own example/lib/src/mock_api.dart.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:nts/src/ffi/frb_generated.dart' show NtsRustLibApi;
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

/// Minimal mock bridge API: stubs the boottime clock read, rejects
/// everything else so an unexpected FFI touch fails loudly instead of
/// silently returning garbage.
final class _BoottimeStubApi implements NtsRustLibApi {
  int nowMicros = 7 * 1000 * 1000;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Match the generated signature exactly (a zero-argument method
    // call): if a future regeneration adds parameters, the stub must
    // fail fast rather than silently accept the mismatched shape.
    if (invocation.memberName == #crateApiNtsNtsBoottimeMicros &&
        invocation.isMethod &&
        invocation.positionalArguments.isEmpty &&
        invocation.namedArguments.isEmpty) {
      return nowMicros;
    }
    throw UnsupportedError(
      '_BoottimeStubApi: ${invocation.memberName} not stubbed '
      '(or called with an unexpected shape)',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = _BoottimeStubApi();

  setUpAll(() => nts.NtsRustLib.initMock(api: api));

  setUp(() => api.nowMicros = 7 * 1000 * 1000);

  group('resolveMonotonicReader under an initialized bridge', () {
    test('resolves the sleep-aware bridge reader riding the stub', () {
      final reader = resolveMonotonicReader();
      expect(reader.isSleepAware, isTrue);
      expect(reader.read(), api.nowMicros);
    });

    test('readings advance across a simulated suspend', () {
      // CLOCK_BOOTTIME keeps counting through deep sleep; the stub
      // models a 2-hour suspend as a jump a Stopwatch would never show.
      final reader = resolveMonotonicReader();
      final before = reader.read();
      api.nowMicros += const Duration(hours: 2).inMicroseconds;
      expect(reader.read() - before, const Duration(hours: 2).inMicroseconds);
    });
  });

  group('PlatformMonotonicClock under an initialized bridge', () {
    // "Never touches the channel" must not depend on no handler being
    // installed — another file leaking a trusted_time/monotonic
    // handler would turn that into a silent false positive. Install a
    // handler that fails on any call, and clear it so this file leaks
    // nothing in turn.
    const monotonicChannel = MethodChannel('trusted_time/monotonic');

    setUpAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(monotonicChannel, (call) async {
            fail(
              'uptimeMs must ride the bridge; unexpected '
              'trusted_time/monotonic call: ${call.method}',
            );
          });
    });

    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(monotonicChannel, null);
    });

    test('uptimeMs reads the bridge, never the method channel', () async {
      final clock = PlatformMonotonicClock();
      expect(await clock.uptimeMs(), api.nowMicros ~/ 1000);
    });

    test('uptimeMs keeps counting across a simulated suspend', () async {
      final clock = PlatformMonotonicClock();
      final before = await clock.uptimeMs();
      api.nowMicros += const Duration(minutes: 30).inMicroseconds;
      expect(
        await clock.uptimeMs() - before,
        const Duration(minutes: 30).inMilliseconds,
      );
    });
  });

  group('SyncClock under an initialized bridge', () {
    test('default resolution is sleep-aware', () {
      final clock = SyncClock();
      addTearDown(clock.dispose);
      expect(clock.isSleepAware, isTrue);
    });

    test('projection includes time spent suspended', () {
      final clock = SyncClock();
      addTearDown(clock.dispose);
      clock.update(1000, DateTime.utc(2026, 3, 1).millisecondsSinceEpoch);
      api.nowMicros += const Duration(hours: 2).inMicroseconds;
      expect(
        clock.elapsedSinceAnchorMs(),
        const Duration(hours: 2).inMilliseconds,
      );
    });
  });

  group('TrustedTime.initialize under an initialized bridge', () {
    // initialize() touches secure storage teardown paths even with
    // persistState: false; a null-returning handler keeps the test
    // hermetic. Cleared in tearDownAll — leaked handlers race with
    // other files on the same channel (see security_policy_test.dart).
    const storageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );

    setUpAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async => null);
    });

    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, null);
    });

    test('requireSleepAwareProjection passes the fail-fast gate', () async {
      // The mirror of trusted_time_impl_test.dart's fallback test,
      // where this exact config throws TrustedTimeSecurityException.
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
          requireSleepAwareProjection: true,
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);

      expect(TrustedTime.isProjectionSleepAware, isTrue);
    });
  });

  group('TimeSample.monotonicReceiptNowMs under an initialized bridge', () {
    // The receipt timeline latches its reader at first stamp; unlatch
    // around each test so the stamp below re-resolves against the
    // stub with a fresh origin, regardless of what earlier tests in
    // this isolate may have latched.
    setUp(() => TimeSample.debugSetReceiptReader(null));
    tearDown(() => TimeSample.debugSetReceiptReader(null));

    test('stamps ride the bridge timeline, sleep included', () {
      expect(TimeSample.monotonicReceiptNowMs(), 0);
      api.nowMicros += const Duration(hours: 1).inMicroseconds;
      expect(
        TimeSample.monotonicReceiptNowMs(),
        const Duration(hours: 1).inMilliseconds,
      );
    });
  });
}
