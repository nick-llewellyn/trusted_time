import 'package:http/http.dart' as http;
import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../infra/dns_budget.dart';
import 'host_lookup_stub.dart' if (dart.library.io) 'host_lookup_io.dart';

export 'ntp_source_stub.dart' if (dart.library.io) 'ntp_source_io.dart';
export 'nts_source_stub.dart' if (dart.library.io) 'nts_source.dart';

/// Resolves [host] to its address literals, warming the platform DNS
/// cache. Injectable so tests can supply a deterministic mapping — or a
/// controllable delay/failure — without real DNS. The resolved IP
/// strings are unused beyond letting the shared [DnsBudget] cache a
/// successful resolution for reuse across warm cycles.
typedef HttpsHostResolver = Future<List<String>> Function(String host);

/// Fetches UTC time from an HTTPS endpoint's `Date` response header.
final class HttpsSource implements TimeSource {
  /// Creates an [HttpsSource] for the given HTTPS [url].
  ///
  /// Validates [url], [requestTimeout], and (when not provided) defers
  /// allocating the default [http.Client] until after validation
  /// passes. Throws [ArgumentError] if:
  ///   * [requestTimeout] is non-positive,
  ///   * [url] cannot be parsed as a URI,
  ///   * the URI scheme is not `https`, or
  ///   * the URI has no host.
  ///
  /// On a validation failure a user-supplied [client] is left
  /// untouched (the factory returns before any field assignment, so
  /// the caller still owns and is responsible for the client). When
  /// [client] is null no default [http.Client] is allocated until
  /// every check has passed, so a misconfiguration cannot leak a
  /// freshly-allocated socket pool.
  ///
  /// [dnsBudget] is the shared SyncEngine-level DNS concurrency budget
  /// (ADR 0008). When supplied, [getTime] first pre-resolves the host
  /// through it cache-first to warm the platform DNS cache before
  /// `package:http` issues its own (now-warm) internal lookup; when
  /// `null` (direct callers, tests) — or on a platform with no
  /// in-process resolver to warm (web), where the default lookup is a
  /// no-op stub — no pre-resolve runs. [hostResolver] is an injection
  /// seam for that warming step; it defaults to the platform resolver,
  /// is unused when [dnsBudget] is `null`, and (because it is a real
  /// seam) forces warming to run even on a platform that would otherwise
  /// skip it.
  factory HttpsSource(
    String url, {
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 3),
    DnsBudget? dnsBudget,
    HttpsHostResolver? hostResolver,
  }) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be strictly positive',
      );
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      throw ArgumentError.value(url, 'url', 'is not a parseable URI: $e');
    }
    if (uri.scheme != 'https') {
      throw ArgumentError.value(
        url,
        'url',
        'must use the https scheme (got "${uri.scheme}")',
      );
    }
    if (!uri.hasAuthority || uri.host.isEmpty) {
      throw ArgumentError.value(url, 'url', 'must contain a non-empty host');
    }
    return HttpsSource._(
      url,
      client ?? http.Client(),
      requestTimeout,
      dnsBudget,
      hostResolver,
    );
  }

  HttpsSource._(
    this._url,
    this._client,
    this._requestTimeout,
    this._dnsBudget,
    this._hostOverride,
  );

  final String _url;
  final http.Client _client;
  final Duration _requestTimeout;
  final DnsBudget? _dnsBudget;
  final HttpsHostResolver? _hostOverride;

  HttpsHostResolver get _resolveHost => _hostOverride ?? defaultHttpsHostLookup;

  @override
  String get id => '${TimeSource.prefixHttps}$_url';

  @override
  String get groupId {
    try {
      return Uri.parse(_url).host;
    } catch (_) {
      return _url;
    }
  }

  @override
  Future<TimeSample> getTime() async {
    await _preResolve();
    final uri = Uri.parse(_url);
    final sw = Stopwatch()..start();

    var response = await _client.head(uri).timeout(_requestTimeout);
    if (response.statusCode == 405 || response.headers['date'] == null) {
      sw.reset();
      sw.start();
      response = await _client.get(uri).timeout(_requestTimeout);
    }
    sw.stop();

    final dateHeader = response.headers['date'];
    if (dateHeader == null) {
      throw Exception('Server did not provide a Date header.');
    }

    final serverTime = _HttpDate.parse(dateHeader);
    final correctedTime = serverTime
        .add(Duration(milliseconds: sw.elapsedMilliseconds ~/ 2))
        .toUtc();

    final startMs =
        correctedTime.millisecondsSinceEpoch - (sw.elapsedMilliseconds ~/ 2);
    final endMs =
        correctedTime.millisecondsSinceEpoch + (sw.elapsedMilliseconds ~/ 2);

    return TimeSample(
      interval: TimeInterval(startMs: startMs, endMs: endMs),
      sourceId: id,
      groupId: groupId,
      // Whole round-trip delay δ; the interval still uses δ/2.
      delayMs: sw.elapsedMilliseconds,
    );
  }

  /// Warms the platform DNS cache for this source's host under the
  /// shared [DnsBudget] before the HTTPS request resolves the same host
  /// internally (ADR 0008). No-op when no budget is configured, or on a
  /// platform with no in-process resolver to warm (web): there the
  /// default lookup is a no-op stub and `package:http` performs its own
  /// DNS as part of `fetch`, so acquiring a permit would be pure
  /// overhead. An injected [hostResolver] overrides this skip.
  ///
  /// The lookup is admitted cache-first: a warm host within the budget's
  /// cache TTL consumes no permit. The resolver timeout is clamped to the
  /// budget's admission window so a stalled lookup cannot hold a permit
  /// past the moment the engine has already dropped the source (mirrors
  /// NtpSource). [DnsBudgetSaturation] propagates so the engine drops the
  /// source onto the standard exponential-cooldown path exactly as a
  /// `maxLatency` miss would; an ordinary lookup failure or timeout is
  /// swallowed because warming is best-effort — the HTTPS request still
  /// runs and surfaces its own connection error if the host is truly
  /// unreachable.
  ///
  /// This accepts a double-resolve (our warming lookup plus
  /// `package:http`'s internal one) and relies on the platform DNS cache
  /// outliving the gap between them; see ADR 0008.
  Future<void> _preResolve() async {
    final budget = _dnsBudget;
    if (budget == null) return;
    // On a platform with no in-process resolver (web), the default
    // lookup is a no-op stub: there is no platform DNS cache for
    // `package:http` to reuse, so warming would only burn a permit (and
    // could throw DnsBudgetSaturation) for nothing. Skip it. A
    // test-injected resolver is a real seam to exercise, so honour it
    // regardless of platform.
    if (_hostOverride == null && !kSupportsHttpsHostWarming) return;
    final host = Uri.parse(_url).host;
    final lookupTimeout = _minDuration(
      const Duration(seconds: 2),
      budget.acquireTimeout,
    );
    try {
      await budget.guard(host, () => _resolveHost(host).timeout(lookupTimeout));
    } on DnsBudgetSaturation {
      rethrow;
    } catch (_) {
      // Best-effort warming: an ordinary resolution failure or timeout
      // must not pre-empt the HTTPS attempt, which has its own error path.
    }
  }

  static Duration _minDuration(Duration a, Duration b) => a <= b ? a : b;

  /// Documented.
  void dispose() => _client.close();
}

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
    try {
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

      final day = int.parse(parts[0]);
      final monthStr = parts[1];
      final month = _months[monthStr];
      if (month == null) throw FormatException('Invalid month: $monthStr');

      var year = int.parse(parts[2]);
      if (year < 100) {
        year += year < 70 ? 2000 : 1900; // RFC 2616 §19.3
      }

      final hour = int.parse(timeParts[0]);
      final min = int.parse(timeParts[1]);
      final sec = int.parse(timeParts[2]);

      if (day < 1 || day > 31) {
        throw const FormatException('Day out of range');
      }
      if (hour < 0 || hour > 23) {
        throw const FormatException('Hour out of range');
      }
      if (min < 0 || min > 59) {
        throw const FormatException('Minute out of range');
      }
      if (sec < 0 || sec > 60) {
        throw const FormatException(
          'Second out of range',
        ); // Allow leap seconds
      }

      return DateTime.utc(year, month, day, hour, min, sec);
    } catch (e) {
      if (e is FormatException) rethrow;
      throw FormatException('Failed to parse HTTP-date: $header ($e)');
    }
  }
}
