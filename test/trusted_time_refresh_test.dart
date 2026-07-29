import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

import 'support/channel_mocks.dart';
import 'support/fake_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useDefaultChannelHandlers();

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
          disableNtpForTesting: true,
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
          disableNtpForTesting: true,
          ntsServers: const [],
          persistState: false,
          additionalSources: [
            FailingSource(id: 'ntp:a', groupId: 'g1'),
            FailingSource(id: 'https:b', groupId: 'g2'),
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
            disableNtpForTesting: true,
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
      // Restore the file-level default handlers so sibling tests keep
      // their persistence-free behaviour.
      addTearDown(installDefaultChannelHandlers);

      final box = MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: const [],
          additionalSources: [
            BoxedSource(box, id: 'ntp:a', groupId: 'g1'),
            BoxedSource(box, id: 'https:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(TrustedTimeImpl.instance.dispose);
      await TrustedTime.firstSyncSettled;

      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      expect(TrustedTimeImpl.instance.debugRetryTimerActive, isFalse);
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

    // Restore the file-level default handlers for sibling groups.
    tearDown(installDefaultChannelHandlers);

    Future<void> initWarmRestored() async {
      final box = MidpointBox(
        DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch,
      );
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: const [],
          earlyExit: false,
          additionalSources: [
            BoxedSource(box, id: 'ntp:a', groupId: 'g1'),
            BoxedSource(box, id: 'ntp:b', groupId: 'g2'),
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

    test(
      'corrupt history whose cleanup delete also fails cannot fail init',
      () async {
        // Corruption is treated as absence so bootstrap can never fail
        // over diagnostics — including when the *cleanup* delete of the
        // corrupt entry itself throws (e.g. secure storage rejecting the
        // call). The store must swallow the delete failure and hand the
        // engine an empty history.
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(storageChannel, (call) async {
          if (call.method == 'read') {
            final key = (call.arguments as Map)['key'] as String?;
            if (key != null && key.startsWith(anchorKeyPrefix)) {
              return persistedAnchorJson;
            }
            if (key != null && key.startsWith(historyKeyPrefix)) {
              return 'not valid json {{{';
            }
          }
          if (call.method == 'delete') {
            throw PlatformException(code: 'STORAGE_UNAVAILABLE');
          }
          return null;
        });
        messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
          if (call.method == 'getUptimeMs') return currentUptimeMs;
          if (call.method == 'getBootId') return 'boot-A';
          return null;
        });

        await initWarmRestored();

        // Init survived: warm restore applied, history opened fresh for
        // the current boot only.
        final assessment = TrustedTime.getAssessment();
        expect(assessment.isTrusted, isTrue);
        expect(assessment.time!.year, 2023);
        final history = TrustedTime.getDriftHistory();
        expect(history, hasLength(1));
        expect(history.single.bootId, 'boot-A');
      },
    );
  });
}
