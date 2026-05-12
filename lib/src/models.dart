import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;
import 'domain/time_source.dart';
import 'exceptions.dart';
import 'sources/nts_auth_level.dart';

/// Qualitative grades of consensus integrity.
///
/// These levels represent the engine's confidence in the accuracy of the current
/// [TrustAnchor] based on population depth, provider diversity, and variance.
enum ConfidenceLevel {
  /// The engine has not yet reached a stable quorum, or the current state
  /// has been explicitly invalidated (e.g., after an integrity violation).
  none,

  /// A consensus has been achieved, but the population depth or provider
  /// diversity is minimal (e.g., only two sources from the same network group).
  low,

  /// A stable quorum has been reached with adequate provider diversity
  /// (multiple administrative groups/protocols).
  medium,

  /// A high-integrity quorum has been reached with broad diversity across
  /// protocols (NTP, HTTPS, NTS) and extremely low population variance.
  high,
}

@immutable
/// Configuration parameters for the [TrustedTime] engine.
///
/// This class defines the behavioral policy of the engine, including quorum
/// requirements, security thresholds, and background synchronization intervals.
///
/// ## Mutability contract
///
/// [TrustedTimeConfig] is annotated `@immutable` and its scalar
/// fields are `final`. The list-typed fields ([ntpServers],
/// [httpsSources], [ntsServers], [additionalSources]) are stored by
/// reference for `const`-constructibility — the canonical
/// production usage is to pass `const`-list literals, which are
/// already deeply immutable.
///
/// Callers that construct a non-`const` [TrustedTimeConfig] from
/// growable lists **must not mutate those lists after construction**.
/// Doing so will silently break the value-equality and `hashCode`
/// contracts (potentially corrupting any [Set] or [Map] keyed on
/// the config) and will make the live engine config drift from the
/// snapshot returned by [TrustedTime.config].
final class TrustedTimeConfig {
  /// Creates a new configuration instance with sensible production defaults.
  const TrustedTimeConfig({
    this.ntpServers = const ['pool.ntp.org', 'time.google.com'],
    this.httpsSources = const [
      'https://www.google.com',
      'https://www.cloudflare.com',
      'https://time.cloudflare.com',
      'https://www.apple.com',
      'https://www.microsoft.com',
    ],
    this.ntsServers = const ['time.cloudflare.com'],
    this.ntsPort = 4460,
    this.ntsDnsConcurrencyCap,
    this.ntsTrustMode = nts.TrustMode.platformWithFallback,
    this.additionalSources = const [],
    this.minQuorumRatio = 0.6,
    this.minimumQuorum = 2,
    this.minGroupCount = 2,
    this.maxLatency = const Duration(seconds: 4),
    this.refreshInterval = const Duration(minutes: 30),
    this.maxAllowedUncertaintyMs = 5000,
    this.persistState = true,
    this.earlyExit = true,
    this.oscillatorDriftFactor = 0.00005,
    this.backgroundSyncInterval,
    this.transientStreakThreshold = 5,
  });

  /// Creates a Web-compatible configuration that only uses HTTPS sources.
  ///
  /// Web platforms don't support UDP sockets (required for NTP/NTS), so this
  /// configuration excludes NTP and NTS servers, relying solely on HTTP/HTTPS
  /// endpoints that work in browsers and WASM environments.
  factory TrustedTimeConfig.web() {
    return const TrustedTimeConfig(
      ntpServers: [], // No UDP support on Web
      ntsServers: [], // No TCP support on Web
      httpsSources: [
        'https://www.google.com',
        'https://www.cloudflare.com',
        'https://time.cloudflare.com',
        'https://www.apple.com',
        'https://www.microsoft.com',
        'https://api.github.com',
        'https://httpbin.org',
        'https://www.wikipedia.org',
      ],
      minimumQuorum: 2,
      minGroupCount: 2,
      maxLatency: Duration(seconds: 5),
      refreshInterval: Duration(hours: 1),
    );
  }

  /// The list of authoritative NTP server hostnames used for synchronization.
  final List<String> ntpServers;

  /// The list of HTTP/HTTPS endpoints used to extract UTC time from the `Date` header.
  final List<String> httpsSources;

  /// The list of Network Time Security (NTS) servers used for cryptographically
  /// authenticated synchronization.
  final List<String> ntsServers;

  /// The TCP port used for the NTS Key Exchange (NTS-KE) handshake.
  /// Defaults to 4460 as per RFC 8915.
  final int ntsPort;

  /// Per-call ceiling on `package:nts`'s process-wide bounded DNS
  /// resolver pool, forwarded to every `ntsQuery` and `ntsWarmCookies`
  /// the engine issues.
  ///
  /// When `null` (the default), [SyncEngine] auto-sizes the cap as
  /// `ntsServers.length + 2`, which keeps each cycle's concurrent
  /// resolutions safely under the limit and avoids the deterministic
  /// `NtsError.timeout` refusals that occur when more than four
  /// resolutions race for admission. Set this explicitly when the
  /// process hosts other concurrent `package:nts` callers (the pool is
  /// process-global, so every admitted worker counts toward every
  /// caller's threshold).
  final int? ntsDnsConcurrencyCap;

  /// Trust-anchor policy applied to every per-source [nts.NtsClient]
  /// constructed by the engine.
  ///
  /// Defaults to [nts.TrustMode.platformWithFallback], which preserves
  /// the behaviour of every release prior to the `package:nts` v3.0.0
  /// migration: each NTS-KE handshake first attempts the platform
  /// trust store, then silently falls back to the bundled
  /// `webpki-roots` static bundle if `build_with_native_verifier`
  /// fails at TLS-config construction.
  ///
  /// Set to [nts.TrustMode.platformOnly] when a pinned corporate CA
  /// or an MDM-installed root is the load-bearing trust anchor and a
  /// silent downgrade to the public-CA bundle would defeat the
  /// deployment's TLS-inspection posture. With this mode,
  /// `build_with_native_verifier` failure surfaces as an
  /// `NtsError.trustBackendUnavailable` (consumed by the engine as a
  /// per-source failure) instead of producing a successful sample
  /// against the static bundle.
  ///
  /// **Scope:** This governs the **build-time** hard-fallback decision
  /// only. On Android, the platform-side `HybridVerifier` makes a
  /// separate **per-chain** decision after the platform verifier
  /// returns: chains the platform verifier rejects with a curated
  /// fallback-eligible failure shape (e.g. missing-OCSP-AIA chains
  /// such as Let's Encrypt R12) can still be accepted via the
  /// `webpki-roots` static bundle and surface as
  /// `TrustBackend.platformWithHybridFallback`. That path is not
  /// affected by this field. `platformOnly` therefore means "no
  /// silent build-time downgrade", not "the public-CA bundle is
  /// unreachable at runtime".
  final nts.TrustMode ntsTrustMode;

  /// Custom [TimeSource] implementations provided by the application developer.
  final List<TimeSource> additionalSources;

  /// The minimum fraction of responding sources (0.0 to 1.0) that must overlap
  /// for a consensus to be considered valid.
  final double minQuorumRatio;

  /// The absolute minimum number of agreeing sources required to establish trust.
  final int minimumQuorum;

  /// The minimum number of distinct administrative groups (e.g., different ASNs
  /// or protocols) required to reach higher confidence levels.
  final int minGroupCount;

  /// The maximum amount of time the engine will wait for a response from any
  /// single source before it is discarded.
  final Duration maxLatency;

  /// The frequency at which the engine enters a proactive synchronization cycle
  /// while the app is in the foreground.
  final Duration refreshInterval;

  /// The hard threshold for precision. If a consensus result has an uncertainty
  /// (width/2) exceeding this value, it is discarded.
  final int maxAllowedUncertaintyMs;

  /// Whether to persist the last verified [TrustAnchor] to secure storage.
  /// Allows for faster "warm-start" trust establishment on app restart.
  final bool persistState;

  /// If true, the engine will stop querying sources as soon as a stable quorum
  /// is reached, conserving network and battery resources.
  final bool earlyExit;

  /// The assumed drift rate of the device oscillator in seconds per second.
  /// Used for offline confidence degradation (0.00005 ≈ 50ppm).
  final double oscillatorDriftFactor;

  /// The interval at which the engine should perform a background synchronization.
  /// If null, background synchronization is disabled.
  final Duration? backgroundSyncInterval;

  /// Number of consecutive [TransientSourceError] failures from a
  /// single source before the engine escalates that source onto the
  /// same exponential-cooldown ladder regular failures use.
  ///
  /// [TransientSourceError] exists so the engine can retry an
  /// otherwise-healthy source on the next cycle without applying
  /// cooldown — the canonical case is `package:nts`'s
  /// `NtsError.timeout(TimeoutPhase.dnsSaturation)`, where the
  /// bounded DNS resolver pool was momentarily full and the source
  /// itself is fine. A genuinely transient condition resolves within
  /// a cycle or two; a "transient" condition that persists across
  /// many cycles is indistinguishable from a sustained outage as far
  /// as quorum participation goes, and should be treated like one.
  ///
  /// When this many consecutive transient failures accumulate from
  /// the same source, the engine increments that source's failure
  /// score and applies the standard capped-exponential
  /// `2^min(score, 6)`-minute cooldown (i.e. doubling from 2
  /// minutes at score 1 up to 64 minutes at score 6, then flat
  /// thereafter), identical to what a non-transient failure would
  /// produce. The streak counter resets on a successful query, on a
  /// regular (non-transient) failure, and on each escalation.
  ///
  /// Default: `5`. With the default [refreshInterval] of 30 minutes
  /// this corresponds to ~2.5 hours of sustained transients before
  /// escalation, long enough that a real DNS-pool burst clears
  /// naturally and short enough that a stuck host eventually
  /// surfaces as unhealthy.
  ///
  /// Set to `0` (or any non-positive value) to disable escalation
  /// entirely and preserve the pre-streak-guard behaviour where
  /// transient failures retry indefinitely.
  final int transientStreakThreshold;

  /// Returns a new [TrustedTimeConfig] with the supplied fields replaced.
  ///
  /// Any field omitted (or passed as `null`) keeps its current value.
  /// [backgroundSyncInterval] cannot be cleared back to `null` through
  /// this method; construct a new instance directly if that is needed.
  TrustedTimeConfig copyWith({
    List<String>? ntpServers,
    List<String>? httpsSources,
    List<String>? ntsServers,
    int? ntsPort,
    int? ntsDnsConcurrencyCap,
    nts.TrustMode? ntsTrustMode,
    List<TimeSource>? additionalSources,
    double? minQuorumRatio,
    int? minimumQuorum,
    int? minGroupCount,
    Duration? maxLatency,
    Duration? refreshInterval,
    int? maxAllowedUncertaintyMs,
    bool? persistState,
    bool? earlyExit,
    double? oscillatorDriftFactor,
    Duration? backgroundSyncInterval,
    int? transientStreakThreshold,
  }) {
    return TrustedTimeConfig(
      ntpServers: ntpServers ?? this.ntpServers,
      httpsSources: httpsSources ?? this.httpsSources,
      ntsServers: ntsServers ?? this.ntsServers,
      ntsPort: ntsPort ?? this.ntsPort,
      ntsDnsConcurrencyCap: ntsDnsConcurrencyCap ?? this.ntsDnsConcurrencyCap,
      ntsTrustMode: ntsTrustMode ?? this.ntsTrustMode,
      additionalSources: additionalSources ?? this.additionalSources,
      minQuorumRatio: minQuorumRatio ?? this.minQuorumRatio,
      minimumQuorum: minimumQuorum ?? this.minimumQuorum,
      minGroupCount: minGroupCount ?? this.minGroupCount,
      maxLatency: maxLatency ?? this.maxLatency,
      refreshInterval: refreshInterval ?? this.refreshInterval,
      maxAllowedUncertaintyMs:
          maxAllowedUncertaintyMs ?? this.maxAllowedUncertaintyMs,
      persistState: persistState ?? this.persistState,
      earlyExit: earlyExit ?? this.earlyExit,
      oscillatorDriftFactor:
          oscillatorDriftFactor ?? this.oscillatorDriftFactor,
      backgroundSyncInterval:
          backgroundSyncInterval ?? this.backgroundSyncInterval,
      transientStreakThreshold:
          transientStreakThreshold ?? this.transientStreakThreshold,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrustedTimeConfig &&
        listEquals(other.ntpServers, ntpServers) &&
        listEquals(other.httpsSources, httpsSources) &&
        listEquals(other.ntsServers, ntsServers) &&
        other.ntsPort == ntsPort &&
        other.ntsDnsConcurrencyCap == ntsDnsConcurrencyCap &&
        other.ntsTrustMode == ntsTrustMode &&
        listEquals(other.additionalSources, additionalSources) &&
        other.minQuorumRatio == minQuorumRatio &&
        other.minimumQuorum == minimumQuorum &&
        other.minGroupCount == minGroupCount &&
        other.maxLatency == maxLatency &&
        other.refreshInterval == refreshInterval &&
        other.maxAllowedUncertaintyMs == maxAllowedUncertaintyMs &&
        other.persistState == persistState &&
        other.earlyExit == earlyExit &&
        other.oscillatorDriftFactor == oscillatorDriftFactor &&
        other.backgroundSyncInterval == backgroundSyncInterval &&
        other.transientStreakThreshold == transientStreakThreshold;
  }

  @override
  int get hashCode => Object.hashAll([
    Object.hashAll(ntpServers),
    Object.hashAll(httpsSources),
    Object.hashAll(ntsServers),
    ntsPort,
    ntsDnsConcurrencyCap,
    ntsTrustMode,
    Object.hashAll(additionalSources),
    minQuorumRatio,
    minimumQuorum,
    minGroupCount,
    maxLatency,
    refreshInterval,
    maxAllowedUncertaintyMs,
    persistState,
    earlyExit,
    oscillatorDriftFactor,
    backgroundSyncInterval,
    transientStreakThreshold,
  ]);

  @override
  String toString() {
    // Multi-line layout because the source pools and quorum knobs are
    // the fields operators most often want to confirm during a
    // benchmarking session, and a single-line dump runs off the edge
    // of a typical terminal long before it gets to the scalar
    // settings. Keep field order in sync with the constructor so a
    // diff between an expected and actual config reads top-to-bottom.
    return 'TrustedTimeConfig(\n'
        '  ntpServers: $ntpServers,\n'
        '  httpsSources: $httpsSources,\n'
        '  ntsServers: $ntsServers,\n'
        '  ntsPort: $ntsPort,\n'
        '  ntsDnsConcurrencyCap: $ntsDnsConcurrencyCap,\n'
        '  ntsTrustMode: $ntsTrustMode,\n'
        '  additionalSources: $additionalSources,\n'
        '  minQuorumRatio: $minQuorumRatio,\n'
        '  minimumQuorum: $minimumQuorum,\n'
        '  minGroupCount: $minGroupCount,\n'
        '  maxLatency: $maxLatency,\n'
        '  refreshInterval: $refreshInterval,\n'
        '  maxAllowedUncertaintyMs: $maxAllowedUncertaintyMs,\n'
        '  persistState: $persistState,\n'
        '  earlyExit: $earlyExit,\n'
        '  oscillatorDriftFactor: $oscillatorDriftFactor,\n'
        '  backgroundSyncInterval: $backgroundSyncInterval,\n'
        '  transientStreakThreshold: $transientStreakThreshold,\n'
        ')';
  }
}

@immutable
/// A hardware-anchored snapshot representing a verified network consensus.
///
/// This model acts as the "source of truth" for the engine. It links the
/// network-verified UTC time to the device's hardware monotonic clock at a
/// specific moment in time.
final class TrustAnchor {
  /// Creates a new [TrustAnchor] from network-verified time and monotonic clock measurements.
  const TrustAnchor({
    required this.networkUtcMs,
    required this.uptimeMs,
    required this.wallMs,
    required this.uncertaintyMs,
    this.authLevel = NtsAuthLevel.none,
    this.confidence = ConfidenceLevel.low,
  });

  /// Deserializes a [TrustAnchor] from a JSON map with rigorous bounds checking.
  factory TrustAnchor.fromJson(Map<String, dynamic> json) {
    try {
      final authIdx = json['authLevel'] as int? ?? 0;
      final confIdx = json['confidence'] as int? ?? 0;

      // CRITICAL-6: Prevent RangeError or malformed state during deserialization.
      final authLevel = (authIdx >= 0 && authIdx < NtsAuthLevel.values.length)
          ? NtsAuthLevel.values[authIdx]
          : NtsAuthLevel.none;

      final confidence =
          (confIdx >= 0 && confIdx < ConfidenceLevel.values.length)
          ? ConfidenceLevel.values[confIdx]
          : ConfidenceLevel.none;

      return TrustAnchor(
        networkUtcMs: json['networkUtcMs'] as int,
        uptimeMs: json['uptimeMs'] as int,
        wallMs: json['wallMs'] as int,
        uncertaintyMs: json['uncertaintyMs'] as int,
        authLevel: authLevel,
        confidence: confidence,
      );
    } catch (e) {
      throw TrustedTimePersistenceException('Malformed TrustAnchor JSON: $e');
    }
  }

  /// The UTC timestamp established by the network consensus (milliseconds).
  final int networkUtcMs;

  /// The device's monotonic uptime at the moment the consensus was reached.
  final int uptimeMs;

  /// The device's system wall-clock time at the moment the consensus was reached.
  final int wallMs;

  /// The calculated precision of the consensus (half-width of the intersection).
  final int uncertaintyMs;

  /// The common authentication level achieved by the quorum participants.
  final NtsAuthLevel authLevel;

  /// The qualitative grade of this anchor (none, low, medium, or high).
  final ConfidenceLevel confidence;

  /// Alias for [networkUtcMs].
  int get trustedUtcMs => networkUtcMs;

  /// A normalized score (0.0 to 1.0) representing the reliability of this anchor.
  double get confidenceScore {
    switch (confidence) {
      case ConfidenceLevel.none:
        return 0.0;
      case ConfidenceLevel.low:
        return 0.3;
      case ConfidenceLevel.medium:
        return 0.7;
      case ConfidenceLevel.high:
        return 1.0;
    }
  }

  /// Serializes the anchor for secure local storage.
  Map<String, dynamic> toJson() => {
    'networkUtcMs': networkUtcMs,
    'uptimeMs': uptimeMs,
    'wallMs': wallMs,
    'uncertaintyMs': uncertaintyMs,
    'authLevel': authLevel.index,
    'confidence': confidence.index,
  };
}

@immutable
/// Diagnostic metrics captured during a synchronization cycle.
final class SyncMetrics {
  /// Creates a new [SyncMetrics] instance with diagnostic data from a synchronization cycle.
  const SyncMetrics({
    required this.latencyMs,
    required this.uncertaintyMs,
    required this.participantCount,
    required this.quorumDepth,
    required this.groupCount,
    required this.confidence,
    required this.confidenceBreakdown,
  });

  /// The total time taken for the network synchronization cycle.
  final int latencyMs;

  /// The precision achieved by the resolved consensus.
  final int uncertaintyMs;

  /// The number of unique time authorities whose interval contains the
  /// consensus midpoint. Stricter than [quorumDepth] — see
  /// `ConsensusResult.participantCount` for the divergence conditions.
  /// Use [quorumDepth] for quorum-floor reasoning.
  final int participantCount;

  /// The number of unique sources active at the densest overlap point
  /// during Marzullo's sweep. This is the figure used by the quorum
  /// check and confidence grading.
  ///
  /// For values produced by the engine, always satisfies
  /// `quorumDepth >= participantCount`. This is an engine invariant,
  /// not a structural one — the type does not constrain the pairing,
  /// since [SyncMetrics] is publicly constructible for tests and mocks
  /// (and the underlying `int` field permits negative values too, even
  /// though engine-produced metrics are always non-negative). See
  /// `ConsensusResult.quorumDepth`.
  final int quorumDepth;

  /// The number of administrative groups represented in the quorum.
  final int groupCount;

  /// The qualitative grade of the synchronization result.
  final ConfidenceLevel confidence;

  /// A granular breakdown of confidence factors (e.g., depth, diversity, stability).
  final Map<String, double> confidenceBreakdown;
}
