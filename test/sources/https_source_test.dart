import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
