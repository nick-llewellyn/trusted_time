import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trusted_time_example/main.dart';
import 'package:trusted_time_example/sync_telemetry.dart';
import 'package:trusted_time/trusted_time.dart';

/// Deterministic [TimeSource] used by the real-engine widget test to
/// guarantee the bootstrap sync reaches consensus instead of failing
/// and arming an exponential retry timer that would leak into sibling
/// tests. Two instances with distinct [groupId]s are passed via
/// [TrustedTimeConfig.additionalSources] so MarzulloEngine sees a
/// pair of overlapping samples (its hard floor for consensus is two
/// independent groups).
class _FakeTimeSource implements TimeSource {
  _FakeTimeSource({required this.id, required this.groupId});

  @override
  final String id;

  @override
  final String groupId;

  @override
  Future<TimeSample> getTime() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // ±50 ms window around wall-clock now: wide enough that two
    // fakes sampled in the same async tick will overlap reliably,
    // narrow enough not to mask any real bug that ever lets these
    // samples slip through into a production-bound code path.
    return TimeSample(
      interval: TimeInterval(startMs: now - 50, endMs: now + 50),
      sourceId: id,
      groupId: groupId,
    );
  }
}

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

  testWidgets('Example app renders TrustedTime V2 Features title', (
    WidgetTester tester,
  ) async {
    final mock = TrustedTimeMock(initial: DateTime.utc(2024, 1, 1, 12));
    // Register cleanup before the override so a failed expectation
    // in the test body cannot leak the override into sibling tests.
    addTearDown(TrustedTime.resetOverride);
    TrustedTime.overrideForTesting(mock);

    await tester.pumpWidget(MyApp(telemetry: TelemetryRecorder()));
    // Two pumps lay out the SingleChildScrollView and its eagerly
    // built children; pumpAndSettle would block on _HomePageState's
    // 1 s UI ticker (Timer.periodic in initState) which never
    // naturally idles. Mirrors the bounded-pump strategy used by
    // the real-engine test below.
    await tester.pump();
    await tester.pump();

    expect(find.text('TrustedTime V2 Features'), findsOneWidget);
    expect(find.text('Section 1 — Live Clock'), findsOneWidget);
  });

  testWidgets('Section 7 FilterChips reflect TrustedTime.config.ntsServers', (
    WidgetTester tester,
  ) async {
    // Widget-layer contract test. Pins that _BenchmarkingPanel's
    // FilterChip selection state is derived from
    // `TrustedTime.config.ntsServers` and nothing else. Uses the
    // override path so the assertion targets the widget code
    // exclusively without depending on engine behaviour. The
    // companion test below exercises the same code path against
    // the real TrustedTimeImpl.
    final mock = TrustedTimeMock(initial: DateTime.utc(2024, 1, 1, 12));
    addTearDown(TrustedTime.resetOverride);
    TrustedTime.overrideForTesting(mock);

    // Under an override, TrustedTime.config returns
    // `const TrustedTimeConfig()`. Snapshot the active host set off
    // the live getter rather than hard-coding it, so the assertion
    // automatically tracks any future change to the default
    // ntsServers list in TrustedTimeConfig's constructor.
    final activeServers = TrustedTime.config.ntsServers.toSet();
    expect(
      activeServers,
      isNotEmpty,
      reason:
          'Default TrustedTimeConfig.ntsServers must seed at '
          'least one host for this test to be meaningful',
    );

    await tester.pumpWidget(MyApp(telemetry: TelemetryRecorder()));
    // Bounded pumps for the same reason as the sibling test above:
    // _HomePageState's 1 s UI ticker prevents pumpAndSettle from
    // ever returning. Two pumps are enough to lay out Section 7.
    await tester.pump();
    await tester.pump();

    final chipFinder = find.byType(FilterChip);
    expect(chipFinder, findsWidgets);

    // The chip pool is the static union of curated + extended pools
    // (see nts_sources.dart), so the rendered chip count is
    // strictly greater than the active server count.
    final chips = tester.widgetList<FilterChip>(chipFinder).toList();
    final renderedSelection = <String, bool>{
      for (final chip in chips) (chip.label as Text).data!: chip.selected,
    };

    // Every active host must be present and selected. Every other
    // rendered chip must be unselected. Together these pin the
    // bidirectional sync between the engine config (via the public
    // TrustedTime.config getter) and the UI.
    for (final host in activeServers) {
      expect(
        renderedSelection[host],
        isTrue,
        reason: 'Active host $host must be a selected chip',
      );
    }
    for (final entry in renderedSelection.entries) {
      final shouldBeSelected = activeServers.contains(entry.key);
      expect(
        entry.value,
        shouldBeSelected,
        reason:
            'Chip ${entry.key} selected=${entry.value} '
            'does not match TrustedTime.config.ntsServers',
      );
    }
  });

  testWidgets(
    'real engine: chips reflect TrustedTime.config after initialize',
    timeout: const Timeout(Duration(seconds: 30)),
    (WidgetTester tester) async {
      // End-to-end integration test: drive the actual TrustedTimeImpl
      // (no override) through TrustedTime.initialize, then verify the
      // chip selection rendered by _BenchmarkingPanel mirrors whatever
      // TrustedTime.config.ntsServers reports back.
      //
      // The engine's network I/O is run via tester.runAsync so its
      // real timers and stream subscriptions execute on the host
      // event loop instead of fighting flutter_test's FakeAsync zone.
      // NtsRustLib.init may fail in the test environment, in which case
      // TrustedTime.initialize rewrites ntsServers to []. The
      // assertion is robust to either outcome — it pins
      // "chips == TrustedTime.config.ntsServers" rather than
      // "chips == requested ntsServers" — so the test passes whether
      // or not the bundled Rust dylib is available.
      //
      // Hermetic-CI design notes:
      //  - With NtsRustLib unavailable (the standard `flutter test` host
      //    environment), initialize() rewrites ntsServers to []. The
      //    two _FakeTimeSource instances in additionalSources keep
      //    the engine's source pool non-empty so the bootstrap sync
      //    reaches consensus, succeeds, and does not arm the
      //    exponential retry timer that would otherwise leak into
      //    sibling tests for the rest of the suite.
      //  - With NtsRustLib available (rare in `flutter test`; expected
      //    in `flutter test integration_test/`), initialize() will
      //    attempt three NTS-KE handshakes alongside the two fake
      //    samples. The bounded 30 s timeout surfaces a wedged
      //    handshake as a test failure rather than an indefinite
      //    hang.
      //  - refreshInterval is set to 1 hour so even after a
      //    successful bootstrap the automatic refresh timer cannot
      //    fire during the test body, eliminating one more source of
      //    pending async work for pumpWidget to deal with.
      //  - addTearDown also pauses automatic refresh as belt-and-
      //    braces in case a future change to the test makes the
      //    bootstrap take longer than the test body.
      TrustedTime.resetOverride();
      addTearDown(TrustedTime.resetOverride);

      const requested = [
        'time.cloudflare.com',
        'mmo1.nts.netnod.se',
        'ohio.time.system76.com',
      ];

      await tester.runAsync(() async {
        await TrustedTime.initialize(
          config: TrustedTimeConfig(
            disableNtpForTesting: true,
            ntsServers: requested,
            // Two distinct group ids so MarzulloEngine treats them as
            // independent samples and consensus is reachable on the
            // bootstrap cycle even when ntsServers is stripped to []
            // by the NtsRustLib-unavailable path.
            additionalSources: [
              _FakeTimeSource(id: 'fake:a', groupId: 'fake-a'),
              _FakeTimeSource(id: 'fake:b', groupId: 'fake-b'),
            ],
            minimumQuorum: 2,
            // Ratio 1.0 over 2 sources lifts MarzulloEngine's
            // requiredQuorum to 2 (ceil(2 * 1.0) == 2). The default
            // 0.4 used by the production benchmarking code would
            // produce ceil(2 * 0.4) == 1, which trips the engine's
            // hard "requiredQuorum < 2 → return null" floor and
            // reproduces exactly the failure mode this test is
            // trying to avoid. With three or more real sources the
            // 0.4 ratio reaches 2 naturally; we use a tighter ratio
            // here purely to satisfy the floor with two fakes.
            minQuorumRatio: 1.0,
            // Long enough that the automatic refresh timer cannot
            // fire during the test body, eliminating one source of
            // pending async work for pumpWidget to deal with.
            refreshInterval: const Duration(hours: 1),
            persistState: false,
          ),
        );
      });
      // Belt-and-braces: even if a future change to the test ever
      // makes the bootstrap fail (e.g. network-only sources added
      // back without a fake), pausing the automatic refresh and
      // setting the interval to zero ensure no scheduled work
      // outlives the test. The retry timer is not affected by these
      // calls (see TrustedTime.pauseAutomaticRefresh docs), but
      // additionalSources above is what actually keeps the retry
      // timer from being scheduled in the first place.
      addTearDown(TrustedTime.pauseAutomaticRefresh);

      final activeServers = TrustedTime.config.ntsServers.toSet();

      await tester.pumpWidget(MyApp(telemetry: TelemetryRecorder()));
      // Two pumps lay out the SingleChildScrollView and its eagerly
      // built children; pumpAndSettle would block on the engine's
      // 1 s UI ticker / integrity stream which never naturally idles.
      await tester.pump();
      await tester.pump();

      final chips = tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .toList();
      expect(chips, isNotEmpty);

      final renderedSelection = <String, bool>{
        for (final chip in chips) (chip.label as Text).data!: chip.selected,
      };

      for (final host in activeServers) {
        expect(
          renderedSelection[host],
          isTrue,
          reason:
              'Active host $host (from real engine config) must be a '
              'selected chip',
        );
      }
      for (final entry in renderedSelection.entries) {
        expect(
          entry.value,
          activeServers.contains(entry.key),
          reason:
              'Chip ${entry.key} selected=${entry.value} does not match '
              'real engine TrustedTime.config.ntsServers',
        );
      }
    },
  );
}
