import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:trusted_time/src/infra/dns_budget.dart';
import 'package:trusted_time/src/sources/time_sources.dart';

/// Regressions for trusted_time-sps.
///
/// HttpsSource now validates `requestTimeout`, URL parse, scheme, and
/// host *before* allocating a default `http.Client`. A user-supplied
/// client is left untouched on validation failure (the factory returns
/// before any field assignment, so the caller still owns it).
///
/// `requestTimeout` is configurable and forwarded verbatim to the
/// underlying `head()` / `get()` calls.
void main() {
  group('HttpsSource validation', () {
    test('throws ArgumentError on non-positive requestTimeout', () {
      expect(
        () => HttpsSource('https://example.com', requestTimeout: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => HttpsSource(
          'https://example.com',
          requestTimeout: const Duration(milliseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError on non-https scheme', () {
      expect(
        () => HttpsSource('http://example.com'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => HttpsSource('ftp://example.com'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError on missing host', () {
      // `Uri.parse` accepts a scheme-only URI without throwing; the
      // constructor still rejects it because there is no host to
      // resolve.
      expect(
        () => HttpsSource('https:///path-only'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('user-supplied client is not closed on validation failure', () {
      final client = _CloseTrackingClient();
      expect(
        () => HttpsSource('http://not-https.example.com', client: client),
        throwsA(isA<ArgumentError>()),
      );
      // Caller still owns the client; it must not have been closed
      // during the constructor's validation throw path.
      expect(client.closeCalled, isFalse);
    });

    test('accepts a well-formed https URL with default timeout', () {
      // Constructor must not throw and must not require a custom
      // timeout — the default (3 s) is preserved for direct callers.
      // Register a tear-down to dispose the default `http.Client`
      // allocated by the factory so the test does not leak sockets
      // across the suite run.
      final source = HttpsSource('https://example.com');
      addTearDown(source.dispose);
      expect(source, isA<HttpsSource>());
    });
  });

  group('HttpsSource configurable requestTimeout', () {
    test('default 3-second timeout is preserved when omitted', () async {
      // Mock client never responds; the request must time out at
      // approximately the default 3-second budget. Use a 2-second
      // probe to confirm the timeout is at least that long.
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 10));
        return http.Response('', 200);
      });
      final source = HttpsSource('https://example.com', client: client);

      final sw = Stopwatch()..start();
      await expectLater(source.getTime(), throwsA(isA<Object>()));
      sw.stop();
      // Default timeout is 3 s; allow generous margin for CI scheduling.
      expect(sw.elapsed.inMilliseconds, greaterThanOrEqualTo(2500));
    });

    test('custom requestTimeout shortens the per-request budget', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 10));
        return http.Response('', 200);
      });
      final source = HttpsSource(
        'https://example.com',
        client: client,
        requestTimeout: const Duration(milliseconds: 200),
      );

      final sw = Stopwatch()..start();
      await expectLater(source.getTime(), throwsA(isA<Object>()));
      sw.stop();
      // Timeout fires well before the default 3 s. Generous upper
      // bound to avoid flakes on slow CI; the assertion is that the
      // custom timeout was respected, not that it fired exactly at
      // 200 ms.
      expect(sw.elapsed.inMilliseconds, lessThan(2000));
    });
  });

  group('HttpsSource DNS budget integration (ADR 0008)', () {
    // A client that always answers with a parseable Date header so
    // getTime() reaches a TimeSample once the pre-resolve step has run.
    http.Client dateClient() => MockClient(
      (request) async => http.Response(
        '',
        200,
        headers: const {'date': 'Wed, 21 Oct 2026 07:28:00 GMT'},
      ),
    );

    test('pre-resolves through the budget cache-first, reusing the '
        'result', () async {
      final budget = DnsBudget(4);
      var lookups = 0;
      final source = HttpsSource(
        'https://example.com',
        client: dateClient(),
        dnsBudget: budget,
        hostResolver: (host) async {
          lookups++;
          return const ['1.2.3.4'];
        },
      );
      addTearDown(source.dispose);

      await source.getTime();
      expect(lookups, 1);

      // A second query for the same host hits the budget cache, so the
      // warming resolver is not consulted again.
      await source.getTime();
      expect(lookups, 1);
    });

    test('without a budget the warming resolver is never consulted', () async {
      var lookups = 0;
      final source = HttpsSource(
        'https://example.com',
        client: dateClient(),
        hostResolver: (host) async {
          lookups++;
          return const ['1.2.3.4'];
        },
      );
      addTearDown(source.dispose);

      await source.getTime();
      expect(lookups, 0);
    });

    test(
      'a saturated budget drops the source (propagates saturation)',
      () async {
        final budget = DnsBudget(
          1,
          acquireTimeout: const Duration(milliseconds: 50),
        );
        // Occupy the only permit under an unrelated key so the source's own
        // warming lookup cannot be admitted.
        final held = Completer<List<String>>();
        unawaited(budget.guard('other-host', () => held.future));
        await Future<void>.delayed(Duration.zero);

        final source = HttpsSource(
          'https://example.com',
          client: dateClient(),
          dnsBudget: budget,
          hostResolver: (host) async => const ['1.2.3.4'],
        );
        addTearDown(source.dispose);

        // Saturation must surface (not be swallowed like an ordinary miss)
        // so SyncEngine drops the source onto the cooldown ladder.
        await expectLater(
          source.getTime(),
          throwsA(isA<DnsBudgetSaturation>()),
        );
        held.complete(const []);
      },
    );

    test('a warming lookup failure still proceeds to the HTTPS '
        'request', () async {
      final budget = DnsBudget(4);
      final source = HttpsSource(
        'https://example.com',
        client: dateClient(),
        dnsBudget: budget,
        hostResolver: (host) async => throw Exception('no DNS'),
      );
      addTearDown(source.dispose);

      // Warming is best-effort: an ordinary resolution failure is
      // swallowed and the request still yields a sample.
      final sample = await source.getTime();
      expect(sample.sourceId, contains('example.com'));
    });

    test('clamps the warming timeout to the budget admission window', () async {
      // Regression (ADR 0008): with a 30ms window and a resolver that only
      // answers after 100ms, the warming lookup times out (swallowed as
      // best-effort) and getTime still returns from the HTTPS request — the
      // permit is not held past the engine's window. Mirrors NtpSource.
      final budget = DnsBudget(
        4,
        acquireTimeout: const Duration(milliseconds: 30),
      );
      final source = HttpsSource(
        'https://example.com',
        client: dateClient(),
        dnsBudget: budget,
        hostResolver: (host) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return const ['1.2.3.4'];
        },
      );
      addTearDown(source.dispose);

      final sample = await source.getTime();
      expect(sample.sourceId, contains('example.com'));
    });
  });
}

/// Minimal `http.Client` that records whether `close()` was called.
/// Lets the validation-failure tests assert that a user-supplied
/// client is left untouched when the constructor throws.
class _CloseTrackingClient extends http.BaseClient {
  bool closeCalled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw UnsupportedError('not used in validation tests');
  }

  @override
  void close() {
    closeCalled = true;
    super.close();
  }
}
