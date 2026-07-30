import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

import 'support/channel_mocks.dart';
import 'support/fake_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useDefaultChannelHandlers();

  group('bootstrap warm-barrier cap', () {
    test('a hung warm() cannot stall initialize(), and the detached '
        'first cycle stays bounded by warmBarrierCap', () {
      // Pins the non-blocking cold start against the pathological warm
      // case: a blackholed NTS-KE handshake must not delay initialize()
      // at all (the first cycle is detached), and inside that detached
      // chain the warm wait must still carry warmBarrierCap so the
      // cycle itself concludes under its own bounds. On timeout the
      // wait is abandoned (warm futures are memoized, not cancellable)
      // and the cycle proceeds.
      fakeAsync((async) {
        TrustedTimeImpl? impl;
        Object? initError;
        unawaited(
          TrustedTimeImpl.init(
            TrustedTimeConfig(
              disableNtpForTesting: true,
              ntsServers: const [],
              persistState: false,
              // Shrink the first cycle's outer safety timeout
              // (maxLatency + 6s) so the settle window this test
              // must elapse stays small and explicit.
              maxLatency: const Duration(seconds: 1),
              additionalSources: [_HungWarmSource()],
            ),
          ).then((i) => impl = i, onError: (Object e) => initError = e),
        );

        // initialize() resolves after local work only — with zero
        // elapsed fake time, despite the hung warm. The engine is
        // unanchored with the first cycle in flight.
        async.flushMicrotasks();
        expect(initError, isNull);
        expect(impl, isNotNull);
        expect(impl!.getAssessment().isTrusted, isFalse);
        expect(impl!.getAssessment().syncInProgress, isTrue);
        var settled = false;
        unawaited(impl!.firstSyncSettled.then((_) => settled = true));

        // The detached chain: bootstrap warm wait (warmBarrierCap),
        // then the cycle's own warming barrier re-joins the memoized
        // hung future (another warmBarrierCap), then the outer safety
        // timeout (maxLatency + 6s). Elapse with a second of slack:
        // the cycle fails quorum (the hung source never samples),
        // _performSync swallows the failure, and the first sync
        // settles untrusted.
        async.elapse(
          SyncEngine.warmBarrierCap + // bootstrap warm wait cap
              SyncEngine.warmBarrierCap + // sync()'s own barrier cap
              const Duration(seconds: 7) + // outer timeout (1s + 6s)
              const Duration(seconds: 1), // slack
        );
        expect(settled, isTrue);
        expect(impl!.getAssessment().isTrusted, isFalse);
        expect(impl!.getAssessment().syncInProgress, isFalse);

        // Cancel the retry timer armed by the failed (transient)
        // first cycle so no work leaks out of the fakeAsync zone.
        impl!.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('warm-restore boot-ID rejection (R5)', () {
    // End-to-end coverage of the IntegrityMonitor/TrustedTimeImpl seam:
    // initialize() must consume checkRebootOnWarmStart's verdict and
    // discard a persisted anchor whose boot identity does not match the
    // device's current boot session, forcing a fresh network sync
    // instead of a warm restore. The unit seams on both sides are
    // covered elsewhere; this pins the caller's boolean gate.
    //
    // The persisted anchor is served through the mocked secure-storage
    // channel because init() constructs the real AnchorStore, and the
    // current boot ID through the mocked monotonic channel. The anchor
    // is dated 2023 while the fake network sources answer 2024, so the
    // restore-vs-resync outcome is observable through the assessment's
    // time as well as through whether any source was queried at all.
    // Match the AnchorStore anchor key by stable prefix rather than the
    // exact versioned literal (currently tt_anchor_v2) so a key version
    // bump does not silently turn this into a cold start. No other
    // store key (drift history, legacy cleanup keys) shares the
    // tt_anchor_ prefix.
    const anchorKeyPrefix = 'tt_anchor_';

    // Wait-out attack shape: the anchor's recorded uptime (1000ms) is
    // far below the mocked current uptime (500000ms), so the legacy
    // inequality alone would honour the anchor — only boot identity
    // can reveal the reboot.
    final persistedUtc = DateTime.utc(2023, 1, 1).millisecondsSinceEpoch;
    final persistedAnchorJson = jsonEncode(
      TrustAnchor(
        networkUtcMs: persistedUtc,
        uptimeMs: 1000,
        wallMs: persistedUtc,
        uncertaintyMs: 10,
        bootId: 'boot-A',
      ).toJson(),
    );

    void installChannelMocks({required String currentBootId}) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'read') {
          final key = (call.arguments as Map)['key'] as String?;
          if (key != null && key.startsWith(anchorKeyPrefix)) {
            return persistedAnchorJson;
          }
        }
        return null;
      });
      messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 500000;
        if (call.method == 'getBootId') return currentBootId;
        return null;
      });
    }

    // Restore the file-level default handlers so sibling groups keep
    // the null-storage / fixed-uptime behaviour they were written
    // against.
    tearDown(installDefaultChannelHandlers);

    Future<ProbeCounter> initWithPersistedAnchor() async {
      final counter = ProbeCounter();
      final box = MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: const [],
          earlyExit: false,
          additionalSources: [
            BoxedCountingSource(
              box,
              id: 'ntp:a',
              groupId: 'g1',
              counter: counter,
            ),
            BoxedCountingSource(
              box,
              id: 'ntp:b',
              groupId: 'g2',
              counter: counter,
            ),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      return counter;
    }

    test('boot-ID mismatch discards the persisted anchor and forces a '
        'fresh network sync', () async {
      installChannelMocks(currentBootId: 'boot-B');

      final counter = await initWithPersistedAnchor();

      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      // The rejected restore fell through to _performSync: the network
      // sources were queried and the resulting anchor reflects their
      // 2024 consensus, not the 2023 anchor persisted under boot-A.
      expect(counter.count, greaterThan(0));
      expect(TrustedTime.getAssessment().time!.year, 2024);
    });

    test('matching boot ID warm-restores the persisted anchor without '
        'touching the network', () async {
      // Control: identical setup except the identity matches, proving
      // the mismatch test's fresh sync is attributable to the boot-ID
      // gate rather than to some other rejection of the fixture.
      installChannelMocks(currentBootId: 'boot-A');

      final counter = await initWithPersistedAnchor();

      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      expect(counter.count, 0);
      expect(TrustedTime.getAssessment().time!.year, 2023);
    });
  });

  group('bootstrap ordering: anchor restore precedes warm phase', () {
    // Pins the reorder in _bootstrap(): the persisted-anchor restore
    // check runs before any network-bound warm-up, so a warm start
    // never pays handshake wall time. The warm still happens on that
    // path — fired unawaited into the background for the scheduled
    // refresh to benefit from.
    final persistedUtc = DateTime.utc(2023, 1, 1).millisecondsSinceEpoch;
    final persistedAnchorJson = jsonEncode(
      TrustAnchor(
        networkUtcMs: persistedUtc,
        uptimeMs: 1000,
        wallMs: persistedUtc,
        uncertaintyMs: 10,
        bootId: 'boot-A',
      ).toJson(),
    );

    setUp(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'read') {
          final key = (call.arguments as Map)['key'] as String?;
          if (key != null && key.startsWith('tt_anchor_')) {
            return persistedAnchorJson;
          }
        }
        return null;
      });
      messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 500000;
        if (call.method == 'getBootId') return 'boot-A';
        return null;
      });
    });

    // Restore the file-level default handlers for sibling groups.
    tearDown(installDefaultChannelHandlers);

    test('warm restore completes without waiting on source warm-up', () {
      fakeAsync((async) {
        TrustedTimeImpl? impl;
        unawaited(
          TrustedTimeImpl.init(
            TrustedTimeConfig(
              disableNtpForTesting: true,
              ntsServers: const [],
              additionalSources: [_HungWarmSource()],
            ),
          ).then((i) => impl = i),
        );

        // The restore path is storage/channel-bound only: a microtask
        // flush resolves init with zero elapsed fake time even though
        // the source's warm() never completes. Before the reorder this
        // sat behind the awaited warm until warmBarrierCap.
        async.flushMicrotasks();
        expect(impl, isNotNull);
        expect(impl!.getAssessment().isTrusted, isTrue);
        expect(impl!.getAssessment().time!.year, 2023);

        impl!.dispose();
        async.flushMicrotasks();
      });
    });

    test('an invalid trust config fails initialize() even on the '
        'warm-restore path', () {
      // The eager effectiveTrustMode gate in _bootstrap validates the
      // trust config on every path. Before the gate, a warm restore
      // never touched SyncEngine._sources, so usePlatformTrust +
      // customRootCerts sailed through initialize() and only surfaced
      // later from the backgrounded warm-up. Now the misconfiguration
      // throws from initialize() itself — the documented error split:
      // config errors throw, network outcomes never do.
      fakeAsync((async) {
        TrustedTimeImpl? impl;
        Object? initError;
        unawaited(
          TrustedTimeImpl.init(
            const TrustedTimeConfig(
              disableNtpForTesting: true,
              ntsServers: [],
              usePlatformTrust: true,
              customRootCerts: [1, 2, 3],
            ),
          ).then((i) => impl = i, onError: (Object e) => initError = e),
        );
        async.flushMicrotasks();

        expect(impl, isNull);
        expect(initError, isA<ArgumentError>());
        // The failed init released its partial engine: no timers leak
        // out of the zone.
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('immediate dispose after warm restore is safe with the '
        'background warm still in flight', () {
      fakeAsync((async) {
        TrustedTimeImpl? impl;
        unawaited(
          TrustedTimeImpl.init(
            TrustedTimeConfig(
              disableNtpForTesting: true,
              ntsServers: const [],
              additionalSources: [_SlowWarmSource()],
            ),
          ).then((i) => impl = i),
        );
        async.flushMicrotasks();
        expect(impl, isNotNull);

        // Dispose while the unawaited background warm is still in
        // flight, then let it complete. warmAllSources() only touches
        // source-internal state, so the late completion must neither
        // throw (an uncaught error fails the fakeAsync zone) nor leave
        // engine work scheduled.
        impl!.dispose();
        async.elapse(const Duration(seconds: 30));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('firstSyncSettled is already complete when initialize() '
        'resolves on a warm restore', () {
      // A warm restore needs no first cycle: the settle gate must not
      // make callers wait on the background warm-up (which is not a
      // sync), and the assessment must not flag activity.
      fakeAsync((async) {
        TrustedTimeImpl? impl;
        unawaited(
          TrustedTimeImpl.init(
            const TrustedTimeConfig(disableNtpForTesting: true, ntsServers: []),
          ).then((i) => impl = i),
        );
        async.flushMicrotasks();
        expect(impl, isNotNull);
        expect(impl!.getAssessment().isTrusted, isTrue);
        expect(impl!.getAssessment().syncInProgress, isFalse);

        var settled = false;
        unawaited(impl!.firstSyncSettled.then((_) => settled = true));
        async.flushMicrotasks();
        expect(settled, isTrue);

        impl!.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('non-blocking initialize (cold start)', () {
    // The trusted_time-pzq contract: initialize() resolves after local
    // work only; the first sync cycle runs detached, observable as
    // syncInProgress and awaitable via firstSyncSettled.
    const config = TrustedTimeConfig(
      disableNtpForTesting: true,
      ntsServers: [],
      persistState: false,
      minimumQuorum: 2,
      minGroupCount: 1,
      earlyExit: false,
    );

    test('initialize() resolves while the first cycle is still in '
        'flight, and firstSyncSettled reports its conclusion', () async {
      final gate = Completer<void>();
      await TrustedTimeImpl.init(
        config.copyWith(
          additionalSources: [
            GatedSource(gate, id: 'nts:a', groupId: 'g1'),
            GatedSource(gate, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());

      // init resolved with both sources still blocked on the gate:
      // unanchored, cycle in flight, settle gate open.
      final during = TrustedTime.getAssessment();
      expect(during.isTrusted, isFalse);
      expect(during.reason, TrustStatusReason.neverSynced);
      expect(during.syncInProgress, isTrue);
      var settled = false;
      unawaited(TrustedTime.firstSyncSettled.then((_) => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      // Release the sources; the detached cycle concludes trusted.
      gate.complete();
      await TrustedTime.firstSyncSettled;
      final after = TrustedTime.getAssessment();
      expect(after.isTrusted, isTrue);
      expect(after.syncInProgress, isFalse);
    });

    test('a failed first cycle settles firstSyncSettled without '
        'throwing, leaving a syncFailed posture', () async {
      await TrustedTimeImpl.init(
        config.copyWith(
          additionalSources: [
            FailingSource(id: 'nts:a', groupId: 'g1'),
            FailingSource(id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());

      // Conclusion, not outcome: the await completes normally even
      // though the cycle failed — the verdict lives on the assessment.
      await TrustedTime.firstSyncSettled;
      final assessment = TrustedTime.getAssessment();
      expect(assessment.isTrusted, isFalse);
      expect(assessment.reason, TrustStatusReason.syncFailed);
      expect(assessment.syncInProgress, isFalse);
    });

    test('dispose before the first cycle concludes settles the gate '
        'so a waiter cannot hang', () async {
      final gate = Completer<void>();
      final impl = await TrustedTimeImpl.init(
        config.copyWith(
          additionalSources: [
            GatedSource(gate, id: 'nts:a', groupId: 'g1'),
            GatedSource(gate, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );

      expect(impl.getAssessment().syncInProgress, isTrue);
      impl.dispose();
      // Must complete promptly despite the still-blocked sources.
      await impl.firstSyncSettled.timeout(const Duration(seconds: 5));
      gate.complete();
    });

    test('dispose during the cold-start warm phase stops the detached '
        'chain before the first sync starts', () {
      // The detached chain re-checks _disposed between its warm and
      // sync phases: a dispose() landing while the warm is still in
      // flight must prevent _performSync from ever querying a source
      // or arming timers on the torn-down engine.
      fakeAsync((async) {
        final counter = ProbeCounter();
        TrustedTimeImpl? impl;
        unawaited(
          TrustedTimeImpl.init(
            config.copyWith(
              additionalSources: [
                _SlowWarmCountingSource(counter, id: 'nts:a', groupId: 'g1'),
                _SlowWarmCountingSource(counter, id: 'nts:b', groupId: 'g2'),
              ],
            ),
          ).then((i) => impl = i),
        );
        async.flushMicrotasks();
        expect(impl, isNotNull);
        expect(impl!.getAssessment().syncInProgress, isTrue);

        impl!.dispose();
        async.elapse(const Duration(seconds: 30));

        expect(counter.count, 0);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('forceResync reports syncInProgress while its cycle is in '
        'flight', () async {
      // The flag is an activity signal beyond the first cycle: a
      // forceResync purges the anchor (documented) and rebuilds — the
      // in-flight window must read as unanchored *with* activity, the
      // "resolution imminent" wait state rather than a settled failure.
      final gate = Completer<void>();
      var firstCycleDone = false;
      await TrustedTimeImpl.init(
        config.copyWith(
          additionalSources: [
            GatedThenBoxedSource(
              () => firstCycleDone,
              gate,
              id: 'nts:a',
              groupId: 'g1',
            ),
            GatedThenBoxedSource(
              () => firstCycleDone,
              gate,
              id: 'nts:b',
              groupId: 'g2',
            ),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      firstCycleDone = true;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      expect(TrustedTime.getAssessment().syncInProgress, isFalse);

      final resync = TrustedTime.forceResync();
      await Future<void>.delayed(Duration.zero);
      final during = TrustedTime.getAssessment();
      expect(during.isTrusted, isFalse);
      expect(during.syncInProgress, isTrue);

      gate.complete();
      await resync;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      expect(TrustedTime.getAssessment().syncInProgress, isFalse);
    });
  });
}

/// A [TimeSource] whose [warm] completes after a delay, to exercise a
/// background warm that outlives the engine it was fired from.
class _SlowWarmSource implements TimeSource, Warmable {
  @override
  final String id = 'nts:slow-warm';
  @override
  final String groupId = 'gslow';

  @override
  Future<void> warm() => Future<void>.delayed(const Duration(seconds: 5));

  @override
  Future<TimeSample> getTime() => Completer<TimeSample>().future;
}

/// A [_SlowWarmSource] variant that tallies every getTime() call, used
/// to prove a dispose() landing during the cold-start warm phase stops
/// the detached chain before its sync phase ever queries a source.
class _SlowWarmCountingSource implements TimeSource, Warmable {
  _SlowWarmCountingSource(
    this.counter, {
    required this.id,
    required this.groupId,
  });

  final ProbeCounter counter;
  @override
  final String id;
  @override
  final String groupId;

  @override
  Future<void> warm() => Future<void>.delayed(const Duration(seconds: 5));

  @override
  Future<TimeSample> getTime() async {
    counter.count++;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(startMs: nowMs - 10, endMs: nowMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// A [TimeSource] whose [warm] never completes, to exercise the
/// bootstrap warm-await bound: a hung handshake must not stall
/// initialize() past [SyncEngine.warmBarrierCap].
class _HungWarmSource implements TimeSource, Warmable {
  @override
  final String id = 'nts:hung-warm';
  @override
  final String groupId = 'ghung';

  @override
  Future<void> warm() => Completer<void>().future;

  @override
  Future<TimeSample> getTime() => Completer<TimeSample>().future;
}
