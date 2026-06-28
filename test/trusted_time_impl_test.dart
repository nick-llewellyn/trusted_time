import 'package:flutter/services.dart';
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
          additionalSources: [
            _BoxedSource(box, id: 'nts:a', groupId: 'g1'),
            _BoxedSource(box, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      expect(TrustedTime.isTrusted, isTrue);

      // Move the probe far outside the 5s default uncertainty window;
      // the anchor stays at the establish-time midpoint.
      box.midpointMs += 10000;
      expect(await TrustedTime.validateFreshness(), isFalse);
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
