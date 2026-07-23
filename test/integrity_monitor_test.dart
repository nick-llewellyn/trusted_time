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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('dispose can be called multiple times safely', () {
      monitor.dispose();
      expect(() => monitor.dispose(), returnsNormally);
    });
  });
}
