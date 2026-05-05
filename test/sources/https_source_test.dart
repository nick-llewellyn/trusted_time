@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:trusted_time_nts/src/sources/time_sources.dart';

/// Hangs every `send()` until `close()` is called. Used to pin the
/// inner per-request timeout regression: a probe whose underlying HTTP
/// future never completes must surface a `TimeoutException` from the
/// `requestTimeout` wrapper inside `fetch()` itself, *not* be left
/// hanging indefinitely or attributed to the engine's outer
/// `maxLatency` budget (which is not even involved at the source
/// level).
class _HangingClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _never =
      Completer<http.StreamedResponse>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _never.future;
  @override
  void close() {
    if (!_never.isCompleted) {
      _never.completeError(StateError('client closed'));
    }
  }
}

void main() {
  group('HttpsSource constructor scheme enforcement', () {
    test('accepts an https URL', () {
      final source = HttpsSource('https://www.example.com');
      addTearDown(source.dispose);
      expect(source.id, 'https:https://www.example.com');
    });

    test('rejects an http URL', () {
      expect(
        () => HttpsSource('http://www.example.com'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('https scheme'), contains('http')),
          ),
        ),
      );
    });

    test('rejects a non-web scheme', () {
      expect(
        () => HttpsSource('ftp://files.example.com'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a bare host without a scheme', () {
      expect(
        () => HttpsSource('www.example.com'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty string', () {
      expect(() => HttpsSource(''), throwsA(isA<ArgumentError>()));
    });

    test('rejects an https URL missing a host', () {
      expect(() => HttpsSource('https://'), throwsA(isA<ArgumentError>()));
    });
  });

  group('HttpsSource requestTimeout enforcement', () {
    // Pin the inner per-request timeout contract at the source level,
    // not just at the engine level. The companion regression in
    // `test/sync_engine_test.dart` ("inner TimeoutException is
    // bucketed as failed, not as a maxLatency timeout") covers the
    // engine's bucketing using a fake `TrustedTimeSource`, but a
    // future refactor that drops or weakens the `.timeout(...)`
    // wrapper inside `HttpsSource.fetch()` would silently slip past
    // that test because the fake never exercises the real call site.
    // These tests close that gap by driving the real `fetch()` over a
    // hanging `http.Client`, with a tight `requestTimeout` so the
    // assertion completes deterministically without the 30 s
    // production wall-clock wait.
    test('HEAD timeout fires when the underlying client hangs', () {
      final client = _HangingClient();
      final source = HttpsSource(
        'https://www.example.com',
        client: client,
        requestTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(source.dispose);
      expect(source.fetch(), throwsA(isA<TimeoutException>()));
    });

    test(
      'requestTimeout is honored independently of any outer wrapper',
      () async {
        // A caller invoking `fetch()` directly (i.e. without the
        // engine's outer `maxLatency` wrapper) must still see the
        // inner timeout fire — otherwise an integrator who builds a
        // custom orchestration on top of `HttpsSource` would get an
        // unbounded hang on a wedged connection. Verifies the
        // wall-clock window is bounded by `requestTimeout`, not by
        // the underlying client's behaviour.
        final client = _HangingClient();
        final source = HttpsSource(
          'https://www.example.com',
          client: client,
          requestTimeout: const Duration(milliseconds: 50),
        );
        addTearDown(source.dispose);
        final sw = Stopwatch()..start();
        await expectLater(source.fetch(), throwsA(isA<TimeoutException>()));
        sw.stop();
        // Generous upper bound to absorb CI scheduling jitter while
        // still demonstrating the bound is much tighter than the 30 s
        // production default.
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );
  });
}
