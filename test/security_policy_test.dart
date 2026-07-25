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
/// A verified assessment ([TimeAssessment.isSecure] true) is only reachable
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
    test('an authLevel-none anchor assesses as degraded, not secure', () {
      final mock = TrustedTimeMock(initial: DateTime.now());
      mock.setTrusted(true);
      mock.setAuthLevel(NtsAuthLevel.none);

      TrustedTime.overrideForTesting(mock);
      addTearDown(TrustedTime.resetOverride);

      final assessment = TrustedTime.getAssessment();
      expect(assessment.isSecure, isFalse);
      expect(assessment.reason, TrustStatusReason.degraded);
      expect(assessment.time, isNotNull);
    });

    test('isSecure is false for none authLevel', () {
      final mock = TrustedTimeMock(initial: DateTime.now());
      mock.setAuthLevel(NtsAuthLevel.none);
      TrustedTime.overrideForTesting(mock);
      addTearDown(TrustedTime.resetOverride);

      expect(TrustedTime.getAssessment().isSecure, isFalse);
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
      // initialize() is non-blocking: these tests assert on the first
      // cycle's concluded posture, so wait for it to settle.
      await TrustedTime.firstSyncSettled;
      addTearDown(TrustedTimeImpl.instance.dispose);
    }

    test(
      'verified Tier 1 truth box assesses as synchronized and secure',
      () async {
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

        final assessment = TrustedTime.getAssessment();
        expect(assessment.authLevel, NtsAuthLevel.verified);
        expect(assessment.isSecure, isTrue);
        expect(assessment.reason, TrustStatusReason.synchronized);
        expect(assessment.time, isA<DateTime>());
      },
    );

    test('zero Tier 1 samples: the assessment reports degraded with a '
        'usable time but no security guarantee', () async {
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

      final assessment = TrustedTime.getAssessment();
      expect(assessment.authLevel, NtsAuthLevel.none);
      expect(assessment.isSecure, isFalse);
      expect(assessment.reason, TrustStatusReason.degraded);
      expect(assessment.time, isA<DateTime>());
    });

    test('unverified anchor keeps assessing as not-secure across resync '
        'cycles', () async {
      // None of the injected samples are verified, so the anchor stays
      // NtsAuthLevel.none and the secure gate fails closed on every cycle.
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
        final assessment = TrustedTime.getAssessment();
        expect(assessment.isSecure, isFalse, reason: 'cycle $cycle');
        expect(
          assessment.reason,
          TrustStatusReason.degraded,
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
      // initialize() is non-blocking: these tests assert on the first
      // cycle's concluded posture, so wait for it to settle.
      await TrustedTime.firstSyncSettled;
      addTearDown(TrustedTimeImpl.instance.dispose);
    }

    group('edge 1: stale-but-cached verified anchor (warm restore)', () {
      // isSecure gates *authentication*, not freshness: a persisted
      // verified anchor warm-restored within the same boot session
      // assesses as secure regardless of its age. There is no freshness
      // window on this path by design — staleness is the responsibility
      // of anchorAge / uncertainty / validateFreshness / the refresh
      // scheduler, per the Secure Time Contract's separation of
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
          // The prefix is unambiguous: the store's other key is
          // tt_drift_history_v1.
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

      test('an aged verified anchor still assesses as secure '
          '(no freshness window on the authentication gate)', () async {
        // No sources at all: the warm restore must satisfy the contract
        // without any network activity.
        await initWith(const [], persistState: true);

        final assessment = TrustedTime.getAssessment();
        expect(assessment.isSecure, isTrue);
        expect(assessment.authLevel, NtsAuthLevel.verified);
        expect(assessment.reason, TrustStatusReason.synchronized);
        // The reported time projects from the stale 2023 anchor,
        // proving the value came from the cache, not a fresh sync —
        // and anchorAge is what carries the staleness signal.
        expect(assessment.time!.year, 2023);
        expect(assessment.anchorAge, isNotNull);
      });
    });

    group('edge 2: only unauthenticated sources available', () {
      test('unauthenticated consensus is not authenticated time: '
          'an unauthenticated-only anchor assesses as degraded', () async {
        // Sources that reach quorum but carry no application-layer
        // signature over the timestamp: samples are unconditionally
        // NtsAuthLevel.none and the anchor degrades.
        await initWith([
          _TierSource(id: 'ntp:a', groupId: 'g1', startMs: 1000, endMs: 1020),
          _TierSource(id: 'ntp:b', groupId: 'g2', startMs: 1005, endMs: 1025),
        ]);

        final assessment = TrustedTime.getAssessment();
        // Quorum was reached — best-effort time is available...
        expect(assessment.isTrusted, isTrue);
        expect(assessment.time, isA<DateTime>());
        // ...but the anchor is degraded, so secure callers must reject.
        expect(assessment.authLevel, NtsAuthLevel.none);
        expect(assessment.isSecure, isFalse);
        expect(assessment.reason, TrustStatusReason.degraded);
      });
    });

    group('edge 3: mid-call NTS server flap', () {
      test('flap to full outage: while trust is invalidated the assessment '
          'reports syncFailed with no time', () async {
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
        expect(TrustedTime.getAssessment().isSecure, isTrue);

        // Every NTS server becomes unreachable; the resync cycle fails.
        nts1.failing = true;
        nts2.failing = true;
        await TrustedTime.forceResync();

        // Trust was invalidated by forceResync and the cycle failed, so
        // the engine refuses to project time. Fail-closed is preserved:
        // the assessment carries no time and no security claim — the
        // retained anchor's verified label is not surfaced while the
        // engine is unanchored.
        final assessment = TrustedTime.getAssessment();
        expect(assessment.isTrusted, isFalse);
        expect(assessment.time, isNull);
        expect(assessment.isSecure, isFalse);
        expect(assessment.reason, TrustStatusReason.syncFailed);
      });

      test(
        'flap with unauthenticated survivors: the degraded replacement '
        'anchor assesses as not-secure (no stale-verified carry-over)',
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
          expect(TrustedTime.getAssessment().isSecure, isTrue);

          // NTS flaps; NTP keeps answering, so the next cycle *succeeds*
          // as a degraded consensus and replaces the verified anchor.
          nts1.failing = true;
          nts2.failing = true;
          await TrustedTime.forceResync();

          final assessment = TrustedTime.getAssessment();
          expect(assessment.isTrusted, isTrue);
          expect(assessment.authLevel, NtsAuthLevel.none);
          expect(assessment.isSecure, isFalse);
          expect(assessment.reason, TrustStatusReason.degraded);
          // Best-effort callers keep working across the degradation.
          expect(assessment.time, isA<DateTime>());
        },
      );
    });

    group('edge 4: cold start with no cache and no network', () {
      test('initialize survives and the assessment reports syncFailed with '
          'no time and no security claim', () async {
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

        final assessment = TrustedTime.getAssessment();
        expect(assessment.isTrusted, isFalse);
        expect(assessment.time, isNull);
        expect(assessment.isSecure, isFalse);
        expect(assessment.authLevel, NtsAuthLevel.none);
        expect(assessment.confidence, ConfidenceLevel.none);
        // The first cycle concluded (and failed), so the posture is
        // syncFailed rather than neverSynced.
        expect(assessment.reason, TrustStatusReason.syncFailed);
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
