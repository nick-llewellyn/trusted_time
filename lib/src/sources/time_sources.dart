import 'package:http/http.dart' as http;
import '../models.dart';
import '../monotonic_clock.dart';

export 'ntp_source_stub.dart' if (dart.library.io) 'ntp_source_io.dart';
export 'nts_source_stub.dart' if (dart.library.io) 'nts_source_io.dart';

/// Fetches UTC time from an HTTPS endpoint's `Date` response header.
///
/// Tries HEAD first (lightweight), falls back to GET if HEAD returns 405
/// or omits the `Date` header. The server's `Date` header is corrected for
/// one-way network latency using the measured round-trip time.
///
/// Pass a pre-configured [http.Client] for enterprise certificate pinning:
/// ```dart
/// final client = IOClient(HttpClient(context: mySecurityContext));
/// final source = HttpsSource('https://internal.example.com', client: client);
/// ```
final class HttpsSource implements TrustedTimeSource {
  HttpsSource(this._url, {http.Client? client, MonotonicClock? clock})
    : _client = client ?? http.Client(),
      _clock = clock ?? PlatformMonotonicClock();

  final String _url;
  final http.Client _client;
  final MonotonicClock _clock;

  @override
  String get id => 'https:$_url';

  @override
  Future<TimeSample> fetch() async {
    final uri = Uri.parse(_url);
    final sw = Stopwatch()..start();

    // Try HEAD first (lightweight), fall back to GET if the server rejects
    // HEAD or omits the Date header.
    var response = await _client.head(uri).timeout(const Duration(seconds: 3));
    if (response.statusCode == 405 || response.headers['date'] == null) {
      sw.reset();
      sw.start();
      response = await _client.get(uri).timeout(const Duration(seconds: 3));
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
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  static const _weekdays = {
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
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
