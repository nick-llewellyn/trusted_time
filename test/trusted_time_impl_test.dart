import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
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

  const integrityChannel = MethodChannel('trusted_time/integrity');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(integrityChannel, (call) async => null);

  group('TrustedTimeImpl via mock', () {
    late TrustedTimeMock mock;

    setUp(() {
      mock = TrustedTimeMock(initial: DateTime.utc(2024, 6, 15, 12));
      TrustedTime.overrideForTesting(mock);
    });

    tearDown(() {
      TrustedTime.resetOverride();
      mock.dispose();
    });

    test('isTrusted becomes false after clock jump event', () async {
      expect(TrustedTime.isTrusted, isTrue);

      mock.simulateTampering(TamperReason.systemClockJumped);
      await Future.delayed(Duration.zero);

      expect(TrustedTime.isTrusted, isFalse);
    });

    test('isTrusted becomes false after reboot event', () async {
      expect(TrustedTime.isTrusted, isTrue);

      mock.simulateReboot();
      await Future.delayed(Duration.zero);

      expect(TrustedTime.isTrusted, isFalse);
    });

    test('onIntegrityLost stream emits events with correct reason', () async {
      final events = <IntegrityEvent>[];
      final sub = TrustedTime.onIntegrityLost.listen(events.add);

      mock.simulateTampering(
        TamperReason.systemClockJumped,
        drift: const Duration(minutes: 3),
      );
      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.reason, TamperReason.systemClockJumped);
      expect(events.first.drift, const Duration(minutes: 3));

      await sub.cancel();
    });

    test('restoreTrust re-enables isTrusted after reboot', () {
      mock.simulateReboot();
      expect(TrustedTime.isTrusted, isFalse);
      mock.restoreTrust();
      expect(TrustedTime.isTrusted, isTrue);
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

    test('nowEstimated returns estimate with full confidence when trusted', () {
      final estimate = TrustedTime.nowEstimated();
      expect(estimate, isNotNull);
      expect(estimate!.confidence, 1.0);
      expect(estimate.estimatedError, Duration.zero);
    });

    test('nowEstimated returns decaying estimate after reboot', () {
      mock.simulateReboot();
      final estimate = TrustedTime.nowEstimated();
      expect(estimate, isNotNull);
      expect(estimate!.confidence, 1.0);
    });

    test('nowEstimated returns null when untrusted without reboot data', () {
      mock.simulateTampering(TamperReason.systemClockJumped);
      final estimate = TrustedTime.nowEstimated();
      expect(estimate, isNull);
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
            httpsSources: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        // Cancel the engine's retry timer at teardown so the failed
        // bootstrap (no-quorum) can't fire a stray _performSync into
        // a sibling test in this suite.
        addTearDown(TrustedTimeImpl.instance.dispose);

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
            httpsSources: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);

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
          httpsSources: [],
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
      addTearDown(mock.dispose);
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
            httpsSources: [],
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
            httpsSources: [],
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
          httpsSources: [],
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
      addTearDown(mock.dispose);
      TrustedTime.overrideForTesting(mock);

      expect(TrustedTime.isProjectionSleepAware, isTrue);
    });

    test('a failed fail-fast initialize() leaves no stale singleton', () async {
      // First, a successful init installs a live singleton.
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          httpsSources: [],
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
            httpsSources: [],
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
          httpsSources: [],
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
            httpsSources: [],
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
          httpsSources: [],
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
        addTearDown(mock.dispose);
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
          httpsSources: const [],
          ntsServers: const [],
          persistState: false,
          additionalSources: [
            _FailingSource(id: 'ntp:a', groupId: 'g1'),
            _FailingSource(id: 'https:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);

      expect(TrustedTime.isTrusted, isFalse);
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
            httpsSources: [],
            ntsServers: [],
            persistState: false,
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);

        expect(TrustedTime.isTrusted, isFalse);
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
          httpsSources: const [],
          ntsServers: const [],
          additionalSources: [
            _BoxedSource(box, id: 'ntp:a', groupId: 'g1'),
            _BoxedSource(box, id: 'https:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);

      expect(TrustedTime.isTrusted, isFalse);
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
        httpsSources: const ['https://example.com'],
        ntsServers: const ['time.cloudflare.com'],
        refreshInterval: const Duration(minutes: 5),
        minimumQuorum: 3,
      );
      final b = TrustedTimeConfig(
        ntpServers: const ['pool.ntp.org'],
        httpsSources: const ['https://example.com'],
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
        httpsSources: const ['https://example.com'],
        ntsServers: const ['time.cloudflare.com', 'mmo1.nts.netnod.se'],
        minimumQuorum: 4,
        refreshInterval: const Duration(minutes: 2),
      );
      final text = config.toString();

      expect(text, startsWith('TrustedTimeConfig('));
      expect(text, contains('ntpServers: [pool.ntp.org]'));
      expect(text, contains('httpsSources: [https://example.com]'));
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
      addTearDown(mock.dispose);
      TrustedTime.overrideForTesting(mock);

      expect(await TrustedTime.validateFreshness(), isTrue);

      mock.simulateTampering(TamperReason.systemClockJumped);
      expect(TrustedTime.isTrusted, isFalse);
      expect(await TrustedTime.validateFreshness(), isFalse);
    });

    test('throws TrustedTimeFreshnessProbeException when no anchor is '
        'established', () async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          httpsSources: [],
          ntsServers: [],
          persistState: false,
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);

      expect(TrustedTime.isTrusted, isFalse);
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
            httpsSources: const [],
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

        expect(TrustedTime.isTrusted, isTrue);
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
            httpsSources: const [],
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

        expect(TrustedTime.isTrusted, isTrue);
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
            httpsSources: const [],
            ntsServers: const [],
            persistState: false,
            earlyExit: false,
            additionalSources: [a, b],
          ),
        );
        addTearDown(TrustedTimeImpl.instance.dispose);

        // The establish cycle built a Tier 1 (verified) anchor.
        expect(TrustedTime.isTrusted, isTrue);
        expect(TrustedTime.authLevel, NtsAuthLevel.verified);

        // Downgrade both sources so the probe sample reports `none`,
        // then confirm the probe still re-validates the verified anchor.
        a.authLevel = NtsAuthLevel.none;
        b.authLevel = NtsAuthLevel.none;
        expect(await TrustedTime.validateFreshness(), isTrue);
        expect(TrustedTime.authLevel, NtsAuthLevel.verified);
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
          httpsSources: const [],
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
      expect(TrustedTime.isTrusted, isTrue);

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
          httpsSources: const [],
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
      addTearDown(() => TrustedTimeImpl.instance.dispose());
    }

    Future<void> initSingleTier() async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          ntpServers: [],
          httpsSources: [],
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
      expect(TrustedTime.isTrusted, isTrue);
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
        expect(TrustedTime.isTrusted, isTrue);
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
          httpsSources: const [],
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
      expect(TrustedTime.isTrusted, isTrue);
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
    // restore-vs-resync outcome is observable through TrustedTime.now()
    // as well as through whether any source was queried at all.
    // Match the AnchorStore anchor key by stable prefix rather than the
    // exact versioned literal (currently tt_anchor_v2) so a key version
    // bump does not silently turn this into a cold start. The prefix is
    // unambiguous: the store's other keys live under tt_last_*.
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
          httpsSources: const [],
          ntsServers: const [],
          earlyExit: false,
          additionalSources: [
            _CountingSource(box, id: 'ntp:a', groupId: 'g1', counter: counter),
            _CountingSource(box, id: 'ntp:b', groupId: 'g2', counter: counter),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      return counter;
    }

    test('boot-ID mismatch discards the persisted anchor and forces a '
        'fresh network sync', () async {
      installChannelMocks(currentBootId: 'boot-B');

      final counter = await initWithPersistedAnchor();

      expect(TrustedTime.isTrusted, isTrue);
      // The rejected restore fell through to _performSync: the network
      // sources were queried and the resulting anchor reflects their
      // 2024 consensus, not the 2023 anchor persisted under boot-A.
      expect(counter.count, greaterThan(0));
      expect(TrustedTime.now().year, 2024);
    });

    test('matching boot ID warm-restores the persisted anchor without '
        'touching the network', () async {
      // Control: identical setup except the identity matches, proving
      // the mismatch test's fresh sync is attributable to the boot-ID
      // gate rather than to some other rejection of the fixture.
      installChannelMocks(currentBootId: 'boot-A');

      final counter = await initWithPersistedAnchor();

      expect(TrustedTime.isTrusted, isTrue);
      expect(counter.count, 0);
      expect(TrustedTime.now().year, 2023);
    });
  });
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
