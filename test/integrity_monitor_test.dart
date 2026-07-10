import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/integrity_monitor.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

class FakeMonotonicClock implements MonotonicClock {
  int value = 1000;
  String? bootId = 'boot-A';
  int bootIdCalls = 0;
  @override
  Future<int> uptimeMs() async => value;
  @override
  Future<String?> getBootId() async {
    bootIdCalls++;
    return bootId;
  }
}

/// A clock whose [uptimeMs] blocks on [gate] (when set) so a test can
/// suspend an in-flight drift check and tear the monitor down mid-await.
class GatedMonotonicClock implements MonotonicClock {
  int value = 1000;
  int uptimeCalls = 0;
  Completer<void>? gate;

  @override
  Future<int> uptimeMs() async {
    uptimeCalls++;
    final pending = gate;
    if (pending != null) await pending.future;
    return value;
  }

  @override
  Future<String?> getBootId() async => 'boot-A';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // EventChannel uses MethodChannel under the hood for listen/cancel.
  // In test mode we mock the underlying MethodChannel so that calling
  // attach() (which calls receiveBroadcastStream()) doesn't throw
  // MissingPluginException. This does NOT simulate native event delivery
  // — it only allows the Dart-side logic to be tested in isolation.
  const integrityChannel = MethodChannel('trusted_time/integrity');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(integrityChannel, (call) async => null);

  group('IntegrityMonitor', () {
    late FakeMonotonicClock clock;
    late IntegrityMonitor monitor;

    setUp(() {
      clock = FakeMonotonicClock();
      monitor = IntegrityMonitor(clock: clock);
    });

    tearDown(() => monitor.dispose());

    test(
      'checkRebootOnWarmStart detects reboot when uptime < anchor',
      () async {
        clock.value = 500;
        final anchor = TrustAnchor(
          networkUtcMs: DateTime.now().millisecondsSinceEpoch,
          uptimeMs: 10000,
          wallMs: DateTime.now().millisecondsSinceEpoch,
          uncertaintyMs: 10,
          bootId: 'boot-A',
        );
        final result = await monitor.checkRebootOnWarmStart(anchor);
        expect(result.rebooted, isTrue);
        expect(result.currentUptimeMs, 500);
        // Uptime regression alone decides the verdict; the boot-ID
        // IPC round-trip is skipped entirely.
        expect(clock.bootIdCalls, 0);
      },
    );

    test('checkRebootOnWarmStart returns false when uptime >= anchor '
        'and boot identity matches', () async {
      clock.value = 20000;
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 10000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
        bootId: 'boot-A',
      );
      final result = await monitor.checkRebootOnWarmStart(anchor);
      expect(result.rebooted, isFalse);
      expect(result.currentUptimeMs, 20000);
      // Exactly one identity fetch: the happy path costs a single
      // boot-ID IPC call, no more.
      expect(clock.bootIdCalls, 1);
    });

    test(
      'checkRebootOnWarmStart detects reboot on boot-identity mismatch '
      'even when uptime has surpassed the anchor (wait-out attack)',
      () async {
        // Wait-out attack shape: the device rebooted (new boot ID) and
        // was left powered on until its uptime exceeded the anchor's
        // recorded value, so the legacy inequality alone would pass.
        clock.value = 50000;
        clock.bootId = 'boot-B';
        final anchor = TrustAnchor(
          networkUtcMs: DateTime.now().millisecondsSinceEpoch,
          uptimeMs: 10000,
          wallMs: DateTime.now().millisecondsSinceEpoch,
          uncertaintyMs: 10,
          bootId: 'boot-A',
        );
        final result = await monitor.checkRebootOnWarmStart(anchor);
        expect(result.rebooted, isTrue);
        expect(result.currentUptimeMs, 50000);
      },
    );

    test(
      'checkRebootOnWarmStart fails closed when the anchor has no bootId',
      () async {
        // Anchors persisted before boot-ID binding (or from a platform
        // that could not supply one) must be treated as rebooted. The
        // verdict is decided without fetching the current boot ID: a
        // null anchor identity can never match, so the IPC call is
        // skipped.
        clock.value = 50000;
        final anchor = TrustAnchor(
          networkUtcMs: DateTime.now().millisecondsSinceEpoch,
          uptimeMs: 10000,
          wallMs: DateTime.now().millisecondsSinceEpoch,
          uncertaintyMs: 10,
        );
        final result = await monitor.checkRebootOnWarmStart(anchor);
        expect(result.rebooted, isTrue);
        expect(clock.bootIdCalls, 0);
      },
    );

    test('checkRebootOnWarmStart fails closed when the platform cannot '
        'supply a current boot ID', () async {
      clock.value = 50000;
      clock.bootId = null;
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 10000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
        bootId: 'boot-A',
      );
      final result = await monitor.checkRebootOnWarmStart(anchor);
      expect(result.rebooted, isTrue);
    });

    test('checkRebootOnWarmStart returns the freshly-sampled uptime '
        'so callers can compute the warm-restore gap without a second '
        'platform-channel call', () async {
      clock.value = 75000;
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 15000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
        bootId: 'boot-A',
      );
      final result = await monitor.checkRebootOnWarmStart(anchor);
      expect(result.rebooted, isFalse);
      // Caller can compute (currentUptimeMs - anchor.uptimeMs) directly
      // — no need for a second monitor.uptimeMs() round-trip.
      expect(result.currentUptimeMs - anchor.uptimeMs, 60000);
    });

    test('events stream is a broadcast stream', () {
      expect(monitor.events.isBroadcast, isTrue);
    });

    test('attach establishes monitoring without throwing', () {
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
      );
      expect(() => monitor.attach(anchor), returnsNormally);
    });

    test('multiple attaches cancel previous subscription', () {
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
      );
      expect(() {
        monitor.attach(anchor);
        monitor.attach(anchor);
      }, returnsNormally);
    });

    test('dispose can be called multiple times safely', () {
      monitor.dispose();
      expect(() => monitor.dispose(), returnsNormally);
    });

    test('a drift check resolving after dispose does not resurrect the '
        'timer (dispose-during-await race)', () async {
      final gate = Completer<void>();
      final gatedClock = GatedMonotonicClock()..gate = gate;
      final racing = IntegrityMonitor(clock: gatedClock);
      // Resilient to an early failure before the explicit dispose() below;
      // dispose() is idempotent, so the duplicate teardown is harmless and
      // it prevents leaking a live drift timer into later tests.
      addTearDown(racing.dispose);
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
      );
      racing.attach(anchor);
      expect(racing.debugDriftTimerActive, isTrue);

      // Start a cycle; it suspends on the gated platform-clock read.
      final cycle = racing.debugRunAdaptiveDriftCheck();
      // Tear down while that await is in flight.
      racing.dispose();
      expect(racing.debugDriftTimerActive, isFalse);

      // Let the suspended cycle resume now that the monitor is disposed.
      gate.complete();
      await cycle;

      // The disposed monitor must not have armed a fresh drift timer.
      expect(racing.debugDriftTimerActive, isFalse);
    });

    test('attach after dispose is a no-op (no surveillance resurrection)', () {
      monitor.dispose();
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
      );
      // attach() must short-circuit on a disposed monitor: no native
      // subscription is opened and no drift timer is armed, so nothing leaks
      // past the (idempotent) dispose() above.
      monitor.attach(anchor);
      expect(monitor.debugDriftTimerActive, isFalse);
    });
  });
}
