import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';
import 'package:trusted_time/trusted_time.dart';

import 'support/channel_mocks.dart';
import 'support/fake_observers.dart';
import 'support/fake_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useDefaultChannelHandlers();

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
            disableNtpForTesting: true,
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
            disableNtpForTesting: true,
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
          disableNtpForTesting: true,
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
          disableNtpForTesting: true,
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
            disableNtpForTesting: true,
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
          disableNtpForTesting: true,
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
            disableNtpForTesting: true,
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

  group('TrustedTime resume anchor-age check', () {
    // Live-engine tests; clear any override left by earlier groups so the
    // static surface drops into the real TrustedTimeImpl singleton. This
    // must run in setUp, not tearDown: a leftover override has to be gone
    // before the first test in this group executes.
    setUp(TrustedTime.resetOverride);

    MidpointBox freshBox() =>
        MidpointBox(DateTime.utc(2024, 6, 15, 12).millisecondsSinceEpoch);

    Future<void> initWithAnchor(MidpointBox box) async {
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: const [],
          persistState: false,
          earlyExit: false,
          additionalSources: [
            BoxedSource(box, id: 'nts:a', groupId: 'g1'),
            BoxedSource(box, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      // Resolving the singleton at teardown time is deliberate: if a
      // test re-initializes, init() itself disposes the prior instance
      // and dispose() is idempotent, so this closure always tears down
      // whichever engine is live. A captured reference would instead
      // leak the replacement.
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      // These tests assert on the bootstrap cycle's concluded anchor;
      // wait for the detached cycle to settle.
      await TrustedTime.firstSyncSettled;
    }

    SyncStartedProbe registerProbe() {
      final probe = SyncStartedProbe();
      TrustedTime.registerObserver(probe);
      addTearDown(() => TrustedTime.unregisterObserver(probe));
      return probe;
    }

    // Settles a fire-and-forget resume dispatch deterministically. The
    // dispatch starts its cycle synchronously (onSyncStarted is emitted
    // before _performSync's first await), so after one event-queue
    // drain the probe count reflects whether a cycle began; the loop
    // then drains until any in-flight cycle concludes (syncInProgress
    // is cleared in _performSync's finally, after the trust posture is
    // written). No fixed real-time delay is assumed — a slow or loaded
    // runner simply loops longer. Not usable while a deliberately
    // gated cycle is in flight (it would spin until the test times
    // out); those tests drain the queue once instead.
    Future<void> settleSyncActivity() async {
      await pumpEventQueue();
      while (TrustedTime.getAssessment().syncInProgress) {
        await pumpEventQueue();
      }
    }

    test('the lifecycle observer is installed at bootstrap', () async {
      await initWithAnchor(freshBox());
      expect(TrustedTimeImpl.instance.debugLifecycleObserverInstalled, isTrue);
    });

    test('a resume with a fresh anchor does not sync', () async {
      await initWithAnchor(freshBox());
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      final probe = registerProbe();

      // The anchor was just established, so its age (milliseconds) is
      // far below the default 48h refresh interval. A resume-triggered
      // cycle would emit onSyncStarted synchronously inside the
      // dispatch; the settle just rules out any deferred start too.
      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();

      expect(probe.startCount, 0);
    });

    test('a resume with a stale anchor runs a full sync', () async {
      await initWithAnchor(freshBox());
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);

      // Shrink the staleness bound to 1ms instead of faking the
      // monotonic clock, then let real time carry the anchor past it
      // (age is measured in whole milliseconds). Cancel the refresh
      // timer the setter arms — without pausing the schedule, since
      // pause suppresses the resume trigger too — so the sync we
      // observe can only come from the resume trigger.
      impl.setRefreshInterval(const Duration(milliseconds: 1));
      impl.debugCancelRefreshTimer();
      final probe = registerProbe();
      await Future.delayed(const Duration(milliseconds: 10));

      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      // The dispatch has already evaluated staleness against the 1ms
      // bound and synchronously begun its cycle. Widen the interval
      // before settling: the success path re-arms the refresh timer
      // from _activeRefreshInterval, and a still-live 1ms schedule
      // would let that timer fire mid-drain on a slow runner and
      // cascade extra cycles into the probe count.
      impl.setRefreshInterval(const Duration(days: 1));
      await settleSyncActivity();

      expect(probe.startCount, 1);
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
    });

    test('pauseAutomaticRefresh suppresses the anchored resume '
        'staleness check', () async {
      // automaticRefreshActive == false must mean *no* anchor-age-
      // driven syncs — timer and resume trigger alike. Same stale-
      // anchor setup as the positive test above, but paused: the
      // resume must not start a cycle.
      await initWithAnchor(freshBox());
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);

      impl.setRefreshInterval(const Duration(milliseconds: 1));
      impl.pauseAutomaticRefresh();
      expect(impl.automaticRefreshActive, isFalse);
      final probe = registerProbe();
      await Future.delayed(const Duration(milliseconds: 10));

      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();

      expect(probe.startCount, 0);

      // Resuming the schedule restores the trigger: the anchor is
      // still stale against the 1ms bound, so the same dispatch now
      // starts a cycle.
      impl.resumeAutomaticRefresh();
      impl.debugCancelRefreshTimer();
      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      // Same re-arm hazard as the positive test above: the cycle is
      // already in flight, so widen the interval before settling to
      // keep the success path's re-armed timer from cascading.
      impl.setRefreshInterval(const Duration(days: 1));
      await settleSyncActivity();

      expect(probe.startCount, 1);
    });

    test('pauseAutomaticRefresh still allows the unanchored establish '
        'attempt on resume', () async {
      // Pause only opts out of anchor-age-driven cadence; a resume
      // with no anchor is an establish attempt and must proceed.
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: [],
          persistState: false,
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      impl.pauseAutomaticRefresh();
      final probe = registerProbe();

      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();

      expect(probe.startCount, 1);
    });

    test('a resume with no anchor at all runs a full sync', () async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: [],
          persistState: false,
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      final probe = registerProbe();

      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();

      expect(probe.startCount, 1);
    });

    test('a non-positive refreshInterval disables the anchored resume '
        'staleness check', () async {
      // Opting out of automatic refresh (non-positive interval at
      // init) must silence the resume trigger too for an anchored
      // engine; otherwise `age < interval` could never hold and every
      // resume would resync. The unanchored establish path is pinned
      // separately below.
      final box = freshBox();
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: const [],
          persistState: false,
          earlyExit: false,
          refreshInterval: Duration.zero,
          additionalSources: [
            BoxedSource(box, id: 'nts:a', groupId: 'g1'),
            BoxedSource(box, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isTrue);
      final probe = registerProbe();

      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();

      expect(probe.startCount, 0);
    });

    test('a non-positive refreshInterval still allows the unanchored '
        'establish attempt on resume', () async {
      await TrustedTime.initialize(
        config: const TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: [],
          persistState: false,
          refreshInterval: Duration.zero,
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      await TrustedTime.firstSyncSettled;
      final impl = TrustedTimeImpl.instance;
      expect(TrustedTime.getAssessment().isTrusted, isFalse);
      final probe = registerProbe();

      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();

      expect(probe.startCount, 1);
    });

    test('non-resumed lifecycle states never sync', () async {
      await initWithAnchor(freshBox());
      final impl = TrustedTimeImpl.instance;
      impl.setRefreshInterval(const Duration(microseconds: 1));
      impl.debugCancelRefreshTimer();
      final probe = registerProbe();

      // Even with a stale anchor, only `resumed` triggers the check.
      impl.debugHandleAppLifecycleState(AppLifecycleState.inactive);
      impl.debugHandleAppLifecycleState(AppLifecycleState.paused);
      impl.debugHandleAppLifecycleState(AppLifecycleState.hidden);
      await settleSyncActivity();

      expect(probe.startCount, 0);
    });

    test('a resume during an in-flight sync does not start a second '
        'cycle', () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      await TrustedTime.initialize(
        config: TrustedTimeConfig(
          disableNtpForTesting: true,
          ntsServers: const [],
          persistState: false,
          earlyExit: false,
          additionalSources: [
            GatedSource(gate, id: 'nts:a', groupId: 'g1', entered: entered),
            GatedSource(gate, id: 'nts:b', groupId: 'g2'),
          ],
        ),
      );
      addTearDown(() => TrustedTimeImpl.instance.dispose());
      final impl = TrustedTimeImpl.instance;

      // The detached bootstrap cycle is scheduled by initialize() but
      // not ordered against it; await the gated source's entry signal
      // so the cycle has provably emitted onSyncStarted and armed the
      // in-flight guard before the probe is registered. From here any
      // count observed below can only come from a second cycle.
      await entered.future;
      expect(TrustedTime.getAssessment().syncInProgress, isTrue);
      final probe = registerProbe();

      // A second cycle would emit onSyncStarted synchronously inside
      // this dispatch (nothing yields before it in _performSync →
      // sync()); settleSyncActivity cannot be used here — the gated
      // bootstrap cycle is deliberately still in flight — so a single
      // event-queue drain covers any deferred start.
      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(probe.startCount, 0);

      gate.complete();
      await TrustedTime.firstSyncSettled;
    });

    test('dispose detaches the observer and a late resume dispatch is '
        'a no-op', () async {
      await initWithAnchor(freshBox());
      final impl = TrustedTimeImpl.instance;
      expect(impl.debugLifecycleObserverInstalled, isTrue);
      final probe = registerProbe();

      impl.dispose();

      expect(impl.debugLifecycleObserverInstalled, isFalse);
      impl.debugHandleAppLifecycleState(AppLifecycleState.resumed);
      await settleSyncActivity();
      expect(probe.startCount, 0);
    });
  });
}
