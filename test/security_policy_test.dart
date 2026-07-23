import 'dart:async';
import 'dart:convert';

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
  //
  // Flutter tests share one process, so install these handlers in setUpAll and
  // clear them (set to null) in tearDownAll. Leaving them installed past this
  // file would leak into — and race with — other test files that set handlers
  // on the same channels, causing order-dependent flakiness.
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const monotonicChannel = MethodChannel('trusted_time/monotonic');
  const backgroundChannel = MethodChannel('trusted_time/background');

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(storageChannel, (call) async => null);
    messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
      if (call.method == 'getUptimeMs') return 1000;
      return null;
    });
    messenger.setMockMethodCallHandler(backgroundChannel, (call) async => null);
  });

  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockMethodCallHandler(monotonicChannel, null);
    messenger.setMockMethodCallHandler(backgroundChannel, null);
  });

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

  group('requireSecure edge cases (trusted_time-ejv)', () {
    setUp(TrustedTime.resetOverride);
    tearDown(TrustedTime.resetOverride);

    Future<void> initWith(
      List<TimeSource> sources, {
      bool persistState = false,
    }) async {
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          persistState: persistState,
          minimumQuorum: 2,
          minGroupCount: 1,
          earlyExit: false,
          usePlatformTrust: false,
        ).copyWith(additionalSources: sources),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
    }

    group('edge 1: stale-but-cached verified anchor (warm restore)', () {
      // requireSecure gates *authentication*, not freshness: a persisted
      // verified anchor warm-restored within the same boot session
      // satisfies requireSecure: true regardless of its age. There is no
      // freshness window on this path by design — staleness is the
      // responsibility of confidenceScore / validateFreshness / the
      // refresh scheduler, per the Secure Time Contract's separation of
      // authentication and accuracy.
      final staleUtc = DateTime.utc(2023, 1, 1).millisecondsSinceEpoch;
      final staleVerifiedAnchorJson = jsonEncode(
        TrustAnchor(
          networkUtcMs: staleUtc,
          uptimeMs: 500,
          wallMs: staleUtc,
          uncertaintyMs: 10,
          authLevel: NtsAuthLevel.verified,
          bootId: 'boot-A',
        ).toJson(),
      );

      setUp(() {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(storageChannel, (call) async {
          // Match the AnchorStore anchor key by stable prefix rather than
          // the exact versioned literal (currently tt_anchor_v2) so a key
          // version bump does not silently turn this into a cold start.
          // The prefix is unambiguous: the store's other keys live under
          // tt_last_*.
          final key = (call.arguments as Map)['key'] as String?;
          if (call.method == 'read' &&
              (key?.startsWith('tt_anchor_') ?? false)) {
            return staleVerifiedAnchorJson;
          }
          return null;
        });
        messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
          if (call.method == 'getUptimeMs') return 1000;
          if (call.method == 'getBootId') return 'boot-A';
          return null;
        });
      });

      tearDown(() {
        // Restore the file-level default handlers for sibling groups.
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          storageChannel,
          (call) async => null,
        );
        messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
          if (call.method == 'getUptimeMs') return 1000;
          return null;
        });
      });

      test('an aged verified anchor still satisfies requireSecure: true '
          '(no freshness window on the authentication gate)', () async {
        // No sources at all: the warm restore must satisfy the contract
        // without any network activity.
        await initWith(const [], persistState: true);

        expect(TrustedTime.isSecure, isTrue);
        expect(TrustedTime.authLevel, NtsAuthLevel.verified);
        final t = TrustedTime.getTime(requireSecure: true);
        // The returned time projects from the stale 2023 anchor,
        // proving the value came from the cache, not a fresh sync.
        expect(t.year, 2023);
      });
    });

    group('edge 2: only unauthenticated sources available', () {
      test(
        'unauthenticated consensus is not authenticated time: '
        'requireSecure: true rejects an unauthenticated-only anchor',
        () async {
          // Sources that reach quorum but carry no application-layer
          // signature over the timestamp: samples are unconditionally
          // NtsAuthLevel.none and the anchor degrades.
          await initWith([
            _TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
            _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
          ]);

          // Quorum was reached — best-effort time is available...
          expect(TrustedTime.isTrusted, isTrue);
          expect(TrustedTime.getTime(), isA<DateTime>());
          // ...but the anchor is degraded, so the secure path fails closed.
          expect(TrustedTime.authLevel, NtsAuthLevel.none);
          expect(TrustedTime.isSecure, isFalse);
          expect(
            () => TrustedTime.getTime(requireSecure: true),
            throwsA(isA<TrustedTimeSecurityException>()),
          );
        },
      );
    });

    group('edge 3: mid-call NTS server flap', () {
      test('flap to full outage: the retained verified anchor cannot be '
          'served while trust is invalidated (fails via NotReady)', () async {
        final nts1 = _FlappableTierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: TrustBackend.webpkiRoots,
        );
        final nts2 = _FlappableTierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 1005,
          endMs: 1025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: TrustBackend.webpkiRoots,
        );
        await initWith([nts1, nts2]);
        expect(TrustedTime.getTime(requireSecure: true), isA<DateTime>());

        // Every NTS server becomes unreachable; the resync cycle fails.
        nts1.failing = true;
        nts2.failing = true;
        await TrustedTime.forceResync();

        // The stale anchor's verified label survives the failed cycle
        // (isSecure reflects the anchor, not the cycle)...
        expect(TrustedTime.isSecure, isTrue);
        // ...but trust was invalidated by forceResync, so the engine
        // refuses to project time from it. Fail-closed is preserved —
        // through TrustedTimeNotReadyException at the now() boundary
        // rather than TrustedTimeSecurityException at the auth gate.
        expect(TrustedTime.isTrusted, isFalse);
        expect(
          () => TrustedTime.getTime(requireSecure: true),
          throwsA(isA<TrustedTimeNotReadyException>()),
        );
      });

      test(
        'flap with unauthenticated survivors: the degraded replacement '
        'anchor fails requireSecure (no stale-verified carry-over)',
        () async {
          final nts1 = _FlappableTierSource(
            id: 'nts:v1',
            groupId: 'g1',
            startMs: 1000,
            endMs: 1020,
            authLevel: NtsAuthLevel.verified,
            trustBackend: TrustBackend.webpkiRoots,
          );
          final nts2 = _FlappableTierSource(
            id: 'nts:v2',
            groupId: 'g2',
            startMs: 1005,
            endMs: 1025,
            authLevel: NtsAuthLevel.verified,
            trustBackend: TrustBackend.webpkiRoots,
          );
          await initWith([
            nts1,
            nts2,
            _TierSource(id: 'ntp:a', groupId: 'g3', startMs: 1000, endMs: 1020),
            _TierSource(id: 'ntp:b', groupId: 'g4', startMs: 1005, endMs: 1025),
          ]);
          expect(TrustedTime.getTime(requireSecure: true), isA<DateTime>());

          // NTS flaps; NTP keeps answering, so the next cycle *succeeds*
          // as a degraded consensus and replaces the verified anchor.
          nts1.failing = true;
          nts2.failing = true;
          await TrustedTime.forceResync();

          expect(TrustedTime.isTrusted, isTrue);
          expect(TrustedTime.authLevel, NtsAuthLevel.none);
          expect(
            () => TrustedTime.getTime(requireSecure: true),
            throwsA(isA<TrustedTimeSecurityException>()),
          );
          // Best-effort callers keep working across the degradation.
          expect(TrustedTime.getTime(), isA<DateTime>());
        },
      );
    });

    group('edge 4: cold start with no cache and no network', () {
      test('initialize survives, requireSecure fails closed with '
          'SecurityException, and best-effort fails with NotReady', () async {
        final dead1 = _FlappableTierSource(
          id: 'nts:v1',
          groupId: 'g1',
          startMs: 1000,
          endMs: 1020,
          authLevel: NtsAuthLevel.verified,
          trustBackend: TrustBackend.webpkiRoots,
        )..failing = true;
        final dead2 = _FlappableTierSource(
          id: 'nts:v2',
          groupId: 'g2',
          startMs: 1005,
          endMs: 1025,
          authLevel: NtsAuthLevel.verified,
          trustBackend: TrustBackend.webpkiRoots,
        )..failing = true;

        // persistState: false models the empty cache; every source
        // fails to model the missing network. initialize() itself must
        // not throw — sync failure is swallowed and retried later.
        await initWith([dead1, dead2]);

        expect(TrustedTime.isTrusted, isFalse);
        expect(TrustedTime.isSecure, isFalse);
        expect(TrustedTime.authLevel, NtsAuthLevel.none);
        // No anchor at all: the auth gate rejects before now() is
        // reached, so strict callers see the actionable security error.
        expect(
          () => TrustedTime.getTime(requireSecure: true),
          throwsA(isA<TrustedTimeSecurityException>()),
        );
        // Relaxed callers fail too — with NotReady from now(): the
        // confidence gate passes (a null anchor reads as low, the
        // minimum), so the missing anchor is what stops the call.
        expect(
          () => TrustedTime.getTime(),
          throwsA(isA<TrustedTimeNotReadyException>()),
        );
      });
    });
  });
}

/// A fixed-interval [TimeSource] (mirroring [_TierSource]'s shape, but
/// unrelated to it) whose availability can be flipped mid-test, modelling
/// an NTS server flap: responsive during the establish cycle, unreachable
/// on a later resync.
class _FlappableTierSource implements TimeSource {
  _FlappableTierSource({
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

  /// When true, [getTime] throws as an unreachable server would.
  bool failing = false;

  @override
  Future<TimeSample> getTime() async {
    if (failing) {
      throw TimeoutException('server flap: $id unreachable');
    }
    return TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: groupId,
      authLevel: authLevel,
      trustBackend: trustBackend,
    );
  }
}
