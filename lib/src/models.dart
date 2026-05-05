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
  /// Network Time Security (RFC 8915) — authenticated NTPv4 over UDP
  /// with TLS-derived AEAD keys.
  nts,

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
    this.authenticated = false,
  });

  /// Broad category of the source (NTP / NTS / HTTPS / custom).
  final TimeSourceKind kind;

  /// Unique identifier matching [TrustedTimeSource.id].
  final String id;

  /// Hostname or URL queried, when applicable.
  final String? host;

  /// NTP stratum value (1-15), if reported by the protocol.
  final int? stratum;

  /// NTP leap-second indicator, if reported by the protocol.
  final LeapIndicator? leapIndicator;

  /// Whether this sample was cryptographically authenticated end-to-end
  /// (e.g., via NTS AEAD verification). Plain NTP and HTTPS-`Date`
  /// samples are never authenticated.
  final bool authenticated;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeSourceMetadata &&
          kind == other.kind &&
          id == other.id &&
          host == other.host &&
          stratum == other.stratum &&
          leapIndicator == other.leapIndicator &&
          authenticated == other.authenticated;

  @override
  int get hashCode =>
      Object.hash(kind, id, host, stratum, leapIndicator, authenticated);

  @override
  String toString() =>
      'TimeSourceMetadata(kind: $kind, id: $id, host: $host, '
      'stratum: $stratum, leap: $leapIndicator, '
      'authenticated: $authenticated)';
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
  ///
  /// Must be non-negative. The sync engine drops samples that violate
  /// this contract from both the Marzullo intersection and the
  /// lowest-RTT anchor reduction; if enough remaining sources still
  /// agree, the sync succeeds without the malformed sample. If quorum
  /// cannot be reached after rejection, the engine throws
  /// `TrustedTimeSyncException` with a diagnostic that reports the
  /// eligible-vs-rejected counts among samples that survived latency
  /// filtering, alongside any latency drops, timeouts, and outright
  /// failures (e.g. `0 eligible (2 rejected as invalid; 1 dropped
  /// for exceeding maxLatency=...; 1 timed out at maxLatency=...;
  /// 1 yielded no usable sample)`). The "yielded no usable sample"
  /// bucket appears whenever a source threw, raised an inner request
  /// timeout, or returned a payload that could not be parsed —
  /// surfacing it here keeps a mixed run (some eligible, some
  /// failed) from being misread as a pure latency or invalidity
  /// shortfall. When *no* sample reaches the eligible set the engine
  /// raises a categorical diagnostic naming the cause: a pure
  /// outright-failure run reports `Every configured time source
  /// failed to produce a usable sample.`, a pure-timeout run reports
  /// `N source(s) timed out after maxLatency=...`, and a pure
  /// post-hoc run reports `N source(s) responded but every sample
  /// exceeded maxLatency=...`. The `maxLatency=...` token renders in
  /// whichever unit matches the configured precision — ms-aligned
  /// budgets render as `50 ms`, sub-millisecond budgets render as
  /// e.g. `500 µs` so the advertised threshold matches the value the
  /// filter actually compared against. Runs whose outcomes span more
  /// than one of `{timed out, responded over-budget, yielded no
  /// usable sample}` produce a multi-cause message that breaks down
  /// each contributing bucket — so a mixed "one timed out / one
  /// yielded a malformed payload" outage is never silently rebadged
  /// as a pure-timeout cause. The "yielded no usable sample" bucket
  /// spans transport failures, inner request timeouts, and
  /// post-response validation/parse errors (e.g. an HTTPS response
  /// without a usable `Date` header) — the neutral wording avoids
  /// implying the source never responded.
  final Duration roundTripTime;

  /// Confidence half-width of [networkUtc].
  ///
  /// Required: the constructor does not supply an API default. The
  /// built-in `HttpsSource` currently advertises a millisecond-grained
  /// bound — `Duration(milliseconds: stopwatch.elapsedMilliseconds ~/
  /// 2)` — because HTTP `Date` headers carry no sub-second resolution
  /// in the first place; custom sources with access to tighter
  /// information (e.g. an NTS source exposing the server's stratum and
  /// root dispersion) may report a smaller, sub-millisecond value.
  /// The sync engine plumbs this through to the Marzullo consensus
  /// interval `[networkUtc - uncertainty, networkUtc + uncertainty]`
  /// at microsecond resolution — it does **not** re-derive intervals
  /// from [roundTripTime], and it does **not** truncate the advertised
  /// bound to whole milliseconds before the intersection sweep, so an
  /// NTS-style sub-millisecond bound is honoured during consensus
  /// rather than being collapsed to a single-point interval. The
  /// engine still floors the *published* `TrustAnchor.uncertaintyMs`
  /// at 1 ms (rounded up from microseconds) because that is the
  /// realistic lower bound any wall clock can claim. Must be
  /// non-negative; samples reporting a negative uncertainty are
  /// rejected alongside negative-RTT samples for the same
  /// defence-in-depth reasons.
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
/// (e.g., a company-internal time API or a proprietary signed-time
/// service) to the TrustedTime consensus pool.
///
/// ```dart
/// class MyTimeSource implements TrustedTimeSource {
///   @override
///   String get id => 'my-company-time';
///
///   @override
///   Future<TimeSample> fetch() async {
///     // Query your time authority and return a structured sample.
///   }
/// }
/// ```
abstract interface class TrustedTimeSource {
  /// A unique identifier for this source, used in debug logging and
  /// consensus weighting (e.g., `'nts:time.cloudflare.com'`).
  String get id;

  /// Queries the remote time authority and returns a structured
  /// [TimeSample] including UTC, round-trip time, captured monotonic
  /// uptime, and origin metadata.
  ///
  /// Implementations must capture the monotonic reference at the moment
  /// the response is received (before any aggregation) and should throw
  /// on failure rather than returning stale or estimated values — the
  /// sync engine handles failures gracefully.
  ///
  /// Both [TimeSample.roundTripTime] and [TimeSample.uncertainty] must
  /// be non-negative. The sync engine excludes samples that violate
  /// either contract from consensus and anchor selection — a negative
  /// round-trip would invert the latency-eligibility check, and a
  /// negative uncertainty would invert the Marzullo interval (upper
  /// endpoint < lower endpoint) and crash the consensus sweep.
  ///
  /// `uncertainty` is a required parameter on [TimeSample] — the API
  /// does not supply a default. Sources that don't have a tighter
  /// bound to advertise should pass `roundTripTime ~/ 2` themselves
  /// (a generic half-RTT estimate; the built-in `HttpsSource` uses
  /// the millisecond-grained equivalent `Duration(milliseconds:
  /// stopwatch.elapsedMilliseconds ~/ 2)` because HTTP `Date`
  /// headers carry no sub-second resolution anyway). Sources with
  /// access to a tighter bound (e.g. an NTS source exposing the
  /// server's stratum and root dispersion) should supply that
  /// narrower, possibly sub-millisecond value, which the engine
  /// honours at microsecond resolution when building each Marzullo
  /// interval rather than re-deriving it from RTT.
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
    this.ntsServers = const [],
    this.httpsSources = const [
      'https://www.google.com',
      'https://www.cloudflare.com',
      'https://www.apple.com',
      'https://www.microsoft.com',
    ],
    this.maxLatency = const Duration(seconds: 3),
    this.httpsRequestTimeout = const Duration(seconds: 30),
    this.ntsRequestTimeout = const Duration(seconds: 5),
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

  /// NTS-KE server hostnames to query (RFC 8915), opt-in.
  ///
  /// Each entry is a hostname; the IANA-assigned default port `4460`
  /// is always used. Empty by default — the engine ignores NTS unless
  /// explicitly configured. Not supported on web (samples from these
  /// hosts will be silently dropped by the engine on browser builds).
  ///
  /// Configure NTS for cryptographically authenticated samples that
  /// resist on-path attackers. Clear-text NTP is intentionally not
  /// supported by this package — see ADR 0003.
  final List<String> ntsServers;

  /// HTTPS URLs whose `Date` headers are used as a TLS-anchored time
  /// source.
  ///
  /// Defaults to four independent operators (Google, Cloudflare, Apple,
  /// Microsoft) so that the default consensus pool tolerates a single
  /// endpoint failure while still satisfying [minimumQuorum] of 2.
  /// Each `Date` header is bound to a TLS handshake, so a network
  /// attacker cannot forge it without a valid certificate; granularity
  /// is one second.
  final List<String> httpsSources;

  /// Maximum acceptable round-trip latency for a single source query.
  ///
  /// Responses exceeding this threshold are discarded as too noisy.
  /// Defaults to 3 seconds.
  final Duration maxLatency;

  /// Per-request defensive ceiling applied inside each built-in
  /// [HttpsSource] HEAD/GET call.
  ///
  /// Distinct from [maxLatency], which is the engine's outer abandonment
  /// budget. The two timers wrap the same work, so when they are equal
  /// they race and the diagnostic message can come from either bucket
  /// (`timedOut` if the outer wrapper fires first, `failed` if the inner
  /// one does). For deterministic attribution this value must be
  /// **strictly greater than** [maxLatency]; the default of 30 s is
  /// chosen to sit comfortably above the default [maxLatency] of 3 s.
  ///
  /// Callers configuring [maxLatency] above 30 s must raise this in
  /// step (e.g. `maxLatency: 60s, httpsRequestTimeout: 90s`); otherwise
  /// every probe will surface the inner ceiling first and be bucketed
  /// as `failed`. The strict-greater rule is enforced by an assert in
  /// the [SyncEngine] constructor when [httpsSources] is non-empty;
  /// HTTPS-free configs may leave this value at any setting.
  ///
  /// Callers concerned about lingering background work — `Future.timeout`
  /// does not cancel the in-flight HTTP request, so an abandoned probe
  /// keeps running until the response arrives, the underlying client
  /// tears down the socket, or this ceiling fires, whichever comes
  /// first — can pass a smaller value (e.g. `Duration(seconds: 5)`)
  /// **provided it remains strictly greater than [maxLatency]**. Values
  /// at or below [maxLatency] are rejected by the [SyncEngine]
  /// constructor in debug builds when [httpsSources] is non-empty;
  /// the same gate that enforces the strict-greater rule above also
  /// rejects this lowering pattern when it would re-introduce the race.
  /// Lowering below the default of 30 s while keeping the inequality
  /// satisfied is the supported way to shorten lingering work.
  ///
  /// Has no effect on [additionalSources]; custom [TrustedTimeSource]
  /// implementations are responsible for their own per-request bounds.
  final Duration httpsRequestTimeout;

  /// Per-NTS-query defensive ceiling applied inside each built-in NTS
  /// source's KE-handshake and individual NTPv4 query.
  ///
  /// The structural relationship to [maxLatency] mirrors
  /// [httpsRequestTimeout]: both timers wrap the same underlying work,
  /// so equal values race and the diagnostic bucket (`timedOut` vs
  /// `failed`) becomes scheduler-dependent. For deterministic
  /// attribution this value must be **strictly greater than**
  /// [maxLatency]; the default of 5 s is chosen to sit above the
  /// default [maxLatency] of 3 s.
  ///
  /// Quantitatively the NTS path differs: the inner ceiling applies
  /// per-query, and the built-in source issues a burst of authenticated
  /// samples per `fetch()` (lowest-RTD wins). A single hung query may
  /// fire the inner deadline and surface as `failed` even though the
  /// overall `fetch()` would still have returned the better samples in
  /// the burst — hence "strictly greater than [maxLatency]" is
  /// necessary but not sufficient on its own to keep slow probes in
  /// the `timedOut` bucket. Callers configuring [maxLatency] above
  /// 5 s must raise this in step (e.g. `maxLatency: 10s,
  /// ntsRequestTimeout: 15s`). The strict-greater rule is enforced by
  /// an assert in the [SyncEngine] constructor when [ntsServers] is
  /// non-empty; NTS-free configs may leave this value at any setting.
  ///
  /// The FRB bridge underlying the built-in NTS source carries the
  /// per-query ceiling as an integer millisecond count. Sub-millisecond
  /// values pass through `Duration.inMicroseconds` and are rounded
  /// **up** to the next whole millisecond before reaching the bridge,
  /// so the strict-greater inequality survives the precision drop
  /// (a 3.6 ms ceiling above a 3.5 ms outer budget reaches the bridge
  /// as 4 ms, still strictly greater). Callers wanting an exact
  /// inner deadline should pass an integer-millisecond [Duration].
  ///
  /// Has no effect on [additionalSources]; custom [TrustedTimeSource]
  /// implementations are responsible for their own per-request bounds.
  final Duration ntsRequestTimeout;

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
  /// in the consensus pool alongside the built-in NTS and HTTPS sources.
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
          listEquals(ntsServers, other.ntsServers) &&
          listEquals(httpsSources, other.httpsSources) &&
          maxLatency == other.maxLatency &&
          httpsRequestTimeout == other.httpsRequestTimeout &&
          ntsRequestTimeout == other.ntsRequestTimeout &&
          minimumQuorum == other.minimumQuorum &&
          persistState == other.persistState &&
          oscillatorDriftFactor == other.oscillatorDriftFactor &&
          backgroundSyncInterval == other.backgroundSyncInterval &&
          listEquals(additionalSources, other.additionalSources);

  @override
  int get hashCode => Object.hash(
    refreshInterval,
    Object.hashAll(ntsServers),
    Object.hashAll(httpsSources),
    maxLatency,
    httpsRequestTimeout,
    ntsRequestTimeout,
    minimumQuorum,
    persistState,
    oscillatorDriftFactor,
    backgroundSyncInterval,
    Object.hashAll(additionalSources),
  );
}
