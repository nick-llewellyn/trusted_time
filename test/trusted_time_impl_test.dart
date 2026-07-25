import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('TrustedTimeImpl via mock', () {
    late TrustedTimeMock mock;

    setUp(() {
      mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
      TrustedTime.overrideForTesting(mock);
    });

    tearDown(TrustedTime.resetOverride);

    test('assessment loses trust after setTrusted(false)', () {
      expect(TrustedTime.getAssessment().isTrusted, isTrue);

      mock.setTrusted(false);

      final assessment = TrustedTime.getAssessment();
      expect(assessment.isTrusted, isFalse);
      expect(assessment.time, isNull);
      expect(assessment.reason, TrustStatusReason.syncFailed);
    });

    test('assessment reports rebootDetected after reboot event', () {
      expect(TrustedTime.getAssessment().isTrusted, isTrue);

      mock.simulateReboot();

      final assessment = TrustedTime.getAssessment();
      expect(assessment.isTrusted, isFalse);
      expect(assessment.reason, TrustStatusReason.rebootDetected);
    });

    test('setTrusted(false) honours an explicit unanchored reason', () {
      mock.setTrusted(false, reason: TrustStatusReason.neverSynced);

      expect(TrustedTime.getAssessment().reason, TrustStatusReason.neverSynced);
    });

    test('restoreTrust re-enables trust after reboot', () {
      mock.simulateReboot();
      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      mock.restoreTrust();
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
    });

    test(
      'trustedLocalTimeIn throws TrustedTimeNotReadyException when not trusted',
      () async {
        await TrustedTime.initialize();
        mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
        TrustedTime.overrideForTesting(mock);
        mock.simulateReboot();
        expect(
          () => TrustedTime.trustedLocalTimeIn('America/New_York'),
          throwsA(isA<TrustedTimeNotReadyException>()),
        );
      },
    );

    test('a trusted assessment carries time', () {
      final assessment = TrustedTime.getAssessment();
      expect(assessment.time, isNotNull);
      expect(assessment.uncertainty, Duration.zero);
    });

    test('mock assessments never carry drift fields', () {
      expect(TrustedTime.getAssessment().driftRate, isNull);
      expect(TrustedTime.getAssessment().driftCorrectedTime, isNull);
      expect(TrustedTime.getDriftHistory(), isEmpty);
    });
  });

  group('TrustedTime.config', () {
    // The override path is exercised on its own so we can drop into the
    // real `TrustedTimeImpl.init` for the live-engine assertion below
    // without contaminating sibling tests in this file.
    tearDown(TrustedTime.resetOverride);

    test(
      'first-ever initialize does not surface a null check on the proxy observer',
      () async {
        // Regression: _ProxySyncObserver previously closed over the
        // static _instance, which is only assigned after _bootstrap()
        // completes. The bootstrap sync's onSyncStarted callback
        // dereferenced `_instance!` synchronously and threw
        // 'Null check operator used on a null value', which was
        // silently swallowed by _performSync's catch block.
        //
        // The bug had no observable side effect from outside the
        // engine (the catch swallowed the TypeError), so this test
        // pins a weaker but still useful contract: a first-ever
        // initialize() with empty source pools completes normally
        // without raising or hanging. Before the fix, initialize()
        // also returned normally — so this test does not strictly
        // distinguish the two states. The accompanying observer
        // probe below additionally verifies the proxy fan-out is
        // wired correctly post-init by exercising it via
        // forceResync(), which catches any *future* regression that
        // breaks the proxy entirely.
        await TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        // Cancel the engine's retry timer at teardown so the failed
        // bootstrap (no-quorum) can't fire a stray _performSync into
        // a sibling test in this suite.
        addTearDown(TrustedTimeImpl.instance.dispose);
        // Let the detached first cycle conclude before registering the
        // probe: forceResync would otherwise converge on that in-flight
        // cycle (whose onSyncStarted predates the registration).
        await TrustedTime.firstSyncSettled;

        final probe = _SyncStartedProbe();
        TrustedTime.registerObserver(probe);
        addTearDown(() => TrustedTime.unregisterObserver(probe));

        await TrustedTime.forceResync();

        expect(
          probe.startCount,
          greaterThanOrEqualTo(1),
          reason: 'forceResync must reach onSyncStarted via the proxy',
        );
      },
    );

    test(
      'concurrent forceResync calls converge on a single in-flight '
      'cycle and emit exactly one onSyncStarted (trusted_time-exw)',
      () async {
        // Acceptance criterion from `bd-trusted_time-exw`: synchronously
        // dispatch multiple sync requests in a tight loop and assert
        // exactly one `onSyncStarted` is emitted. Validates the
        // two-tier in-flight guard in `_performSync`: the synchronous
        // [_syncEntryGuard] bool catches same-microtask re-entry
        // before any await, and the [_syncInProgress] Completer makes
        // the converging callers all complete on the same future.
        //
        // Without either guard tier the three `forceResync` calls
        // would each reach `_syncEngine.sync()` independently and
        // produce three observable `onSyncStarted` events.
        await TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);
        // Let the detached first cycle conclude first: the three
        // forceResync calls below must converge on *their own* single
        // cycle, not silently join the in-flight bootstrap cycle
        // (whose onSyncStarted predates the probe registration).
        await TrustedTime.firstSyncSettled;

        final probe = _SyncStartedProbe();
        TrustedTime.registerObserver(probe);
        addTearDown(() => TrustedTime.unregisterObserver(probe));

        // Three back-to-back synchronous dispatches in a single list
        // literal. All three `forceResync()` calls execute their
        // synchronous prologues sequentially in the *same microtask*
        // — async functions in Dart run synchronously until their
        // first `await`, and calling one without awaiting does not
        // yield between back-to-back invocations. Trace:
        //
        //  * Call A enters `forceResync` → enters `_performSync`,
        //    synchronously sets [_syncEntryGuard]+[_syncInProgress],
        //    cancels timers, then hits `await _syncEngine.sync()`
        //    and yields.
        //  * Control returns to the list-literal evaluation. Call B
        //    enters `forceResync` → enters `_performSync` *in the
        //    same microtask*. The two-tier guard sees
        //    `_syncEntryGuard == true` and returns A's in-flight
        //    future. B's `await _performSync()` then awaits A's
        //    future.
        //  * Call C does the same, also returning A's future.
        //
        // All three Futures resolve when A's cycle completes. Without
        // either guard tier, calls 2 and 3 would each reach
        // `_syncEngine.sync()` independently and produce three
        // observable `onSyncStarted` events — that is the regression
        // signature this assertion catches.
        final futures = <Future<void>>[
          TrustedTime.forceResync(),
          TrustedTime.forceResync(),
          TrustedTime.forceResync(),
        ];
        await Future.wait(futures);

        expect(
          probe.startCount,
          equals(1),
          reason:
              'Three concurrent forceResync calls must converge on '
              'a single in-flight cycle; multiple onSyncStarted '
              'events indicate the in-flight guard has regressed.',
        );
      },
    );

    test(
      'returns the same TrustedTimeConfig instance passed to initialize',
      () async {
        // Empty source lists keep the test fully offline: the engine
        // constructs, but the bootstrap sync fails fast (no quorum)
        // and never touches the network. `ntsServers: []` also skips
        // the `NtsRustLib.init` -> `copyWith(ntsServers: [])` rewrite in
        // TrustedTime.initialize, so the exact instance we pass in is
        // what gets stashed on TrustedTimeImpl._config.
        const config = TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          refreshInterval: Duration(minutes: 7),
          minimumQuorum: 3,
          persistState: false,
        );

        await TrustedTime.initialize(config: config);
        addTearDown(TrustedTimeImpl.instance.dispose);

        expect(identical(TrustedTime.config, config), isTrue);
        expect(TrustedTime.config.refreshInterval, const Duration(minutes: 7));
        expect(TrustedTime.config.minimumQuorum, 3);
        expect(TrustedTime.config.ntsServers, isEmpty);
      },
    );

    test('returns default const TrustedTimeConfig under a test override', () {
      final mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
      TrustedTime.overrideForTesting(mock);

      // Under an override the public surface should not reach the real
      // singleton; per the override-path contract it returns the
      // canonical default config.
      expect(identical(TrustedTime.config, const TrustedTimeConfig()), isTrue);
    });
  });

  group('sleep-aware projection surface', () {
    tearDown(TrustedTime.resetOverride);

    // A plain test isolate never initializes the nts bridge
    // (nts.MonotonicClock.instance throws StateError by contract), so
    // resolveMonotonicReader deterministically resolves the
    // suspend-frozen Stopwatch fallback in every test below.

    test(
      'isProjectionSleepAware reports the fallback timeline honestly',
      () async {
        await TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);

        expect(TrustedTime.isProjectionSleepAware, isFalse);
      },
    );

    test('requireSleepAwareProjection fails initialize() fast when only '
        'the suspend-frozen fallback is available', () async {
      await expectLater(
        TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
            requireSleepAwareProjection: true,
          ),
        ),
        throwsA(isA<TrustedTimeSecurityException>()),
      );
    });

    test('default (requireSleepAwareProjection: false) accepts the '
        'fallback and initialize() completes', () async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      // No throw; the degraded timeline is observable, not fatal.
      expect(TrustedTime.isProjectionSleepAware, isFalse);
    });

    test('isProjectionSleepAware is true under a mock override', () {
      final mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
      TrustedTime.overrideForTesting(mock);

      expect(TrustedTime.isProjectionSleepAware, isTrue);
    });

    test('a failed fail-fast initialize() leaves no stale singleton', () async {
      // First, a successful init installs a live singleton.
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      expect(TrustedTimeImpl.instance, isNotNull);

      // A re-initialize that trips the gate must not leave [instance]
      // pointing at the disposed previous engine: the singleton is
      // cleared before bootstrap, so a failed init lands in a clean
      // "not initialized" state.
      await expectLater(
        TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
            requireSleepAwareProjection: true,
          ),
        ),
        throwsA(isA<TrustedTimeSecurityException>()),
      );

      expect(() => TrustedTimeImpl.instance, throwsAssertionError);
    });

    test('a failed re-initialize() leaves the background channel handler '
        'unbound', () async {
      // Delivers an inbound platform message on the background channel
      // and reports whether a Dart-side handler answered it: a bound
      // handler produces a non-null reply envelope, an unbound channel
      // replies null.
      Future<bool> backgroundHandlerBound() async {
        const codec = StandardMethodCodec();
        final message = codec.encodeMethodCall(
          const MethodCall('onBackgroundSync'),
        );
        ByteData? reply;
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'trusted_time/background',
              message,
              (data) => reply = data,
            );
        return reply != null;
      }

      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      expect(await backgroundHandlerBound(), isTrue);

      // The gate-tripping re-init disposes the previous engine, which
      // must unbind the handler — otherwise platform callbacks would
      // keep invoking the disposed instance.
      await expectLater(
        TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
            requireSleepAwareProjection: true,
          ),
        ),
        throwsA(isA<TrustedTimeSecurityException>()),
      );

      expect(await backgroundHandlerBound(), isFalse);
    });
  });

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
              ntpServers: const [],
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

  group('TrustedTime refresh schedule control', () {
    // Live-engine tests; tear down any leftover override from earlier
    // groups so the static surface drops into the real
    // TrustedTimeImpl singleton.
    tearDown(TrustedTime.resetOverride);

    // Tracks whether the dispose-at-teardown hook has already been
    // registered in the active test, so multiple initEmpty() calls
    // in a single test (e.g. the "pause state does not persist
    // across re-initialize" test) don't queue redundant teardowns.
    // Reset between tests by setUp below. dispose() itself is
    // idempotent, so this guard is belt-and-braces — the previous
    // version queued two teardowns referring to two different
    // instances (the first instance is disposed by init's own
    // re-init path, then disposed again at teardown), which the
    // idempotency guard now handles cleanly. Tracking the
    // registration here keeps the teardown queue minimal regardless.
    var teardownRegistered = false;
    setUp(() {
      teardownRegistered = false;
    });

    Future<void> initEmpty() async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
          refreshInterval: Duration(minutes: 5),
        ),
      );
      // Cancel the engine's retry timer at teardown so the failed
      // bootstrap (no-quorum) can't fire a stray _performSync into
      // a sibling test in this group. Only register once per test;
      // the closure resolves TrustedTimeImpl.instance at teardown
      // time, so it always picks up whichever instance is current
      // at the end of the test (the most recently initialized one).
      if (!teardownRegistered) {
        teardownRegistered = true;
        addTearDown(() => TrustedTimeImpl.instance.dispose());
      }
    }

    test('automaticRefreshActive is true after a fresh initialize', () async {
      await initEmpty();
      expect(TrustedTime.automaticRefreshActive, isTrue);
    });

    test('pauseAutomaticRefresh flips automaticRefreshActive to false; '
        'resumeAutomaticRefresh restores it', () async {
      await initEmpty();

      TrustedTime.pauseAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isFalse);

      // Idempotent.
      TrustedTime.pauseAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isFalse);

      TrustedTime.resumeAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isTrue);

      // Calling resume again keeps automaticRefreshActive true
      // (idempotent in terms of the getter); the underlying
      // refresh-timer deadline is reset on each call, but this
      // test only pins the user-facing flag.
      TrustedTime.resumeAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isTrue);
    });

    test('setRefreshInterval(Duration.zero) is equivalent to '
        'pauseAutomaticRefresh', () async {
      await initEmpty();

      TrustedTime.setRefreshInterval(Duration.zero);
      expect(TrustedTime.automaticRefreshActive, isFalse);

      // resumeAutomaticRefresh re-arms with the most recent positive
      // interval (the at-init default in this case, since
      // setRefreshInterval(Duration.zero) does not overwrite the
      // active interval — see TrustedTimeImpl.setRefreshInterval).
      TrustedTime.resumeAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isTrue);
    });

    test('setRefreshInterval with a positive value also resumes from a '
        'paused state', () async {
      await initEmpty();

      TrustedTime.pauseAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isFalse);

      TrustedTime.setRefreshInterval(const Duration(seconds: 10));
      expect(TrustedTime.automaticRefreshActive, isTrue);
    });

    test('TrustedTime.config still reports the at-init refreshInterval after '
        'setRefreshInterval mutates the active value', () async {
      // Pinning the contract that config is a snapshot of init-time
      // values; the runtime-mutable interval is intentionally not
      // exposed via [config] (preserves backwards compatibility for
      // consumers reading config.refreshInterval to display the
      // configured cadence).
      await initEmpty();

      TrustedTime.setRefreshInterval(const Duration(seconds: 7));

      expect(TrustedTime.config.refreshInterval, const Duration(minutes: 5));
    });

    test('pause state does not persist across re-initialize', () async {
      await initEmpty();
      TrustedTime.pauseAutomaticRefresh();
      expect(TrustedTime.automaticRefreshActive, isFalse);

      await initEmpty();
      expect(
        TrustedTime.automaticRefreshActive,
        isTrue,
        reason:
            're-init must give a fresh schedule; consumers that want to '
            'preserve the paused state should re-call '
            'pauseAutomaticRefresh after initialize',
      );
    });

    test(
      'pause/resume/setRefreshInterval are no-ops under a test override',
      () async {
        final mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
        TrustedTime.overrideForTesting(mock);

        // Pins the override-path contract: the pause / resume /
        // setRefreshInterval entry points return without raising and
        // without touching any TrustedTimeImpl singleton, regardless
        // of whether earlier tests in this group have created one.
        expect(() => TrustedTime.pauseAutomaticRefresh(), returnsNormally);
        expect(() => TrustedTime.resumeAutomaticRefresh(), returnsNormally);
        expect(
          () => TrustedTime.setRefreshInterval(const Duration(minutes: 1)),
          returnsNormally,
        );
        expect(TrustedTime.automaticRefreshActive, isFalse);
      },
    );
  });

  group('TrustedTime failed-sync retry classification', () {
    // Pins the shared transient/non-transient verdict (isTransientSyncError,
    // also used by runBackgroundSync's in-run retry loop) on the foreground
    // retry scheduler: a failed cycle arms the retry timer only for
    // transient failures. Before the unification, every failure — including
    // an ArgumentError from an invalid config that fails identically on
    // each attempt — looped through _scheduleRetry forever.
    tearDown(TrustedTime.resetOverride);

    test('a transient quorum failure arms the retry timer', () async {
      // Sources that throw make the bootstrap sync fail quorum — a
      // transient TrustedTimeSyncException (network weather), so
      // recovery retries stay armed.
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          persistState: false,
          additionalSources: [
            _FailingSource(id: 'ntp:a', groupId: 'g1'),
            _FailingSource(id: 'https:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      await TrustedTime.firstSyncSettled;

      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      expect(TrustedTimeImpl.instance.debugRetryTimerActive, isTrue);
    });

    test(
      'an empty source configuration does not arm the retry timer',
      () async {
        // "No time sources are configured" fails identically on every
        // attempt — the engine flags it non-transient, so retrying would
        // just loop the same failure (and drain battery in background
        // contexts). The retry timer must stay unarmed.
        await TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);
        await TrustedTime.firstSyncSettled;

        expect(TrustedTime.getAssessment().isTrusted, isFalse);
        expect(TrustedTimeImpl.instance.debugRetryTimerActive, isFalse);
      },
    );

    test('a non-transient failure does not arm the retry timer', () async {
      // Drive the non-transient class through the shared cycle's banking
      // step: the engine reaches quorum, but persisting the anchor throws
      // (secure storage rejects writes). A storage failure is not network
      // weather — retrying the identical cycle would fail identically —
      // so the retry timer must stay unarmed.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            if (call.method == 'write') {
              throw PlatformException(code: 'STORAGE_UNAVAILABLE');
            }
            return null;
          });
      addTearDown(() {
        // Restore the file-level null-returning storage mock so sibling
        // tests keep their persistence-free behaviour.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(storageChannel, (call) async => null);
      });

      final box = _MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          additionalSources: [
            _BoxedSource(box, id: 'ntp:a', groupId: 'g1'),
            _BoxedSource(box, id: 'https:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      await TrustedTime.firstSyncSettled;

      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      expect(TrustedTimeImpl.instance.debugRetryTimerActive, isFalse);
    });
  });

  group('TrustedTimeConfig value equality', () {
    test('two non-const instances with identical fields compare equal', () {
      // `new TrustedTimeConfig(...)` (without `const`) defeats Dart's
      // const canonicalisation, so these are guaranteed to be distinct
      // object identities. Equality must therefore come from the new
      // operator==/hashCode, not from `identical`.
      final a = TrustedTimeConfig(
        ntpServers: const ['pool.ntp.org'],
        ntsServers: const ['time.cloudflare.com'],
        refreshInterval: const Duration(minutes: 5),
        minimumQuorum: 3,
      );
      final b = TrustedTimeConfig(
        ntpServers: const ['pool.ntp.org'],
        ntsServers: const ['time.cloudflare.com'],
        refreshInterval: const Duration(minutes: 5),
        minimumQuorum: 3,
      );

      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('list field divergence breaks equality', () {
      final a = TrustedTimeConfig(ntsServers: const ['a', 'b']);
      final b = TrustedTimeConfig(ntsServers: const ['a', 'b', 'c']);
      final c = TrustedTimeConfig(ntsServers: const ['b', 'a']);

      expect(a, isNot(equals(b)));
      // Element order matters — server order influences shuffle and
      // cycle iteration, so unordered equality would be a regression.
      expect(a, isNot(equals(c)));
    });

    test('scalar field divergence breaks equality', () {
      final base = TrustedTimeConfig();
      expect(base, isNot(equals(base.copyWith(minimumQuorum: 99))));
      expect(
        base,
        isNot(equals(base.copyWith(refreshInterval: const Duration(days: 1)))),
      );
    });

    test('toString surfaces the source pools and quorum knobs', () {
      final config = TrustedTimeConfig(
        ntpServers: const ['pool.ntp.org'],
        ntsServers: const ['time.cloudflare.com', 'mmo1.nts.netnod.se'],
        minimumQuorum: 4,
        refreshInterval: const Duration(minutes: 2),
      );
      final text = config.toString();

      expect(text, startsWith('TrustedTimeConfig('));
      expect(text, contains('ntpServers: [pool.ntp.org]'));
      expect(
        text,
        contains('ntsServers: [time.cloudflare.com, mmo1.nts.netnod.se]'),
      );
      expect(text, contains('minimumQuorum: 4'));
      expect(text, contains('refreshInterval: 0:02:00.000000'));
    });
  });

  group('TrustedTime.validateFreshness (ADR 0006)', () {
    tearDown(TrustedTime.resetOverride);

    test('under a test override reflects the mock trust state', () async {
      final mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
      TrustedTime.overrideForTesting(mock);

      expect(await TrustedTime.validateFreshness(), isTrue);

      mock.setTrusted(false);
      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      expect(await TrustedTime.validateFreshness(), isFalse);
    });

    test('throws TrustedTimeFreshnessProbeException when no anchor is '
        'established', () async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      await TrustedTime.firstSyncSettled;

      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      await expectLater(
        TrustedTime.validateFreshness(),
        throwsA(isA<TrustedTimeFreshnessProbeException>()),
      );
    });

    test(
      'throws when an anchor exists but no NTS source is configured',
      () async {
        final box = _MidpointBox(
          DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
        );
        await TrustedTime.initialize(
          config: TrustedTimeConfig(
            ntpServers: const [],
            ntsServers: const [],
            persistState: false,
            earlyExit: false,
            additionalSources: [
              _BoxedSource(box, id: 'ntp:a', groupId: 'g1'),
              _BoxedSource(box, id: 'https:b', groupId: 'g2'),
            ],
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);
        await TrustedTime.firstSyncSettled;

        expect(TrustedTime.getAssessment().isTrusted, isTrue);
        await expectLater(
          TrustedTime.validateFreshness(),
          throwsA(isA<TrustedTimeFreshnessProbeException>()),
        );
      },
    );

    test(
      'returns true when a fresh NTS probe agrees with the anchor',
      () async {
        final box = _MidpointBox(
          DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
        );
        await TrustedTime.initialize(
          config: TrustedTimeConfig(
            ntpServers: const [],
            ntsServers: const [],
            persistState: false,
            earlyExit: false,
            additionalSources: [
              _BoxedSource(box, id: 'nts:a', groupId: 'g1'),
              _BoxedSource(box, id: 'nts:b', groupId: 'g2'),
            ],
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);
        await TrustedTime.firstSyncSettled;

        expect(TrustedTime.getAssessment().isTrusted, isTrue);
        expect(await TrustedTime.validateFreshness(), isTrue);
      },
    );

    test(
      'is authLevel-agnostic: a none probe re-validates a verified anchor',
      () async {
        // Pins the deliberate posture for trusted_time-wba: freshness is
        // an *operational* claim (the clock has not drifted), not an
        // *authentication* claim — the anchor's integrity guarantees come
        // entirely from the establish cycle, so validateFreshness() does
        // not compare the probe sample's authLevel against the anchor's.
        //
        // As shipped, the mixed case cannot arise: bundledOnly cannot
        // produce `none` samples and platformOnly cannot produce
        // `verified` anchors. This test constructs the mix directly so
        // that if a future trust mode (or a probe-side authLevel guard)
        // changes the posture, it fails and forces the decision to be
        // re-asked rather than drifting silently.
        final box = _MidpointBox(
          DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
        );
        final a = _AuthBoxedSource(
          box,
          id: 'nts:a',
          groupId: 'g1',
          authLevel: NtsAuthLevel.verified,
        );
        final b = _AuthBoxedSource(
          box,
          id: 'nts:b',
          groupId: 'g2',
          authLevel: NtsAuthLevel.verified,
        );
        await TrustedTime.initialize(
          config: TrustedTimeConfig(
            ntpServers: const [],
            ntsServers: const [],
            persistState: false,
            earlyExit: false,
            additionalSources: [a, b],
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);
        await TrustedTime.firstSyncSettled;

        // The establish cycle built a Tier 1 (verified) anchor.
        expect(TrustedTime.getAssessment().isTrusted, isTrue);
        expect(TrustedTime.getAssessment().authLevel, NtsAuthLevel.verified);

        // Downgrade both sources so the probe sample reports `none`,
        // then confirm the probe still re-validates the verified anchor.
        a.authLevel = NtsAuthLevel.none;
        b.authLevel = NtsAuthLevel.none;
        expect(await TrustedTime.validateFreshness(), isTrue);
        expect(TrustedTime.getAssessment().authLevel, NtsAuthLevel.verified);
      },
    );

    test('returns false when the NTS probe disagrees beyond the '
        'uncertainty window', () async {
      final box = _MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          persistState: false,
          earlyExit: false,
          // Pin the uncertainty window so this test's pass/fail boundary
          // does not depend on the library default staying at 5s.
          maxAllowedUncertaintyMs: 5000,
          additionalSources: [
            _BoxedSource(box, id: 'nts:a', groupId: 'g1'),
            _BoxedSource(box, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      await TrustedTime.firstSyncSettled;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);

      // Move the probe (10s) far outside the configured 5s uncertainty
      // window; the anchor stays at the establish-time midpoint.
      box.midpointMs += 10000;
      expect(await TrustedTime.validateFreshness(), isFalse);
    });
  });

  group('TrustedTime tiered cadence scheduler (ADR 0006)', () {
    // Live-engine tests; clear any override left by earlier groups so the
    // static surface drops into the real TrustedTimeImpl singleton.
    tearDown(TrustedTime.resetOverride);

    Future<void> initTiered(
      _MidpointBox box, {
      Duration foregroundValidateThreshold = const Duration(minutes: 15),
    }) async {
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          persistState: false,
          earlyExit: false,
          cadenceMode: CadenceMode.tieredMobile,
          foregroundValidateThreshold: foregroundValidateThreshold,
          additionalSources: [
            _BoxedSource(box, id: 'nts:a', groupId: 'g1'),
            _BoxedSource(box, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      // These tests assert on the establish cycle's concluded anchor
      // and the timers it arms; wait for the detached cycle to settle.
      await TrustedTime.firstSyncSettled;
      addTearDown(() => TrustedTimeImpl.instance.dispose());
    }

    Future<void> initSingleTier() async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
    }

    _MidpointBox freshBox() =>
        _MidpointBox(DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch);

    test('singleTier30m arms neither the validate timer nor the '
        'lifecycle observer', () async {
      await initSingleTier();
      final impl = TrustedTimeImpl.instance;
      expect(impl.debugValidateTimerActive, isFalse);
      expect(impl.debugLifecycleObserverInstalled, isFalse);
    });

    test('tieredMobile arms the validate timer and installs the '
        'lifecycle observer', () async {
      await initTiered(freshBox());
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      expect(impl.debugValidateTimerActive, isTrue);
      expect(impl.debugLifecycleObserverInstalled, isTrue);
    });

    test(
      'a foreground resume after the threshold runs a validate cycle',
      () async {
        await initTiered(freshBox());
        final impl = TrustedTimeImpl.instance;
        expect(impl.debugValidateCycleCount, 0);

        const bg = Duration(hours: 5);
        impl.debugHandleAppLifecycleState(
          AppLifecycleState.paused,
          elapsed: bg,
        );
        impl.debugHandleAppLifecycleState(
          AppLifecycleState.resumed,
          elapsed: bg + const Duration(minutes: 20),
        );
        // The cycle is fire-and-forget; let its probe settle.
        await Future.delayed(const Duration(milliseconds: 20));

        expect(impl.debugValidateCycleCount, 1);
        // The probe agreed with the anchor, so trust is intact.
        expect(TrustedTime.getAssessment().isTrusted, isTrue);
      },
    );

    test('a brief background excursion below the threshold does not '
        'run a validate cycle', () async {
      await initTiered(freshBox());
      final impl = TrustedTimeImpl.instance;

      const bg = Duration(hours: 5);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused, elapsed: bg);
      impl.debugHandleAppLifecycleState(
        AppLifecycleState.resumed,
        elapsed: bg + const Duration(minutes: 5),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(impl.debugValidateCycleCount, 0);
    });

    test('a resume with no prior background transition is a no-op', () async {
      await initTiered(freshBox());
      final impl = TrustedTimeImpl.instance;

      impl.debugHandleAppLifecycleState(
        AppLifecycleState.resumed,
        elapsed: const Duration(hours: 5),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(impl.debugValidateCycleCount, 0);
    });

    test('a negative foreground threshold is normalized to zero and probes '
        'on every resume', () async {
      await initTiered(
        freshBox(),
        foregroundValidateThreshold: const Duration(minutes: -1),
      );
      final impl = TrustedTimeImpl.instance;

      // Same monotonic reading on background and resume: a zero-length
      // excursion. With the negative threshold normalized to zero, the
      // delta (0) still meets the bound, so a cycle runs.
      const bg = Duration(hours: 5);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused, elapsed: bg);
      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed, elapsed: bg);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(impl.debugValidateCycleCount, 1);
    });

    test('a non-advancing monotonic reading on resume does not run a '
        'cycle (guards the wall-clock-regression case)', () async {
      await initTiered(freshBox());
      final impl = TrustedTimeImpl.instance;

      const bg = Duration(hours: 5);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused, elapsed: bg);
      // Under wall-clock time a backward jump while backgrounded would
      // make the delta negative and silently skip the probe. A monotonic
      // source can never regress, so a non-advancing reading is simply a
      // sub-threshold (here zero) duration and runs no cycle.
      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed, elapsed: bg);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(impl.debugValidateCycleCount, 0);
    });

    test('singleTier30m ignores lifecycle transitions entirely', () async {
      await initSingleTier();
      final impl = TrustedTimeImpl.instance;

      const bg = Duration(hours: 5);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused, elapsed: bg);
      impl.debugHandleAppLifecycleState(
        AppLifecycleState.resumed,
        elapsed: bg + const Duration(hours: 1),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(impl.debugValidateCycleCount, 0);
    });

    test(
      'dispose cancels the validate timer and detaches the observer',
      () async {
        await initTiered(freshBox());
        final impl = TrustedTimeImpl.instance;
        expect(impl.debugValidateTimerActive, isTrue);
        expect(impl.debugLifecycleObserverInstalled, isTrue);

        impl.dispose();

        expect(impl.debugValidateTimerActive, isFalse);
        expect(impl.debugLifecycleObserverInstalled, isFalse);
      },
    );

    test('a foreground resume does not start a probe that overlaps an '
        'in-flight validate cycle (shared in-flight guard)', () async {
      // A probe is a single getTime() call, so the counter tallies
      // exactly "one probe == one getTime() call"; the two sources
      // share one counter so the assertion holds regardless of which
      // ranked source the validate tier selects.
      final counter = _ProbeCounter();
      final box = freshBox();
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          persistState: false,
          earlyExit: false,
          cadenceMode: CadenceMode.tieredMobile,
          additionalSources: [
            _CountingSource(box, id: 'nts:a', groupId: 'g1', counter: counter),
            _CountingSource(box, id: 'nts:b', groupId: 'g2', counter: counter),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      final impl = TrustedTimeImpl.instance;

      // The bootstrap establish cycle queried the sources; only
      // post-init probe getTime() calls are relevant to the guard.
      counter.count = 0;

      // Two foreground resumes dispatched in the same synchronous turn.
      // The first drives _runValidateCycle to its first await — setting
      // the in-flight flag before yielding — so the second must observe
      // the flag and return before issuing any probe getTime() call.
      const bg1 = Duration(hours: 5);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused, elapsed: bg1);
      impl.debugHandleAppLifecycleState(
        AppLifecycleState.resumed,
        elapsed: bg1 + const Duration(minutes: 20),
      );
      const bg2 = Duration(hours: 10);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused, elapsed: bg2);
      impl.debugHandleAppLifecycleState(
        AppLifecycleState.resumed,
        elapsed: bg2 + const Duration(minutes: 20),
      );

      await Future.delayed(const Duration(milliseconds: 30));

      // Both resumes register as attempts, but the guard let only one
      // probe reach a source: a single getTime() call, not two
      // overlapping probes contending on shared per-source state.
      expect(impl.debugValidateCycleCount, 2);
      expect(counter.count, 1);
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
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

    tearDown(() {
      // Restore the file-level default handlers so sibling groups keep
      // the null-storage / fixed-uptime behaviour they were written
      // against.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storageChannel, (call) async => null);
      messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 1000;
        return null;
      });
    });

    Future<_ProbeCounter> initWithPersistedAnchor() async {
      final counter = _ProbeCounter();
      final box = _MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          earlyExit: false,
          additionalSources: [
            _CountingSource(box, id: 'ntp:a', groupId: 'g1', counter: counter),
            _CountingSource(box, id: 'ntp:b', groupId: 'g2', counter: counter),
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

  group('drift correction (assessment drift fields)', () {
    // End-to-end coverage of the passive drift pipeline: persisted
    // drift history is restored on init, the warm-restored anchor is
    // deduped against it, and getAssessment() surfaces driftRate /
    // driftCorrectedTime only when the *current boot's* record spans
    // at least an hour.
    const anchorKeyPrefix = 'tt_anchor_';
    const historyKeyPrefix = 'tt_drift_history_';

    final persistedUtc = DateTime.utc(2023, 6, 1).millisecondsSinceEpoch;
    // Anchor uptime is chosen so a 2h-earlier first observation still
    // has positive uptime, and the mocked current uptime sits above
    // the anchor's so the legacy monotonic inequality honours it.
    const anchorUptimeMs = 7201720;
    const currentUptimeMs = 8000000;

    final persistedAnchorJson = jsonEncode(
      TrustAnchor(
        networkUtcMs: persistedUtc,
        uptimeMs: anchorUptimeMs,
        wallMs: persistedUtc,
        uncertaintyMs: 10,
        bootId: 'boot-A',
      ).toJson(),
    );

    void installChannelMocks({required String historyJson}) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method == 'read') {
          final key = (call.arguments as Map)['key'] as String?;
          if (key != null && key.startsWith(anchorKeyPrefix)) {
            return persistedAnchorJson;
          }
          if (key != null && key.startsWith(historyKeyPrefix)) {
            return historyJson;
          }
        }
        return null;
      });
      messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return currentUptimeMs;
        if (call.method == 'getBootId') return 'boot-A';
        return null;
      });
    }

    tearDown(() {
      // Restore the file-level default handlers for sibling groups.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storageChannel, (call) async => null);
      messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 1000;
        return null;
      });
    });

    Future<void> initWarmRestored() async {
      final box = _MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          ntpServers: const [],
          ntsServers: const [],
          earlyExit: false,
          additionalSources: [
            _BoxedSource(box, id: 'ntp:a', groupId: 'g1'),
            _BoxedSource(box, id: 'ntp:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
    }

    /// A current-boot history record whose latest pair matches the
    /// persisted anchor exactly (so the warm re-apply dedups) and whose
    /// first observation sits [span] earlier on both timelines, skewed
    /// by [driftMs] on the uptime axis.
    String historyRecord({required Duration span, required int driftMs}) {
      final spanMs = span.inMilliseconds;
      return jsonEncode([
        DriftBootRecord(
          bootId: 'boot-A',
          firstUptimeMs: anchorUptimeMs - spanMs - driftMs,
          firstNetworkUtcMs: persistedUtc - spanMs,
          lastUptimeMs: anchorUptimeMs,
          lastNetworkUtcMs: persistedUtc,
          anchorCount: 2,
        ).toJson(),
      ]);
    }

    test(
      'no drift fields when the current boot span is under an hour',
      () async {
        installChannelMocks(
          historyJson: historyRecord(
            span: const Duration(minutes: 30),
            driftMs: 2,
          ),
        );

        await initWarmRestored();

        final assessment = TrustedTime.getAssessment();
        expect(assessment.time, isNotNull);
        expect(assessment.driftRate, isNull);
        expect(assessment.driftCorrectedTime, isNull);
        // The restored record is exposed, deduped against the re-applied
        // warm anchor (anchorCount stays 2).
        final history = TrustedTime.getDriftHistory();
        expect(history, hasLength(1));
        expect(history.single.anchorCount, 2);
      },
    );

    test('a >=1h current-boot span yields driftRate and a corrected '
        'projection', () async {
      // 720 ms of uptime excess over a 2h network span: +100 ppm.
      installChannelMocks(
        historyJson: historyRecord(
          span: const Duration(hours: 2),
          driftMs: 720,
        ),
      );

      await initWarmRestored();

      final assessment = TrustedTime.getAssessment();
      expect(assessment.driftRate, isNotNull);
      expect(assessment.driftRate!, closeTo(0.0001, 1e-9));
      // Both fields derive from the one elapsed read in the snapshot:
      // corrected == anchor + anchorAge/(1+rate), against the same
      // anchorAge that produced time == anchor + anchorAge.
      final elapsedMs = assessment.anchorAge!.inMilliseconds;
      expect(assessment.time!.millisecondsSinceEpoch, persistedUtc + elapsedMs);
      expect(
        assessment.driftCorrectedTime!.millisecondsSinceEpoch,
        persistedUtc + (elapsedMs / (1 + assessment.driftRate!)).round(),
      );
    });

    test(
      'a prior boot\'s record is never applied to the live anchor',
      () async {
        // Same >=1h, +100ppm record, but keyed to a previous boot: the
        // live anchor (boot-A) must open a fresh zero-span record instead
        // of inheriting the old rate.
        final oldBoot = jsonEncode([
          DriftBootRecord(
            bootId: 'boot-old',
            firstUptimeMs: 0,
            firstNetworkUtcMs: persistedUtc - 7200000,
            lastUptimeMs: 7200720,
            lastNetworkUtcMs: persistedUtc,
            anchorCount: 5,
          ).toJson(),
        ]);
        installChannelMocks(historyJson: oldBoot);

        await initWarmRestored();

        final assessment = TrustedTime.getAssessment();
        expect(assessment.time, isNotNull);
        expect(assessment.driftRate, isNull);
        expect(assessment.driftCorrectedTime, isNull);
        // History keeps the prior boot for diagnostics and opened a new
        // record for the current boot.
        final history = TrustedTime.getDriftHistory();
        expect(history, hasLength(2));
        expect(history.first.bootId, 'boot-old');
        expect(history.last.bootId, 'boot-A');
        expect(history.last.anchorCount, 1);
      },
    );

    test(
      'an implausible persisted rate is never applied to the projection',
      () async {
        // Persisted history is only syntactically validated, so a
        // parseable-but-corrupt record can carry an absurd rate. Here
        // a 2h span with 1h of uptime excess yields +500000 ppm — far
        // beyond the 200 ppm sanity bound — so correction must be
        // withheld while the record stays visible as diagnostics.
        installChannelMocks(
          historyJson: historyRecord(
            span: const Duration(hours: 2),
            driftMs: 3600000,
          ),
        );

        await initWarmRestored();

        final assessment = TrustedTime.getAssessment();
        expect(assessment.time, isNotNull);
        expect(assessment.driftRate, isNull);
        expect(assessment.driftCorrectedTime, isNull);
        final history = TrustedTime.getDriftHistory();
        expect(history, hasLength(1));
        expect(history.single.observedDriftRate, closeTo(0.5, 1e-9));
      },
    );
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

    tearDown(() {
      // Restore the file-level default handlers for sibling groups.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(storageChannel, (call) async => null);
      messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
        if (call.method == 'getUptimeMs') return 1000;
        return null;
      });
    });

    test('warm restore completes without waiting on source warm-up', () {
      fakeAsync((async) {
        TrustedTimeImpl? impl;
        unawaited(
          TrustedTimeImpl.init(
            TrustedTimeConfig(
              ntpServers: const [],
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
              ntpServers: [],
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
              ntpServers: const [],
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
            const TrustedTimeConfig(ntpServers: [], ntsServers: []),
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
      ntpServers: [],
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
            _GatedSource(gate, id: 'nts:a', groupId: 'g1'),
            _GatedSource(gate, id: 'nts:b', groupId: 'g2'),
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
            _FailingSource(id: 'nts:a', groupId: 'g1'),
            _FailingSource(id: 'nts:b', groupId: 'g2'),
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
            _GatedSource(gate, id: 'nts:a', groupId: 'g1'),
            _GatedSource(gate, id: 'nts:b', groupId: 'g2'),
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
        final counter = _ProbeCounter();
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
            _GatedThenBoxedSource(
              () => firstCycleDone,
              gate,
              id: 'nts:a',
              groupId: 'g1',
            ),
            _GatedThenBoxedSource(
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

  final _ProbeCounter counter;
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

/// Minimal [SyncObserver] that just counts onSyncStarted invocations,
/// used to verify the proxy observer fan-out works on the first init.
class _SyncStartedProbe implements SyncObserver {
  int startCount = 0;

  @override
  void onSyncStarted() => startCount++;

  @override
  void onSampleReceived(TimeSample sample) {}

  @override
  void onSourceFailed(String sourceId, Object error) {}

  @override
  void onConsensusReached(ConsensusResult result) {}

  @override
  void onMetricsReported(SyncMetrics metrics) {}

  @override
  void onSyncFailed(Object error) {}
}

/// Mutable midpoint shared by establish and probe queries so a test can
/// move "network time" between the two phases.
class _MidpointBox {
  _MidpointBox(this.midpointMs);
  int midpointMs;
}

/// Shared getTime() tally so an overlap test can count how many probe
/// queries actually executed independently of which ranked source the
/// validate tier selected.
class _ProbeCounter {
  int count = 0;
}

/// A [_BoxedSource] variant that tallies every getTime() call into a
/// shared [_ProbeCounter], used to prove the validate-in-flight guard
/// stops a second overlapping probe burst from reaching a source.
class _CountingSource implements TimeSource {
  _CountingSource(
    this._box, {
    required this.id,
    required this.groupId,
    required this.counter,
  });

  final _MidpointBox _box;
  @override
  final String id;
  @override
  final String groupId;
  final _ProbeCounter counter;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async {
    counter.count++;
    return TimeSample(
      interval: TimeInterval(
        startMs: _box.midpointMs - halfWidthMs,
        endMs: _box.midpointMs + halfWidthMs,
      ),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// A [TimeSource] whose every query throws, driving the engine into a
/// quorum failure — the transient classification path.
class _FailingSource implements TimeSource {
  _FailingSource({required this.id, required this.groupId});

  @override
  final String id;
  @override
  final String groupId;

  @override
  Future<TimeSample> getTime() async => throw Exception('unreachable host');
}

/// A [_BoxedSource] variant with a mutable [authLevel], so a test can
/// establish a verified anchor and then downgrade the same sources for
/// the freshness probe (the trusted_time-wba posture test).
class _AuthBoxedSource implements TimeSource {
  _AuthBoxedSource(
    this._box, {
    required this.id,
    required this.groupId,
    required this.authLevel,
  });

  final _MidpointBox _box;
  @override
  final String id;
  @override
  final String groupId;
  NtsAuthLevel authLevel;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(
      startMs: _box.midpointMs - halfWidthMs,
      endMs: _box.midpointMs + halfWidthMs,
    ),
    sourceId: id,
    groupId: groupId,
    authLevel: authLevel,
  );
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

/// A [TimeSource] blocked on an external gate, letting a test hold the
/// first sync cycle in flight and release it deterministically.
class _GatedSource implements TimeSource {
  _GatedSource(this._gate, {required this.id, required this.groupId});

  final Completer<void> _gate;
  @override
  final String id;
  @override
  final String groupId;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async {
    await _gate.future;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(
        startMs: nowMs - halfWidthMs,
        endMs: nowMs + halfWidthMs,
      ),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// A [TimeSource] that answers immediately until the flag flips, then
/// blocks on the gate — so a test can establish an anchor with the
/// first cycle and hold a *subsequent* cycle in flight.
class _GatedThenBoxedSource implements TimeSource {
  _GatedThenBoxedSource(
    this._gateActive,
    this._gate, {
    required this.id,
    required this.groupId,
  });

  final bool Function() _gateActive;
  final Completer<void> _gate;
  @override
  final String id;
  @override
  final String groupId;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async {
    if (_gateActive()) await _gate.future;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return TimeSample(
      interval: TimeInterval(
        startMs: nowMs - halfWidthMs,
        endMs: nowMs + halfWidthMs,
      ),
      sourceId: id,
      groupId: groupId,
    );
  }
}

/// A [TimeSource] that reports an interval centred on a [_MidpointBox]
/// so the validate-tier offset comparison can be driven
/// deterministically.
class _BoxedSource implements TimeSource {
  _BoxedSource(this._box, {required this.id, required this.groupId});

  final _MidpointBox _box;
  @override
  final String id;
  @override
  final String groupId;
  static const int halfWidthMs = 10;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(
      startMs: _box.midpointMs - halfWidthMs,
      endMs: _box.midpointMs + halfWidthMs,
    ),
    sourceId: id,
    groupId: groupId,
  );
}
