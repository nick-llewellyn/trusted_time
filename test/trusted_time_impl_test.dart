import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/ntp_inventory.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

import 'support/channel_mocks.dart';
import 'support/fake_observers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useDefaultChannelHandlers();

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
        // Regression: ProxySyncObserver previously closed over the
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
            disableNtpForTesting: true,
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

        final probe = SyncStartedProbe();
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
            disableNtpForTesting: true,
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

        final probe = SyncStartedProbe();
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
          disableNtpForTesting: true,
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

  group('TrustedTimeConfig value equality', () {
    test('two non-const instances with identical fields compare equal', () {
      // `new TrustedTimeConfig(...)` (without `const`) defeats Dart's
      // const canonicalisation, so these are guaranteed to be distinct
      // object identities. Equality must therefore come from the new
      // operator==/hashCode, not from `identical`.
      final a = TrustedTimeConfig(
        ntsServers: const ['time.cloudflare.com'],
        refreshInterval: const Duration(minutes: 5),
        minimumQuorum: 3,
      );
      final b = TrustedTimeConfig(
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
        ntsServers: const ['time.cloudflare.com', 'mmo1.nts.netnod.se'],
        minimumQuorum: 4,
        refreshInterval: const Duration(minutes: 2),
      );
      final text = config.toString();

      expect(text, startsWith('TrustedTimeConfig('));
      // Summarised, not enumerated: the curated inventory is fixed and
      // 51 entries long.
      expect(text, contains('ntpServers: ${curatedNtpInventory.length} hosts'));
      expect(
        text,
        contains('ntsServers: [time.cloudflare.com, mmo1.nts.netnod.se]'),
      );
      expect(text, contains('minimumQuorum: 4'));
      expect(text, contains('refreshInterval: 0:02:00.000000'));
    });
  });
}
