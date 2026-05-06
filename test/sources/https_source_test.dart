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

/// Returns 405 on HEAD (which triggers the GET fallback inside
/// `HttpsSource.fetch()`) and hangs forever on GET. Pins the contract
/// that the GET branch is wrapped in `_requestTimeout` too — a
/// regression that drops or weakens the `.timeout(...)` on the GET
/// fallback would slip past the HEAD-only `_HangingClient` regression.
class _HeadRejectsGetHangsClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _never =
      Completer<http.StreamedResponse>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'HEAD') {
      return Future.value(
        http.StreamedResponse(
          Stream<List<int>>.fromIterable(const <List<int>>[]),
          405,
          request: request,
        ),
      );
    }
    return _never.future;
  }

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

  group('HttpsSource constructor requestTimeout positivity guard', () {
    // Mirrors the `SyncEngine._validateConfig` check at the
    // direct-construction layer. The dartdoc on `HttpsSource` points
    // callers at this constructor for `additionalSources` wiring, so
    // the source itself has to reject a non-positive `requestTimeout`
    // — otherwise a direct user can ship a source that fires its
    // inner ceiling on first scheduler tick and surfaces every probe
    // as `failed` before the request reaches the network. Throws in
    // both debug and release builds to close the gap a debug-only
    // assert would leave.
    test('rejects Duration.zero', () {
      expect(
        () => HttpsSource(
          'https://www.example.com',
          requestTimeout: Duration.zero,
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'requestTimeout'),
        ),
      );
    });

    test('rejects a negative duration', () {
      expect(
        () => HttpsSource(
          'https://www.example.com',
          requestTimeout: const Duration(seconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts a positive duration', () {
      final source = HttpsSource(
        'https://www.example.com',
        requestTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(source.dispose);
      expect(source.requestTimeoutForTesting, const Duration(milliseconds: 1));
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
    test('HEAD timeout fires when the underlying client hangs', () async {
      // `await expectLater(...)` is load-bearing: a synchronous
      // `expect(future, ...)` body returns immediately, so
      // `addTearDown(source.dispose)` could close `_HangingClient`
      // before the 50 ms timer fires and the underlying request would
      // complete with `StateError('client closed')` instead of the
      // intended `TimeoutException`. Awaiting the matcher pins the
      // ordering so the timer wins and the regression actually
      // exercises the timeout path.
      final client = _HangingClient();
      final source = HttpsSource(
        'https://www.example.com',
        client: client,
        requestTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(source.dispose);
      await expectLater(source.fetch(), throwsA(isA<TimeoutException>()));
    });

    test(
      'GET fallback timeout fires when HEAD is rejected and GET hangs',
      () async {
        // Pins the contract on the GET fallback branch. The HEAD-only
        // `_HangingClient` regression cannot catch a future refactor
        // that drops or weakens the `.timeout(...)` wrapper on the GET
        // call — a server returning 405 on HEAD would then leave the
        // GET branch unbounded. The 405 response triggers the fallback
        // inside `HttpsSource.fetch()`, after which the hanging GET
        // surfaces a `TimeoutException` from the inner wrapper.
        final client = _HeadRejectsGetHangsClient();
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
        // production default — and tighter than any wall-clock value
        // that would suggest the test is succeeding by coincidence
        // (e.g. the HEAD-405 path returning early).
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );

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
