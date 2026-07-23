import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/infra/trusted_time_log.dart'
    show TrustedTimeLog, TrustedTimeLogLevel;
import 'package:trusted_time/trusted_time.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock secure storage MethodChannel.
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'read') return null;
        return null;
      });

  // Mock monotonic uptime channel.
  const monotonicChannel = MethodChannel('trusted_time/monotonic');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 1000;
        return null;
      });

  // Mock background task channel.
  const backgroundChannel = MethodChannel('trusted_time/background');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(backgroundChannel, (call) async {
        return null;
      });

  group('TrustedTime V2 Senior Rewrite Test Suite', () {
    late DateTime baseTime;
    late TrustedTimeMock mock;

    setUp(() {
      baseTime = DateTime.utc(2024, 1, 1, 12, 0, 0);
      mock = TrustedTimeMock(initial: baseTime);
      TrustedTime.overrideForTesting(mock);
    });

    tearDown(TrustedTime.resetOverride);

    test('getAssessment() returns exactly the mocked UTC time', () {
      final assessment = TrustedTime.getAssessment();
      expect(assessment.time, baseTime);
      expect(assessment.time!.millisecondsSinceEpoch, 1704110400000);
      expect(assessment.isTrusted, isTrue);
    });

    test('advanceTime() shifts the assessed time', () {
      mock.advanceTime(const Duration(seconds: 45));
      expect(
        TrustedTime.getAssessment().time,
        baseTime.add(const Duration(seconds: 45)),
      );
    });

    test('Trust Loss: setTrusted(false) yields an unanchored assessment', () {
      mock.setTrusted(false);

      final assessment = TrustedTime.getAssessment();
      expect(assessment.isTrusted, isFalse);
      expect(assessment.time, isNull);
      expect(assessment.reason, TrustStatusReason.syncFailed);
      expect(assessment.authLevel, NtsAuthLevel.none);
      expect(assessment.confidence, ConfidenceLevel.none);
    });

    test('Auth posture: verified anchors report synchronized, '
        'unauthenticated anchors report degraded', () {
      expect(TrustedTime.getAssessment().reason, TrustStatusReason.degraded);
      expect(TrustedTime.getAssessment().isSecure, isFalse);

      mock.setAuthLevel(NtsAuthLevel.verified);

      final assessment = TrustedTime.getAssessment();
      expect(assessment.reason, TrustStatusReason.synchronized);
      expect(assessment.isSecure, isTrue);
    });

    test('Offline Best-Effort: estimate decays confidence over 72h', () {
      mock.simulateReboot(); // Lose trust to enable estimation paths.

      final estimate = TrustedTime.getAssessment().estimate;
      expect(estimate, isNotNull);
      expect(
        estimate!.confidence,
        1.0,
      ); // No time elapsed yet since "mocked" reboot.
      expect(estimate.isReasonable, isTrue);

      // Advance virtual clock by 36 hours (half of 72h).
      mock.advanceTime(const Duration(hours: 36));
      final estimate36h = TrustedTime.getAssessment().estimate!;
      expect(estimate36h.confidence, closeTo(0.5, 0.01));
      expect(estimate36h.isReasonable, isTrue);

      // Advance past 72h.
      mock.advanceTime(const Duration(hours: 40));
      final estimate76h = TrustedTime.getAssessment().estimate!;
      expect(estimate76h.confidence, 0.0);
      expect(estimate76h.isReasonable, isFalse);
    });

    test(
      'Timezone-Proof: trustedLocalTimeIn() returns correct offsets',
      () async {
        // Initialize timezone database must happen during TrustedTime.initialize()
        // or manually for hermetic tests.
        await TrustedTime.initialize();

        // "America/New_York" on Jan 1st is UTC-5.
        final nycTime = TrustedTime.trustedLocalTimeIn('America/New_York');
        expect(nycTime.hour, 7); // 12:00 UTC - 5h = 07:00.
        expect(nycTime.minute, 0);

        // "Asia/Tokyo" on Jan 1st is UTC+9.
        final tokyoTime = TrustedTime.trustedLocalTimeIn('Asia/Tokyo');
        expect(tokyoTime.hour, 21); // 12:00 UTC + 9h = 21:00.
      },
    );

    test('initialize(onLog:) installs the process-global sink even when '
        'a mock short-circuits engine init', () async {
      final lines = <(TrustedTimeLogLevel, String)>[];
      await TrustedTime.initialize(
        onLog: (level, message) => lines.add((level, message)),
      );
      addTearDown(() => TrustedTimeLog.sink = null);

      TrustedTimeLog.log(TrustedTimeLogLevel.info, '[TrustedTime] probe');

      expect(lines, [(TrustedTimeLogLevel.info, '[TrustedTime] probe')]);
    });

    test('a throwing sink is contained by the router instead of '
        'propagating into engine flows', () {
      TrustedTimeLog.sink = (level, message) => throw StateError('sink bug');
      addTearDown(() => TrustedTimeLog.sink = null);

      expect(
        () => TrustedTimeLog.log(TrustedTimeLogLevel.info, '[TrustedTime] x'),
        returnsNormally,
      );
    });

    test('Exception: trustedLocalTimeIn() throws for unknown identifiers', () {
      expect(
        () => TrustedTime.trustedLocalTimeIn('Mars/Elon_City'),
        throwsA(isA<UnknownTimezoneException>()),
      );
    });

    test('Mock Restore: restoreTrust() resumes high-integrity baseline', () {
      mock.simulateReboot();
      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      expect(
        TrustedTime.getAssessment().reason,
        TrustStatusReason.rebootDetected,
      );
      mock.restoreTrust();
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
    });
  });
}
