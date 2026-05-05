import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models.dart';
import '../monotonic_clock.dart';

export 'nts_source_stub.dart' if (dart.library.io) 'nts_source_io.dart';

/// Fetches UTC time from an HTTPS endpoint's `Date` response header.
///
/// Tries HEAD first (lightweight), falls back to GET if HEAD returns 405
/// or omits the `Date` header. The server's `Date` header is corrected for
/// one-way network latency using the measured round-trip time.
///
/// The URL **must** use the `https` scheme. The package's threat model
/// relies on the `Date` header being bound to a TLS handshake; a
/// `http://` URL silently degrades that guarantee and is rejected at
/// construction time with an [ArgumentError].
///
/// Pass a pre-configured [http.Client] for enterprise certificate pinning:
/// ```dart
/// final client = IOClient(HttpClient(context: mySecurityContext));
/// final source = HttpsSource('https://internal.example.com', client: client);
/// ```
///
/// [requestTimeout] is the per-request defensive ceiling applied to
/// each HEAD/GET. It defaults to 30 s, sized to sit comfortably above
/// the default `TrustedTimeConfig.maxLatency` of 3 s so a slow probe
/// is attributed to the outer budget (`timedOut`) rather than racing
/// the inner deadline (`failed`).
///
/// For deterministic attribution `requestTimeout` must be **strictly
/// greater than** the engine's `maxLatency`. Both timers wrap the same
/// underlying work, so `requestTimeout == maxLatency` lets either
/// callback fire first and the diagnostic bucket becomes
/// scheduler-dependent. Callers configuring a `maxLatency` of e.g.
/// 60 s must pass `requestTimeout: const Duration(seconds: 90)` (or
/// larger) to keep the outer wrapper deterministically ahead. The
/// inner bound is hard-coded into the `.timeout(...)` call here, so
/// it cannot be relaxed by swapping in a different `http.Client`
/// alone.
///
/// Callers concerned about lingering background work after the outer
/// wrapper times out (`Future.timeout` does not cancel the in-flight
/// HTTP request) can pass a smaller `requestTimeout`, accepting that
/// values close to or below `maxLatency` will rejoin the race and
/// degrade the `timedOut`-vs-`failed` diagnostic split.
///
/// When this source is constructed by `SyncEngine` from
/// `TrustedTimeConfig.httpsSources`, the engine forwards
/// `TrustedTimeConfig.httpsRequestTimeout` here automatically; this
/// constructor parameter exists for callers wiring `HttpsSource`
/// directly through `TrustedTimeConfig.additionalSources` or in tests.
final class HttpsSource implements TrustedTimeSource {
  HttpsSource(
    this._url, {
    http.Client? client,
    MonotonicClock? clock,
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _clock = clock ?? PlatformMonotonicClock(),
       _requestTimeout = requestTimeout {
    final Uri parsed;
    try {
      parsed = Uri.parse(_url);
    } on FormatException catch (e) {
      throw ArgumentError.value(_url, 'url', 'Not a valid URI: ${e.message}');
    }
    if (parsed.scheme != 'https') {
      throw ArgumentError.value(
        _url,
        'url',
        'HttpsSource requires the https scheme; got "${parsed.scheme}". '
            'Clear-text HTTP would silently drop the TLS binding the '
            'package depends on (see ADR 0003).',
      );
    }
    if (parsed.host.isEmpty) {
      throw ArgumentError.value(_url, 'url', 'URI is missing a host.');
    }
  }

  final String _url;
  final http.Client _client;
  final MonotonicClock _clock;
  final Duration _requestTimeout;

  /// Test seam: the per-request defensive ceiling currently in effect.
  /// Lets `SyncEngine`-construction regressions verify that
  /// [TrustedTimeConfig.httpsRequestTimeout] reaches the built-in
  /// probes constructed from `httpsSources`.
  @visibleForTesting
  Duration get requestTimeoutForTesting => _requestTimeout;

  @override
  String get id => 'https:$_url';

  @override
  Future<TimeSample> fetch() async {
    final uri = Uri.parse(_url);
    final sw = Stopwatch()..start();

    // Try HEAD first (lightweight), fall back to GET if the server rejects
    // HEAD or omits the Date header.
    //
    // `_requestTimeout` is a per-request defensive ceiling for genuinely
    // hung connections (e.g. a TCP socket that never receives RST) — it
    // is *not* the policy knob for "how long is too long". `SyncEngine`
    // wraps every `fetch()` in `timeout(maxLatency)` and routes the
    // resulting `_OuterTimeoutException` to the `timedOut` diagnostic
    // bucket; an inner `TimeoutException` is bucketed as `failed`
    // instead.
    //
    // For deterministic attribution `_requestTimeout` must be strictly
    // greater than `maxLatency`; both timers wrap the same underlying
    // work, so equal values let either callback fire first depending on
    // scheduler ordering. The 30 s default sits comfortably above the
    // default `maxLatency` of 3 s. Callers configuring `maxLatency`
    // above 30 s must raise `requestTimeout` further still (e.g.
    // `requestTimeout: maxLatency + Duration(seconds: 30)`); the inner
    // bound is hard-coded into the `.timeout(...)` calls here, so it
    // cannot be relaxed by swapping in a different `http.Client`
    // alone.
    //
    // Conversely, callers concerned about lingering background work —
    // `Future.timeout` does not cancel the in-flight request, so an
    // abandoned probe keeps running until the response arrives, the
    // underlying client tears down the socket, or `_requestTimeout`
    // fires, whichever comes first — can pass a smaller
    // `requestTimeout`, accepting that values close to or below
    // `maxLatency` will rejoin the race and degrade the diagnostic
    // split.
    var response = await _client.head(uri).timeout(_requestTimeout);
    if (response.statusCode == 405 || response.headers['date'] == null) {
      sw.reset();
      sw.start();
      response = await _client.get(uri).timeout(_requestTimeout);
    }
    sw.stop();
    // Capture monotonic reference immediately on response receipt, before
    // any further aggregation work in the sync engine.
    final capturedMonotonicMs = await _clock.uptimeMs();
    final capturedAt = DateTime.now().toUtc();

    final dateHeader = response.headers['date'];
    if (dateHeader == null) {
      throw Exception('Server did not provide a Date header.');
    }

    final serverTime = _HttpDate.parse(dateHeader);
    final networkUtc = serverTime
        .add(Duration(milliseconds: sw.elapsedMilliseconds ~/ 2))
        .toUtc();
    return TimeSample(
      networkUtc: networkUtc,
      roundTripTime: sw.elapsed,
      uncertainty: Duration(milliseconds: sw.elapsedMilliseconds ~/ 2),
      capturedMonotonicMs: capturedMonotonicMs,
      source: TimeSourceMetadata(
        kind: TimeSourceKind.https,
        id: id,
        host: uri.host,
      ),
      capturedAt: capturedAt,
    );
  }

  void dispose() => _client.close();
}

/// Internal parser for RFC 7231 / RFC 1123 HTTP date headers.
///
/// Handles the standard format: `Thu, 01 Jan 2024 12:00:00 GMT`.
/// Also handles RFC 850 format: `Thursday, 01-Jan-24 12:00:00 GMT`.
/// Throws [FormatException] on unrecognized formats — the SyncEngine's
/// try/catch in [_querySafe] handles this gracefully.
final class _HttpDate {
  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  static const _weekdays = {
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  };

  static DateTime parse(String header) {
    final parts = header
        .replaceAll('-', ' ')
        .split(RegExp(r'[\s,]+'))
        .where((p) => p.isNotEmpty && !_weekdays.contains(p))
        .toList();

    if (parts.length < 4) {
      throw FormatException('Unrecognized HTTP-date format: $header');
    }

    final timeParts = parts[3].split(':');
    if (timeParts.length < 3) {
      throw FormatException('Unrecognized time format in HTTP-date: $header');
    }

    var year = int.parse(parts[2]);
    if (year < 100) year += 2000;

    return DateTime.utc(
      year,
      _months[parts[1]] ?? 1,
      int.parse(parts[0]),
      int.parse(timeParts[0]),
      int.parse(timeParts[1]),
      int.parse(timeParts[2]),
    );
  }
}
