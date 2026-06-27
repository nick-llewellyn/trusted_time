import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

/// A [TimeSource] with a fully specified interval, auth level, and trust
/// backend so the tiered-trust admission path can be driven deterministically
/// through the real engine.
///
/// The mock override forces `isSecure == false` unconditionally, so the
/// `verified` (non-throwing) branch of [TrustedTime.getTime] is only reachable
/// by establishing a real anchor through a live sync — hence these sources.
class _TierSource implements TimeSource {
  _TierSource({
    required this.id,
    required this.groupId,
    required this.startMs,
    required this.endMs,
    this.authLevel = NtsAuthLevel.none,
    this.trustBackend,
  });

  @override
  final String id;
  @override
  final String groupId;
  final int startMs;
  final int endMs;
  final NtsAuthLevel authLevel;
  final TrustBackend? trustBackend;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: startMs, endMs: endMs),
    sourceId: id,
    groupId: groupId,
    authLevel: authLevel,
    trustBackend: trustBackend,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The live-engine group drives the real TrustedTimeImpl singleton; stub the
  // platform channels it touches during initialize() so the harness stays
  // fully offline and deterministic.
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storageChannel, (call) async => null);

  const monotonicChannel = MethodChannel('trusted_time/monotonic');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 1000;
        return null;
      });

  const backgroundChannel = MethodChannel('trusted_time/background');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(backgroundChannel, (call) async => null);

  const integrityChannel = MethodChannel('trusted_time/integrity');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(integrityChannel, (call) async => null);

  group('Security Policy Enforcement (CRITICAL-4, 5)', () {
    test('getTime(requireSecure: true) fails when authLevel is none', () async {
      final mock = TrustedTimeMock(initial: DateTime.now());
      mock.setTrusted(true);
      mock.setAuthLevel(NtsAuthLevel.none);

      TrustedTime.overrideForTesting(mock);

      expect(
        () => TrustedTime.getTime(requireSecure: true),
        throwsA(isA<TrustedTimeSecurityException>()),
      );

      TrustedTime.resetOverride();
    });

    test('isSecure returns false for none authLevel', () {
      final mock = TrustedTimeMock(initial: DateTime.now());
      mock.setAuthLevel(NtsAuthLevel.none);
      TrustedTime.overrideForTesting(mock);

      expect(TrustedTime.isSecure, isFalse);

      TrustedTime.resetOverride();
    });
  });

  group('Secure Time Contract — requireSecure (live engine)', () {
    // Drop into the real TrustedTimeImpl singleton: clear any override a
    // sibling group may have left set *before* each test, otherwise
    // initialize() short-circuits and never exercises the real engine.
    setUp(TrustedTime.resetOverride);
    tearDown(TrustedTime.resetOverride);

    Future<void> initWith(List<TimeSource> sources) async {
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          persistState: false,
          minimumQuorum: 2,
          minGroupCount: 1,
          earlyExit: false,
          usePlatformTrust: false,
        ).copyWith(additionalSources: sources),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
    }

    test('verified Tier 1 truth box: getTime(requireSecure: true) returns '
        'without throwing', () async {
      // Two verified NTS samples overlap -> a Tier 1 truth box -> the
      // anchor is verified, so the secure contract is satisfied.
      await initWith([
        _TierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: TrustBackend.webpkiRoots,
        ),
        _TierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 1005,
          endMs: 1025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: TrustBackend.webpkiRoots,
        ),
      ]);

      expect(TrustedTime.authLevel, NtsAuthLevel.verified);
      expect(TrustedTime.isSecure, isTrue);
      expect(TrustedTime.getTime(requireSecure: true), isA<DateTime>());
    });

    test('zero Tier 1 samples (degraded): getTime(requireSecure: true) throws '
        'with the library-controlled-trust-store message', () async {
      // Quorum is reached, but no sample is verified -> the anchor degrades
      // to NtsAuthLevel.none and the secure contract fails closed.
      await initWith([
        _TierSource(
          id: 'nts:platform',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          trustBackend: TrustBackend.platform,
        ),
        _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        _TierSource(id: 'ntp:c', groupId: 'g3', startMs: 1000, endMs: 1020),
      ]);

      expect(TrustedTime.authLevel, NtsAuthLevel.none);
      expect(TrustedTime.isSecure, isFalse);
      expect(
        () => TrustedTime.getTime(requireSecure: true),
        throwsA(
          isA<TrustedTimeSecurityException>().having(
            (e) => e.message,
            'message',
            contains('library-controlled trust store'),
          ),
        ),
      );
    });

    test('unverified anchor keeps getTime(requireSecure: true) fail-closed '
        'across resync cycles', () async {
      // None of the injected samples are verified, so the anchor stays
      // NtsAuthLevel.none and requireSecure fails closed on every cycle.
      await initWith([
        _TierSource(
          id: 'nts:platform',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          trustBackend: TrustBackend.platform,
        ),
        _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
      ]);

      for (var cycle = 0; cycle < 3; cycle++) {
        expect(TrustedTime.isSecure, isFalse, reason: 'cycle $cycle');
        expect(
          () => TrustedTime.getTime(requireSecure: true),
          throwsA(isA<TrustedTimeSecurityException>()),
          reason: 'cycle $cycle',
        );
        await TrustedTime.forceResync();
      }
    });
  });
}
