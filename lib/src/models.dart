import 'package:flutter/foundation.dart';

/// Represents a verified point-in-time anchor pinned to hardware uptime.
///
/// A [TrustAnchor] captures the precise relationship between network-verified
/// UTC time and the device's monotonic uptime clock at the moment of
/// synchronization. This relationship is the foundation for all subsequent
/// tamper-proof time calculations:
///
/// ```
/// trustedNow = networkUtcMs + (currentUptime - uptimeMs)
/// ```
///
/// Because monotonic uptime cannot be manipulated by the user, the anchor
/// remains valid until the device reboots (which resets the uptime counter).
@immutable
final class TrustAnchor {
  /// Creates a new trust anchor from a successful network synchronization.
  ///
  /// All values are in milliseconds since their respective epochs:
  /// - [networkUtcMs]: Unix epoch (1970-01-01T00:00:00Z)
  /// - [uptimeMs]: Device boot time
  /// - [wallMs]: Unix epoch (device's local wall clock at sync time)
  const TrustAnchor({
    required this.networkUtcMs,
    required this.uptimeMs,
    required this.wallMs,
    required this.uncertaintyMs,
  });

  /// The verified UTC time from network consensus, in milliseconds since
  /// the Unix epoch.
  final int networkUtcMs;

  /// The device's monotonic uptime at the moment of synchronization, in
  /// milliseconds since boot.
  ///
  /// This value is immune to system clock manipulation and only resets on
  /// device reboot.
  final int uptimeMs;

  /// The device's wall-clock time at the moment of synchronization, in
  /// milliseconds since the Unix epoch.
  ///
  /// Used for elapsed-time calculations and offline estimation. Unlike
  /// [uptimeMs], this value can be manipulated by the user.
  final int wallMs;

  /// The estimated uncertainty of the network time measurement, in
  /// milliseconds.
  ///
  /// Derived from the Marzullo intersection width — smaller values indicate
  /// higher confidence in the anchor's accuracy.
  final int uncertaintyMs;

  /// Returns the [networkUtcMs] as a UTC [DateTime].
  DateTime get networkUtc =>
      DateTime.fromMillisecondsSinceEpoch(networkUtcMs, isUtc: true);

  /// Creates a copy of this anchor with an updated [uncertaintyMs].
  TrustAnchor copyWith({int? uncertaintyMs}) => TrustAnchor(
    networkUtcMs: networkUtcMs,
    uptimeMs: uptimeMs,
    wallMs: wallMs,
    uncertaintyMs: uncertaintyMs ?? this.uncertaintyMs,
  );

  /// Serializes this anchor to a JSON-compatible map for secure storage.
  Map<String, dynamic> toJson() => {
    'networkUtcMs': networkUtcMs,
    'uptimeMs': uptimeMs,
    'wallMs': wallMs,
    'uncertaintyMs': uncertaintyMs,
  };

  /// Deserializes a [TrustAnchor] from a JSON map.
  ///
  /// Throws if any required key is missing or has an incorrect type.
  factory TrustAnchor.fromJson(Map<String, dynamic> j) => TrustAnchor(
    networkUtcMs: j['networkUtcMs'] as int,
    uptimeMs: j['uptimeMs'] as int,
    wallMs: j['wallMs'] as int,
    uncertaintyMs: j['uncertaintyMs'] as int,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustAnchor &&
          networkUtcMs == other.networkUtcMs &&
          uptimeMs == other.uptimeMs &&
          wallMs == other.wallMs &&
          uncertaintyMs == other.uncertaintyMs;

  @override
  int get hashCode =>
      Object.hash(networkUtcMs, uptimeMs, wallMs, uncertaintyMs);

  @override
  String toString() =>
      'TrustAnchor(utc: $networkUtcMs, uptime: $uptimeMs, '
      'wall: $wallMs, uncertainty: ±${uncertaintyMs}ms)';
}

/// Identifies the broad category of a time-authority source.
enum TimeSourceKind {
  /// Network Time Protocol (UDP).
  ntp,

  /// HTTPS `Date` header probe.
  https,

  /// Application-supplied custom source.
  custom,
}

/// NTP leap-second indicator (per RFC 5905).
enum LeapIndicator { noWarning, addSecond, deleteSecond, unsynchronized }

/// Structured metadata describing the origin of a [TimeSample].
///
/// Carries protocol-level signals that the sync engine and downstream
/// consumers can use to weight, audit, or annotate the sample.
@immutable
final class TimeSourceMetadata {
  const TimeSourceMetadata({
    required this.kind,
    required this.id,
    this.host,
    this.stratum,
    this.leapIndicator,
  });

  /// Broad category of the source (NTP / HTTPS / custom).
  final TimeSourceKind kind;

  /// Unique identifier matching [TrustedTimeSource.id].
  final String id;

  /// Hostname or URL queried, when applicable.
  final String? host;

  /// NTP stratum value (1-15), if reported by the protocol.
  final int? stratum;

  /// NTP leap-second indicator, if reported by the protocol.
  final LeapIndicator? leapIndicator;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeSourceMetadata &&
          kind == other.kind &&
          id == other.id &&
          host == other.host &&
          stratum == other.stratum &&
          leapIndicator == other.leapIndicator;

  @override
  int get hashCode => Object.hash(kind, id, host, stratum, leapIndicator);

  @override
  String toString() =>
      'TimeSourceMetadata(kind: $kind, id: $id, host: $host, '
      'stratum: $stratum, leap: $leapIndicator)';
}

/// A single observation from a [TrustedTimeSource], captured atomically at
/// the moment the network response was received.
///
/// Pinning [capturedMonotonicMs] inside the source — rather than after all
/// queries resolve — keeps the anchor's reference point free of drift from
/// slower siblings.
@immutable
final class TimeSample {
  const TimeSample({
    required this.networkUtc,
    required this.roundTripTime,
    required this.uncertainty,
    required this.capturedMonotonicMs,
    required this.source,
    required this.capturedAt,
  });

  /// UTC time reported by the source (already RTT-corrected by the source
  /// implementation when applicable).
  final DateTime networkUtc;

  /// Measured round-trip latency to acquire this sample.
  final Duration roundTripTime;

  /// Estimated uncertainty (half-RTT by default; sources with tighter
  /// internal estimates may report less).
  final Duration uncertainty;

  /// Device monotonic uptime in milliseconds, captured the instant the
  /// response was received.
  final int capturedMonotonicMs;

  /// Origin metadata for auditing and consensus weighting.
  final TimeSourceMetadata source;

  /// Wall-clock time at sample capture (diagnostics only — not used for
  /// trust decisions).
  final DateTime capturedAt;
}

/// Contract for implementing custom time-authority providers.
///
/// Implement this interface to add enterprise or custom time sources
/// (e.g., a company-internal NTP server or a proprietary time API)
/// to the TrustedTime consensus pool.
///
/// ```dart
/// class MyTimeSource implements TrustedTimeSource {
///   @override
///   String get id => 'my-company-ntp';
///
///   @override
///   Future<TimeSample> fetch() async {
///     // Query your time authority and return a structured sample.
///   }
/// }
/// ```
abstract interface class TrustedTimeSource {
  /// A unique identifier for this source, used in debug logging and
  /// consensus weighting (e.g., `'ntp:time.google.com'`).
  String get id;

  /// Queries the remote time authority and returns a structured
  /// [TimeSample] including UTC, round-trip time, captured monotonic
  /// uptime, and origin metadata.
  ///
  /// Implementations must capture the monotonic reference at the moment
  /// the response is received (before any aggregation) and should throw
  /// on failure rather than returning stale or estimated values — the
  /// sync engine handles failures gracefully.
  Future<TimeSample> fetch();
}

/// Immutable configuration for the TrustedTime engine.
///
/// All parameters have sensible defaults for most applications. Pass a
/// custom [TrustedTimeConfig] to [TrustedTime.initialize] to tune behavior
/// for specific requirements.
///
/// ```dart
/// await TrustedTime.initialize(
///   config: TrustedTimeConfig(
///     refreshInterval: Duration(hours: 6),
///     minimumQuorum: 3,
///   ),
/// );
/// ```
@immutable
final class TrustedTimeConfig {
  /// Creates a new configuration with the given parameters.
  ///
  /// All parameters are optional and fall back to production-safe defaults.
  const TrustedTimeConfig({
    this.refreshInterval = const Duration(hours: 12),
    this.ntpServers = const [
      'time.google.com',
      'time.cloudflare.com',
      'pool.ntp.org',
    ],
    this.httpsSources = const [
      'https://www.google.com',
      'https://www.cloudflare.com',
    ],
    this.maxLatency = const Duration(seconds: 3),
    this.minimumQuorum = 2,
    this.persistState = true,
    this.additionalSources = const [],
    this.oscillatorDriftFactor = 0.00005,
    this.backgroundSyncInterval,
  });

  /// How often the engine re-validates its anchor against network sources.
  ///
  /// Defaults to 12 hours. Shorter intervals increase accuracy but use
  /// more network bandwidth.
  final Duration refreshInterval;

  /// NTP server hostnames to query via UDP.
  ///
  /// At least [minimumQuorum] servers should be listed for reliable
  /// consensus. Defaults to Google, Cloudflare, and pool.ntp.org.
  final List<String> ntpServers;

  /// HTTPS URLs whose `Date` headers are used as a fallback time source.
  ///
  /// This provides a universal fallback for environments where UDP (NTP)
  /// traffic is blocked (e.g., corporate firewalls).
  final List<String> httpsSources;

  /// Maximum acceptable round-trip latency for a single source query.
  ///
  /// Responses exceeding this threshold are discarded as too noisy.
  /// Defaults to 3 seconds.
  final Duration maxLatency;

  /// Minimum number of agreeing sources required to establish consensus.
  ///
  /// Must be ≥ 2 for meaningful tamper resistance. The engine will throw
  /// [TrustedTimeSyncException] if fewer sources agree.
  final int minimumQuorum;

  /// Whether to persist the trust anchor in secure storage.
  ///
  /// When `true`, the anchor survives app restarts without requiring
  /// a fresh network sync (unless a device reboot is detected).
  final bool persistState;

  /// Additional custom [TrustedTimeSource] implementations to include
  /// in the consensus pool alongside the built-in NTP and HTTPS sources.
  final List<TrustedTimeSource> additionalSources;

  /// Estimated local oscillator drift rate in ms/ms.
  ///
  /// Used to calculate error bounds for offline time estimation.
  /// The default value of `0.00005` (50 ppm) is conservative for
  /// typical mobile device quartz oscillators.
  final double oscillatorDriftFactor;

  /// Optional interval for automatic background synchronization.
  ///
  /// When set, the engine registers OS-level background tasks
  /// (WorkManager on Android, BGTaskScheduler on iOS) to refresh the
  /// anchor periodically even when the app is not in the foreground.
  final Duration? backgroundSyncInterval;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedTimeConfig &&
          refreshInterval == other.refreshInterval &&
          listEquals(ntpServers, other.ntpServers) &&
          listEquals(httpsSources, other.httpsSources) &&
          maxLatency == other.maxLatency &&
          minimumQuorum == other.minimumQuorum &&
          persistState == other.persistState &&
          oscillatorDriftFactor == other.oscillatorDriftFactor &&
          backgroundSyncInterval == other.backgroundSyncInterval &&
          listEquals(additionalSources, other.additionalSources);

  @override
  int get hashCode => Object.hash(
    refreshInterval,
    Object.hashAll(ntpServers),
    Object.hashAll(httpsSources),
    maxLatency,
    minimumQuorum,
    persistState,
    oscillatorDriftFactor,
    backgroundSyncInterval,
    Object.hashAll(additionalSources),
  );
}
