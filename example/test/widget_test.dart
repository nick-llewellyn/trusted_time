import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trusted_time_example/main.dart';
import 'package:trusted_time_example/sync_telemetry.dart';
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

  testWidgets('Example app renders TrustedTime V2 Features title', (
    WidgetTester tester,
  ) async {
    final mock = TrustedTimeMock(initial: DateTime.utc(2024, 1, 1, 12));
    TrustedTime.overrideForTesting(mock);

    await tester.pumpWidget(MyApp(telemetry: TelemetryRecorder()));
    await tester.pumpAndSettle();

    expect(find.text('TrustedTime V2 Features'), findsOneWidget);
    expect(find.text('Section 1 — Live Clock'), findsOneWidget);

    TrustedTime.resetOverride();
    mock.dispose();
  });

  testWidgets(
    'Section 7 FilterChips reflect TrustedTime.config.ntsServers',
    (WidgetTester tester) async {
      // Widget-layer contract test. Pins that _BenchmarkingPanel's
      // FilterChip selection state is derived from
      // `TrustedTime.config.ntsServers` and nothing else. Uses the
      // override path so the assertion targets the widget code
      // exclusively without depending on engine behaviour. The
      // companion test below exercises the same code path against
      // the real TrustedTimeImpl.
      final mock = TrustedTimeMock(initial: DateTime.utc(2024, 1, 1, 12));
      addTearDown(() {
        TrustedTime.resetOverride();
        mock.dispose();
      });
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
        reason: 'Default TrustedTimeConfig.ntsServers must seed at '
            'least one host for this test to be meaningful',
      );

      await tester.pumpWidget(MyApp(telemetry: TelemetryRecorder()));
      await tester.pumpAndSettle();

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
          reason: 'Chip ${entry.key} selected=${entry.value} '
              'does not match TrustedTime.config.ntsServers',
        );
      }
    },
  );

  testWidgets(
    'real engine: chips reflect TrustedTime.config after initialize',
    (WidgetTester tester) async {
      // End-to-end integration test: drive the actual TrustedTimeImpl
      // (no override) through TrustedTime.initialize, then verify the
      // chip selection rendered by _BenchmarkingPanel mirrors whatever
      // TrustedTime.config.ntsServers reports back.
      //
      // The engine's network I/O is run via tester.runAsync so its
      // real timers and stream subscriptions execute on the host
      // event loop instead of fighting flutter_test's FakeAsync zone.
      // RustLib.init may fail in the test environment, in which case
      // TrustedTime.initialize rewrites ntsServers to []. The
      // assertion is robust to either outcome — it pins
      // "chips == TrustedTime.config.ntsServers" rather than
      // "chips == requested ntsServers" — so the test passes whether
      // or not the bundled Rust dylib is available.
      TrustedTime.resetOverride();
      addTearDown(TrustedTime.resetOverride);

      const requested = [
        'time.cloudflare.com',
        'mmo1.nts.netnod.se',
        'ohio.time.system76.com',
      ];

      await tester.runAsync(() async {
        await TrustedTime.initialize(
          config: const TrustedTimeConfig(
            ntpServers: [],
            httpsSources: [],
            ntsServers: requested,
            minimumQuorum: 2,
            minQuorumRatio: 0.4,
            // Long enough that the bootstrap retry timer cannot fire
            // during the test body, eliminating one source of pending
            // async work for pumpWidget to deal with.
            refreshInterval: Duration(hours: 1),
            persistState: false,
          ),
        );
      });

      final activeServers = TrustedTime.config.ntsServers.toSet();

      await tester.pumpWidget(MyApp(telemetry: TelemetryRecorder()));
      // Two pumps lay out the SingleChildScrollView and its eagerly
      // built children; pumpAndSettle would block on the engine's
      // 1 s UI ticker / integrity stream which never naturally idles.
      await tester.pump();
      await tester.pump();

      final chips =
          tester.widgetList<FilterChip>(find.byType(FilterChip)).toList();
      expect(chips, isNotEmpty);

      final renderedSelection = <String, bool>{
        for (final chip in chips) (chip.label as Text).data!: chip.selected,
      };

      for (final host in activeServers) {
        expect(
          renderedSelection[host],
          isTrue,
          reason: 'Active host $host (from real engine config) must be a '
              'selected chip',
        );
      }
      for (final entry in renderedSelection.entries) {
        expect(
          entry.value,
          activeServers.contains(entry.key),
          reason: 'Chip ${entry.key} selected=${entry.value} does not match '
              'real engine TrustedTime.config.ntsServers',
        );
      }
    },
  );
}
