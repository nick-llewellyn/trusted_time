import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_example/burst/burst_probe_panel.dart';

/// Wraps [BurstProbePanel] in a [MaterialApp] so Material-only widgets
/// (Slider, DropdownButtonFormField, etc.) have the inherited theme /
/// directionality they require for layout.
Widget _harness({required Iterable<String> hosts}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: BurstProbePanel(candidateHosts: hosts),
      ),
    ),
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
      'didUpdateWidget drops a selected host that disappears from candidates',
      (tester) async {
        // Render with two hosts, no manual selection => effective host
        // is hosts.first.
        await tester.pumpWidget(
          _harness(hosts: const ['time.cloudflare.com', 'b.example.com']),
        );
        expect(find.text('time.cloudflare.com'), findsOneWidget);

        // Rebuild with a candidate set that no longer contains the
        // first host. The panel should not crash and the dropdown
        // should now display the new first host.
        await tester.pumpWidget(_harness(hosts: const ['b.example.com']));
        await tester.pump();

        expect(find.text('b.example.com'), findsOneWidget);
        expect(find.text('time.cloudflare.com'), findsNothing);
      },
    );
  });
}
