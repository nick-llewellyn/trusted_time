import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_example/burst/burst_probe_panel.dart';

import 'burst_test_helpers.dart';

/// Wraps [BurstProbePanel] in a [MaterialApp] so Material-only widgets
/// (Slider, DropdownButtonFormField, etc.) have the inherited theme /
/// directionality they require for layout.
///
/// [clientFactory] defaults to the production implementation so the
/// form-state tests stay untouched; the burst-flow tests inject a
/// deterministic fake to drive a burst end to end without the NTS
/// network.
Widget _harness({
  required Iterable<String> hosts,
  NtsBurstClientFactory? clientFactory,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: BurstProbePanel(
          candidateHosts: hosts,
          clientFactory: clientFactory ?? defaultNtsBurstClientFactory,
        ),
      ),
    ),
  );
}

/// Taps the Run Burst button and pumps discrete frames until the
/// in-flight indicator clears, then asserts the burst actually
/// finished. Deliberately avoids `pumpAndSettle`: the running button
/// hosts a [CircularProgressIndicator] whose indefinite animation would
/// make `pumpAndSettle` time out. A no-delay parallel burst resolves
/// in a handful of frames; the generous upper bound only guards
/// against slower CI or an extra await
/// creeping into the burst path, and the trailing expectation turns
/// "still running" into a deterministic failure rather than a silent
/// early return mid-flight.
Future<void> _runBurstAndSettle(WidgetTester tester) async {
  await tester.tap(find.text('Run Burst'));
  await tester.pump(); // commit running = true
  for (var i = 0; i < 200 && find.text('Running…').evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(
    find.text('Running…'),
    findsNothing,
    reason: 'burst did not finish within the pump budget',
  );
}

void main() {
  group('BurstProbePanel', () {
    testWidgets('renders empty-state when no hosts are supplied', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(hosts: const []));

      expect(
        find.text(
          'No NTS hosts available — pick at least one in Section 7.',
        ),
        findsOneWidget,
      );
      // Run button must be disabled when no host is selectable.
      final runButton = tester.widget<ElevatedButton>(
        find.byType(ElevatedButton),
      );
      expect(runButton.onPressed, isNull);
    });

    testWidgets(
      'renders host dropdown with all candidates and default form state',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            hosts: const ['time.cloudflare.com', 'mmo1.nts.netnod.se'],
          ),
        );

        expect(find.text('Target host'), findsOneWidget);
        expect(find.text('time.cloudflare.com'), findsOneWidget);
        expect(
          find.text('Sample count: 4  (clamped to [1, 8])'),
          findsOneWidget,
        );
        expect(
          find.text('parallel — fire all queries at t = 0'),
          findsOneWidget,
        );
        expect(find.text('No burst run yet'), findsOneWidget);
      },
    );

    testWidgets(
      'switching to jittered mode reveals the jitter-window slider',
      (tester) async {
        await tester.pumpWidget(
          _harness(hosts: const ['time.cloudflare.com']),
        );

        // The mode dropdown is the second DropdownButtonFormField in
        // the tree (host dropdown is first); tap it to open the menu.
        await tester.tap(
          find.text('parallel — fire all queries at t = 0'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('jittered — random delays within a window').last,
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Jitter window: 200 ms'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'switching to sequential mode reveals the spacing slider',
      (tester) async {
        await tester.pumpWidget(
          _harness(hosts: const ['time.cloudflare.com']),
        );

        await tester.tap(
          find.text('parallel — fire all queries at t = 0'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('sequential — wait between completions').last,
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Sequential spacing'),
          findsOneWidget,
        );
        expect(find.textContaining('500 ms'), findsOneWidget);
      },
    );

    testWidgets(
      'didUpdateWidget drops the auto-default host when it disappears',
      (tester) async {
        // Default branch: no manual dropdown interaction, so
        // _selectedHost is null and effective host is hosts.first.
        // Removing the auto-default host on a rebuild must not crash
        // and must surface the new hosts.first.
        await tester.pumpWidget(
          _harness(hosts: const ['time.cloudflare.com', 'b.example.com']),
        );
        expect(find.text('time.cloudflare.com'), findsOneWidget);

        await tester.pumpWidget(_harness(hosts: const ['b.example.com']));
        await tester.pump();

        expect(find.text('b.example.com'), findsOneWidget);
        expect(find.text('time.cloudflare.com'), findsNothing);
      },
    );

    testWidgets(
      'didUpdateWidget drops an explicitly user-selected host that disappears',
      (tester) async {
        // Stronger variant: actually drive the dropdown to select
        // the second host so _selectedHost is non-null. The previous
        // test only covers the auto-default branch (_selectedHost
        // null, effective host = hosts.first); without this variant,
        // a regression that left _selectedHost pointing at a
        // no-longer-offered value would slip through and surface as
        // a runtime assert from DropdownButtonFormField rejecting an
        // initialValue not present in items.
        await tester.pumpWidget(
          _harness(hosts: const ['a.example.com', 'b.example.com']),
        );

        // Open the host dropdown and pick the second host.
        await tester.tap(find.text('a.example.com'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('b.example.com').last);
        await tester.pumpAndSettle();

        // Sanity: the dropdown shows the user's pick, not the
        // auto-default.
        expect(find.text('b.example.com'), findsOneWidget);

        // Now rebuild with a candidate set that no longer offers
        // 'b.example.com'. The panel must not throw and must fall
        // back to the new hosts.first ('a.example.com').
        await tester.pumpWidget(_harness(hosts: const ['a.example.com']));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('a.example.com'), findsOneWidget);
        expect(find.text('b.example.com'), findsNothing);
      },
    );

    testWidgets(
      'duplicate hosts in candidateHosts are de-duped before reaching the dropdown',
      (tester) async {
        // DropdownButtonFormField asserts uniqueness on item values
        // at runtime. A non-deduped Iterable with repeats (e.g. a
        // Set lifted from concat'd configs) would crash the panel
        // with a non-obvious "There should be exactly one item with
        // [DropdownButton]'s value" assertion. Pin the dedupe.
        await tester.pumpWidget(
          _harness(
            hosts: const [
              'time.cloudflare.com',
              'time.cloudflare.com',
              'mmo1.nts.netnod.se',
            ],
          ),
        );

        // The pump itself would have thrown if the dedupe failed.
        expect(tester.takeException(), isNull);

        // Closed dropdown shows the auto-default once (twice would
        // mean the dedupe didn't apply to the items list — which
        // would have already crashed the pump above, but assert
        // explicitly so a future regression that swallows the
        // assert silently doesn't sneak past).
        expect(find.text('time.cloudflare.com'), findsOneWidget);

        // Open the dropdown to verify the menu has both unique
        // entries and only one copy of the duplicate.
        await tester.tap(find.text('time.cloudflare.com'));
        await tester.pumpAndSettle();

        // 'time.cloudflare.com' is rendered both as the field's
        // displayed value and as a menu entry, so it appears twice
        // in the open-menu state. 'mmo1.nts.netnod.se' only appears
        // in the menu, so once. A failed dedupe would render the
        // duplicate as a third 'time.cloudflare.com' menu item.
        expect(find.text('time.cloudflare.com'), findsNWidgets(2));
        expect(find.text('mmo1.nts.netnod.se'), findsOneWidget);
      },
    );

    testWidgets(
      'sample-count slider can reach the maximum (8) without floating-point clip',
      (tester) async {
        // Regression: the previous v.toInt() call would floor a
        // snap-to-8 value of 7.999... back to 7, making sampleCount=8
        // unselectable on platforms whose Slider interpolation
        // surfaces sub-integer values at the max division. round()
        // closes that gap. Pin it.
        await tester.pumpWidget(
          _harness(hosts: const ['time.cloudflare.com']),
        );

        // Default is 4; verify the label shows that before the drag.
        expect(
          find.text('Sample count: 4  (clamped to [1, 8])'),
          findsOneWidget,
        );

        // Drag the sample-count Slider to its visual right edge.
        // The first Slider in the tree is the sample-count slider
        // (the duration slider only appears in jittered/sequential
        // modes, and we're in the default parallel mode here).
        final sliderCenter = tester.getCenter(find.byType(Slider).first);
        await tester.dragFrom(
          sliderCenter,
          const Offset(2000, 0), // overshoot intentional; clipped at max
        );
        await tester.pump();

        expect(
          find.text('Sample count: 8  (clamped to [1, 8])'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'runs a burst through the injected client and surfaces aggregated '
      'stats',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            hosts: const ['time.cloudflare.com'],
            clientFactory: testClientFactory(
              nowFn: () => 1000000000,
              rtts: const [10000, 20000, 30000, 40000],
              serverOffsetMicros: 5000,
            ),
          ),
        );

        await _runBurstAndSettle(tester);

        // Result card reports the dropdown's host (factory honours the
        // selected (host, port)) and the four successful queries.
        expect(
          find.textContaining('Last burst: time.cloudflare.com'),
          findsOneWidget,
        );
        expect(find.text('Issued'), findsOneWidget);
        expect(find.text('4 (4 ok, 0 failed)'), findsOneWidget);
        // hasResult branch rendered the aggregated stats.
        expect(find.text('Min RTT'), findsOneWidget);
      },
    );

    testWidgets(
      'the injected client factory is consulted once per host across '
      'repeated bursts',
      (tester) async {
        // Pins the panel's per-(host, port) client caching: a second
        // burst against the same host must reuse the cached client
        // rather than re-invoking the factory (which, in production,
        // would re-pay the NTS-KE handshake).
        final created = <String>[];
        await tester.pumpWidget(
          _harness(
            hosts: const ['time.cloudflare.com'],
            clientFactory: testClientFactory(
              nowFn: () => 1000000000,
              rtts: const [10000, 20000, 30000, 40000],
              serverOffsetMicros: 5000,
              onCreate: (host, port) => created.add('$host:$port'),
            ),
          ),
        );

        await _runBurstAndSettle(tester);
        await _runBurstAndSettle(tester);

        expect(created, ['time.cloudflare.com:4460']);
      },
    );

    testWidgets(
      'rebuilding with a new clientFactory invalidates the cached client '
      'so the next burst uses the updated factory',
      (tester) async {
        // Complements the caching test above: when the parent rebuilds
        // the panel with a *different* factory (hot reload, or a test
        // swapping fakes), didUpdateWidget must drop the cached client
        // so the next burst is built by the new factory rather than the
        // stale one. Without that invalidation `second` stays empty.
        final first = <String>[];
        final second = <String>[];

        Widget build(NtsBurstClientFactory factory) => _harness(
              hosts: const ['time.cloudflare.com'],
              clientFactory: factory,
            );

        await tester.pumpWidget(
          build(
            testClientFactory(
              nowFn: () => 1000000000,
              rtts: const [10000, 20000, 30000, 40000],
              serverOffsetMicros: 5000,
              onCreate: (host, port) => first.add('$host:$port'),
            ),
          ),
        );
        await _runBurstAndSettle(tester);
        expect(first, ['time.cloudflare.com:4460']);

        await tester.pumpWidget(
          build(
            testClientFactory(
              nowFn: () => 1000000000,
              rtts: const [10000, 20000, 30000, 40000],
              serverOffsetMicros: 5000,
              onCreate: (host, port) => second.add('$host:$port'),
            ),
          ),
        );
        await _runBurstAndSettle(tester);

        expect(second, ['time.cloudflare.com:4460']);
      },
    );
  });
}
