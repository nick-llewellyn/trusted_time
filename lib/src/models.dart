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
  /// protocols (NTP, NTS) and extremely low population variance.
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
/// [ntsServers], [additionalSources]) are stored by
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
    this.ntpServers = const [
      'pool.ntp.org',
      'time.apple.com',
      'time.windows.com',
    ],
    this.ntsServers = const ['time.cloudflare.com', 'nts.netnod.se'],
    this.ntsPort = 4460,
    this.maxConcurrentDnsLookups,
    // ignore: deprecated_member_use_from_same_package
    this.ntsDnsConcurrencyCap,
    this.usePlatformTrust = false,
    this.customRootCerts = const [],
    this.additionalSources = const [],
    this.minQuorumRatio = 0.6,
    this.minimumQuorum = 2,
    this.minGroupCount = 2,
    this.maxLatency = const Duration(seconds: 4),
    this.refreshInterval = const Duration(hours: 48),
    this.maxAllowedUncertaintyMs = 5000,
    this.persistState = true,
    this.earlyExit = true,
    this.backgroundSyncInterval,
    this.transientStreakThreshold = 5,
    this.ntsBurstCount = 8,
    this.ntpBurstCount = 8,
    this.requireSleepAwareProjection = false,
  }) : assert(
         ntsBurstCount >= 1 && ntsBurstCount <= 8,
         'ntsBurstCount must be in 1..8: 8 matches the fixed burst size '
         'of package:nts\'s own one-call getTime and bounds the '
         'worst-case cookie drain of a total-loss burst to one full '
         '8-cookie jar (RFC 8915).',
       ),
       assert(
         ntpBurstCount >= 1 && ntpBurstCount <= 8,
         'ntpBurstCount must be in 1..8, matching the NTS burst cap so '
         'both source kinds share one worst-case wall-time model.',
       );

  /// Creates a mobile-tuned configuration implementing the 48h
  /// anchor-age policy.
  ///
  /// * [backgroundSyncInterval] is 24h — one background refresh
  ///   attempt per day, the cadence iOS `BGTaskScheduler` and Android
  ///   `WorkManager` will actually honour on battery-conscious
  ///   devices.
  /// * [refreshInterval] is 48h (the global default, named explicitly)
  ///   — the staleness bound for the foreground timer and the
  ///   on-resume anchor-age check. Twice the background cadence, so
  ///   the best-effort OS scheduler gets a full day of slack to land
  ///   the daily job before a foreground resume forces a sync.
  ///
  /// The policy is completed by the engine's on-resume anchor-age
  /// check (active in every mode, not just this one): returning to
  /// the foreground with an anchor older than [refreshInterval]
  /// triggers a full sync immediately rather than waiting for the
  /// next timer tick.
  factory TrustedTimeConfig.mobileDefaults() {
    return const TrustedTimeConfig(
      refreshInterval: Duration(hours: 48),
      backgroundSyncInterval: Duration(hours: 24),
    );
  }

  /// The list of authoritative NTP server hostnames used for synchronization.
  ///
  /// Every default host follows the leap-second **stepping** policy;
  /// smearing operators (Google, AWS) are deliberately excluded, since
  /// a smeared source diverges from stepping sources by up to a full
  /// second around a leap event and can poison the consensus.
  final List<String> ntpServers;

  /// The list of Network Time Security (NTS) servers used for cryptographically
  /// authenticated synchronization.
  ///
  /// The default pairs two anycast anchors from distinct operators
  /// (Cloudflare, Netnod), so the out-of-the-box config can satisfy
  /// [minGroupCount]'s two-distinct-groups requirement and mint a
  /// verified truth box on its own. Both operators step (not smear)
  /// leap seconds.
  final List<String> ntsServers;

  /// The TCP port used for the NTS Key Exchange (NTS-KE) handshake.
  /// Defaults to 4460 as per RFC 8915.
  final int ntsPort;

  /// SyncEngine-level ceiling on concurrent *uncached* DNS resolutions
  /// across all source kinds (ADR 0008).
  ///
  /// A single budget is shared by every source whose hostname resolution
  /// the engine can govern in-process; cache hits are free and never
  /// consume a slot. When `null` (the default), the effective budget is
  /// resolved by [effectiveMaxConcurrentDnsLookups]:
  /// [kDefaultMaxConcurrentDnsLookups] (`6`), or the deprecated
  /// [ntsDnsConcurrencyCap] during migration.
  ///
  /// Six sits between the carrier-conservative (4) and WiFi-optimistic
  /// (8) envelopes: it covers a typical NTS pool plus NTP headroom
  /// while staying inside the CGNAT serialisation threshold a cold-start
  /// burst tends to hit. See ADR 0008.
  final int? maxConcurrentDnsLookups;

  /// Per-call ceiling on `package:nts`'s process-wide bounded DNS
  /// resolver pool, forwarded to every `ntsQuery` and `ntsWarmCookies`
  /// the engine issues.
  ///
  /// When `null` (the default), [SyncEngine] sizes the NTS cap from the
  /// unified [effectiveMaxConcurrentDnsLookups] budget. Set this
  /// explicitly when the process hosts other concurrent `package:nts`
  /// callers (the pool is process-global, so every admitted worker
  /// counts toward every caller's threshold).
  @Deprecated(
    'Use maxConcurrentDnsLookups instead; it governs DNS concurrency '
    'across the engine-resolved NTP and NTS lookups rather than NTS alone '
    '(see ADR 0008). '
    'Honoured as the unified budget while maxConcurrentDnsLookups is '
    'unset; removal is deferred to the fork 2.x release.',
  )
  final int? ntsDnsConcurrencyCap;

  /// The unified DNS budget applied when neither [maxConcurrentDnsLookups]
  /// nor the deprecated [ntsDnsConcurrencyCap] is set (ADR 0008).
  static const int kDefaultMaxConcurrentDnsLookups = 6;

  /// The effective unified DNS budget after applying the ADR 0008
  /// migration ladder.
  ///
  /// An explicit [maxConcurrentDnsLookups] wins; otherwise a legacy
  /// [ntsDnsConcurrencyCap] is honoured; otherwise
  /// [kDefaultMaxConcurrentDnsLookups]. Emitting the one-time deprecation
  /// warning for the legacy branch is [SyncEngine]'s responsibility at
  /// the point of use.
  ///
  /// Throws [ArgumentError] if the resolved budget is not positive. The
  /// constructor is `const`, so a zero/negative cap cannot be rejected in
  /// the initializer list; this getter is the single enforcement point
  /// (mirroring [effectiveTrustMode]) so an invalid budget fails fast in
  /// both debug and release rather than reaching [DnsBudget] — where it
  /// would admit no lookups and stall every uncached resolution.
  int get effectiveMaxConcurrentDnsLookups {
    final resolved =
        maxConcurrentDnsLookups ??
        // ignore: deprecated_member_use_from_same_package
        ntsDnsConcurrencyCap ??
        kDefaultMaxConcurrentDnsLookups;
    if (resolved < 1) {
      throw ArgumentError.value(
        resolved,
        'maxConcurrentDnsLookups',
        'the DNS budget must be at least 1; a non-positive cap would '
            'admit no lookups and stall every uncached resolution',
      );
    }
    return resolved;
  }

  /// Whether to validate every NTS-KE handshake against the platform /
  /// OS trust store instead of the bundled `webpki-roots` static set.
  ///
  /// Defaults to `false` — the engine constructs every per-source
  /// [nts.NtsClient] in [nts.TrustMode.bundledOnly], so authenticity is
  /// end-to-end and a TLS-inspection appliance holding a platform- or
  /// MDM-installed inspection CA cannot complete a man-in-the-middle
  /// NTS-KE handshake this client would accept. This is the
  /// security-by-default posture: a consumer who never reasons about
  /// trust still gets a library-controlled anchor set rather than one
  /// the surrounding network can influence.
  ///
  /// Set to `true` only as the explicit "I have a pinned corporate CA
  /// or MDM-installed root and accept that authenticity is
  /// platform-mediated rather than end-to-end" opt-in. The engine then
  /// constructs each client in [nts.TrustMode.platformOnly], which
  /// refuses `package:nts`'s Android `webpki-roots` hybrid fallback
  /// (nts 4.0.0): a `platformOnly` caller never resolves to
  /// [nts.TrustBackend.platformWithHybridFallback], so the bundled set
  /// genuinely is not consulted on any platform — hence "instead of"
  /// above, not "in preference to".
  ///
  /// Under the Secure Time Contract, samples authenticated via the
  /// platform store report [NtsAuthLevel.none] rather than
  /// [NtsAuthLevel.verified], so a platform-mediated path is never
  /// misrepresented as cryptographically verified. `NtsSource` maps
  /// each handshake's reported [nts.TrustBackend] to its auth level:
  /// [nts.TrustBackend.webpkiRoots] and [nts.TrustBackend.custom]
  /// yield `verified`; [nts.TrustBackend.platform] (and the
  /// Android-only [nts.TrustBackend.platformWithHybridFallback]) yield
  /// `none` (design Section 3.2). Enabling this field therefore trades
  /// `verified` samples for platform-mediated `none` samples —
  /// [TrustedTime.getTime] with `requireSecure: true` will not be
  /// satisfiable by them.
  ///
  /// Mutually exclusive with a non-empty [customRootCerts]; the
  /// combination throws [ArgumentError]. See [effectiveTrustMode].
  final bool usePlatformTrust;

  /// PEM- or DER-encoded root certificates supplied by the consumer.
  ///
  /// When non-empty, the engine constructs every per-source
  /// [nts.NtsClient] in [nts.TrustMode.custom] with these bytes;
  /// neither the platform store nor the bundled `webpki-roots` set is
  /// consulted, and the engine never silently augments the custom
  /// anchors with either. Appropriate for on-premise or private-CA
  /// NTS-KE deployments where neither default anchor set contains the
  /// issuing root. Like the default bundled path, the anchor set is
  /// fully caller-controlled, so a TLS-inspection appliance without the
  /// matching private key cannot intercept the exchange.
  ///
  /// Empty (the default) selects the [usePlatformTrust] / bundled path.
  /// Mutually exclusive with `usePlatformTrust == true`; the
  /// combination throws [ArgumentError]. See [effectiveTrustMode].
  ///
  /// The mutability contract documented on the other list-typed fields
  /// applies verbatim: pass a `const` list literal or a list the caller
  /// does not subsequently mutate.
  final List<int> customRootCerts;

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
  /// while the app is in the foreground, and the staleness bound for the
  /// on-resume anchor-age check. Defaults to 48 hours.
  final Duration refreshInterval;

  /// The hard threshold for precision. If a consensus result has an uncertainty
  /// (width/2) exceeding this value, it is discarded.
  final int maxAllowedUncertaintyMs;

  /// Whether to persist the last verified [TrustAnchor] to secure storage.
  /// Allows for faster "warm-start" trust establishment on app restart.
  final bool persistState;

  /// Whether the engine must project time on a sleep-aware monotonic
  /// timeline, failing closed when only the suspend-frozen fallback is
  /// available.
  ///
  /// Projection between syncs rides the best available monotonic
  /// reader. When the `package:nts` bridge is initialized (any config
  /// with non-empty [ntsServers] whose FFI bootstrap succeeded), that
  /// is the sleep-aware `nts.MonotonicClock` — `CLOCK_BOOTTIME` /
  /// `mach_continuous_time` / `QueryInterruptTimePrecise` — which
  /// keeps counting through device suspend. Without the bridge
  /// (NTP-only configs, or after a genuine bridge init
  /// failure) the engine falls back to a Dart `Stopwatch`, which
  /// freezes during suspend: a device that sleeps between syncs then
  /// reports a projected time behind by the sleep duration until the
  /// next sync or integrity reconciliation.
  ///
  /// `false` (the default) accepts the fallback silently — matching
  /// pre-existing behaviour — and leaves the timeline observable via
  /// `TrustedTime.isProjectionSleepAware`. Set `true` when
  /// suspend-correct projection is a hard requirement:
  ///
  /// * `TrustedTime.initialize` throws [TrustedTimeSecurityException]
  ///   when no sleep-aware reader can be resolved at engine start
  ///   (including the case where a bridge init failure stripped
  ///   [ntsServers]), so misconfiguration fails fast rather than at
  ///   first read; and
  /// * `TrustedTime.now` throws [TrustedTimeSecurityException] if the
  ///   projection is ever anchored on a suspend-frozen timeline.
  ///
  /// This gate is about projection *between* syncs, not consensus
  /// quality — it is orthogonal to [ConfidenceLevel] and to
  /// `requireSecure` (which gates NTS authentication of the anchor
  /// itself).
  final bool requireSleepAwareProjection;

  /// If true, the engine will stop querying sources as soon as a stable quorum
  /// is reached, conserving network and battery resources.
  final bool earlyExit;

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
  /// Default: `5` — five consecutive sync cycles of sustained
  /// transients before escalation, long enough that a real DNS-pool
  /// burst clears naturally and short enough that a stuck host
  /// eventually surfaces as unhealthy.
  ///
  /// Set to `0` (or any non-positive value) to disable escalation
  /// entirely and preserve the pre-streak-guard behaviour where
  /// transient failures retry indefinitely.
  final int transientStreakThreshold;

  /// The maximum number of sequential authenticated queries each
  /// [NtsSource] issues per `getTime()` call — one call per sync
  /// cycle.
  ///
  /// Every query in the burst produces an independent measurement; the
  /// source reduces them to the single lowest-RTT sample — the
  /// burst-and-pick-min strategy `package:nts` documents — so a
  /// transient path delay on one query
  /// cannot widen the interval the consensus sees. The burst is
  /// sequential by design, mirroring `package:nts`'s own one-call
  /// `getTime`: concurrent samples fired at one server share any
  /// transient queue spike, defeating the lowest-delay selection,
  /// whereas sequential queries let the path drain between samples.
  /// The whole burst shares one [maxLatency] wall-clock budget as a
  /// shrinking deadline — when the budget depletes mid-burst the
  /// remaining attempts are skipped and the best sample gathered so
  /// far wins, so slow paths degrade to fewer samples rather than no
  /// result.
  ///
  /// Defaults to `8`; must be in `1..8` — the fixed burst size of
  /// `package:nts`'s one-call `getTime`, which also bounds the
  /// worst-case cookie drain: successful queries are cookie-neutral
  /// (each reply's in-band refill lands before the next query
  /// spends), but a failed attempt spends its cookie without a
  /// refill, so a total-loss burst of 8 empties the 8-cookie jar
  /// (RFC 8915) and forces a full NTS-KE re-handshake before the next
  /// attempt. `1` reproduces the pre-burst single-query behaviour
  /// exactly.
  final int ntsBurstCount;

  /// The number of sequential SNTP exchanges each NTP source issues
  /// per `getTime()` call during a sync cycle.
  ///
  /// The NTP mirror of [ntsBurstCount]: attempts run one-at-a-time
  /// against the same resolved server, sharing the [maxLatency]
  /// wall-clock budget as a shrinking deadline, and the successes are
  /// collapsed to the single sample with the smallest RFC 5905
  /// network delay δ — the tightest, least path-asymmetric estimate
  /// (the burst-and-pick-min strategy the NTS path uses). NTP has no
  /// cookie economics, so the `1..8` cap simply matches the NTS cap:
  /// one worst-case wall-time model for both source kinds.
  ///
  /// Defaults to `8`. `1` reproduces the pre-burst single-query
  /// behaviour exactly.
  final int ntpBurstCount;

  /// The [nts.TrustMode] the engine applies to every per-source
  /// [nts.NtsClient], derived from [usePlatformTrust] and
  /// [customRootCerts].
  ///
  /// | [usePlatformTrust] | [customRootCerts] | result |
  /// |---|---|---|
  /// | `false` (default) | empty (default) | [nts.TrustMode.bundledOnly] |
  /// | `false` | non-empty | [nts.TrustMode.custom] |
  /// | `true` | empty | [nts.TrustMode.platformOnly] |
  /// | `true` | non-empty | throws [ArgumentError] |
  ///
  /// `usePlatformTrust: true` together with a non-empty
  /// [customRootCerts] names two mutually exclusive trust sources with
  /// no defined precedence and throws [ArgumentError]. This getter is
  /// the single enforcement point: [SyncEngine] reads it while building
  /// its per-source `NtsSource` list — each `NtsSource` forwards the
  /// resolved mode to its own lazily-constructed [nts.NtsClient] — so an
  /// invalid config fails closed before any source is built and the
  /// combination cannot
  /// reach a live engine. (The `const` constructor cannot perform this
  /// check itself — list emptiness is not a const-evaluable
  /// expression.) See the Secure Time Contract, "Persona selection at
  /// construction time".
  nts.TrustMode get effectiveTrustMode {
    if (usePlatformTrust && customRootCerts.isNotEmpty) {
      throw ArgumentError(
        'usePlatformTrust and customRootCerts are mutually exclusive: '
        'set exactly one trust source (platform vs caller-supplied roots).',
      );
    }
    if (customRootCerts.isNotEmpty) return nts.TrustMode.custom;
    if (usePlatformTrust) return nts.TrustMode.platformOnly;
    return nts.TrustMode.bundledOnly;
  }

  /// Returns a new [TrustedTimeConfig] with the supplied fields replaced.
  ///
  /// Any field omitted (or passed as `null`) keeps its current value.
  /// [backgroundSyncInterval] cannot be cleared back to `null` through
  /// this method; construct a new instance directly if that is needed.
  TrustedTimeConfig copyWith({
    List<String>? ntpServers,
    List<String>? ntsServers,
    int? ntsPort,
    int? maxConcurrentDnsLookups,
    int? ntsDnsConcurrencyCap,
    bool? usePlatformTrust,
    List<int>? customRootCerts,
    List<TimeSource>? additionalSources,
    double? minQuorumRatio,
    int? minimumQuorum,
    int? minGroupCount,
    Duration? maxLatency,
    Duration? refreshInterval,
    int? maxAllowedUncertaintyMs,
    bool? persistState,
    bool? earlyExit,
    Duration? backgroundSyncInterval,
    int? transientStreakThreshold,
    int? ntsBurstCount,
    int? ntpBurstCount,
    bool? requireSleepAwareProjection,
  }) {
    return TrustedTimeConfig(
      ntpServers: ntpServers ?? this.ntpServers,
      ntsServers: ntsServers ?? this.ntsServers,
      ntsPort: ntsPort ?? this.ntsPort,
      maxConcurrentDnsLookups:
          maxConcurrentDnsLookups ?? this.maxConcurrentDnsLookups,
      // ignore: deprecated_member_use_from_same_package
      ntsDnsConcurrencyCap: ntsDnsConcurrencyCap ?? this.ntsDnsConcurrencyCap,
      usePlatformTrust: usePlatformTrust ?? this.usePlatformTrust,
      customRootCerts: customRootCerts ?? this.customRootCerts,
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
      backgroundSyncInterval:
          backgroundSyncInterval ?? this.backgroundSyncInterval,
      transientStreakThreshold:
          transientStreakThreshold ?? this.transientStreakThreshold,
      ntsBurstCount: ntsBurstCount ?? this.ntsBurstCount,
      ntpBurstCount: ntpBurstCount ?? this.ntpBurstCount,
      requireSleepAwareProjection:
          requireSleepAwareProjection ?? this.requireSleepAwareProjection,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrustedTimeConfig &&
        listEquals(other.ntpServers, ntpServers) &&
        listEquals(other.ntsServers, ntsServers) &&
        other.ntsPort == ntsPort &&
        other.maxConcurrentDnsLookups == maxConcurrentDnsLookups &&
        // ignore: deprecated_member_use_from_same_package
        other.ntsDnsConcurrencyCap == ntsDnsConcurrencyCap &&
        other.usePlatformTrust == usePlatformTrust &&
        listEquals(other.customRootCerts, customRootCerts) &&
        listEquals(other.additionalSources, additionalSources) &&
        other.minQuorumRatio == minQuorumRatio &&
        other.minimumQuorum == minimumQuorum &&
        other.minGroupCount == minGroupCount &&
        other.maxLatency == maxLatency &&
        other.refreshInterval == refreshInterval &&
        other.maxAllowedUncertaintyMs == maxAllowedUncertaintyMs &&
        other.persistState == persistState &&
        other.earlyExit == earlyExit &&
        other.backgroundSyncInterval == backgroundSyncInterval &&
        other.transientStreakThreshold == transientStreakThreshold &&
        other.ntsBurstCount == ntsBurstCount &&
        other.ntpBurstCount == ntpBurstCount &&
        other.requireSleepAwareProjection == requireSleepAwareProjection;
  }

  @override
  int get hashCode => Object.hashAll([
    Object.hashAll(ntpServers),
    Object.hashAll(ntsServers),
    ntsPort,
    maxConcurrentDnsLookups,
    // ignore: deprecated_member_use_from_same_package
    ntsDnsConcurrencyCap,
    usePlatformTrust,
    Object.hashAll(customRootCerts),
    Object.hashAll(additionalSources),
    minQuorumRatio,
    minimumQuorum,
    minGroupCount,
    maxLatency,
    refreshInterval,
    maxAllowedUncertaintyMs,
    persistState,
    earlyExit,
    backgroundSyncInterval,
    transientStreakThreshold,
    ntsBurstCount,
    ntpBurstCount,
    requireSleepAwareProjection,
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
        '  ntsServers: $ntsServers,\n'
        '  ntsPort: $ntsPort,\n'
        '  maxConcurrentDnsLookups: $maxConcurrentDnsLookups,\n'
        // ignore: deprecated_member_use_from_same_package
        '  ntsDnsConcurrencyCap: $ntsDnsConcurrencyCap,\n'
        '  usePlatformTrust: $usePlatformTrust,\n'
        // Summarise rather than interpolate the raw bytes: dumping the
        // list verbatim would leak consumer CA material into logs and
        // produce a single line megabytes long for a PEM bundle. The
        // byte count is enough to confirm whether custom roots are
        // configured during a benchmarking session.
        '  customRootCerts: ${customRootCerts.length} bytes,\n'
        '  additionalSources: $additionalSources,\n'
        '  minQuorumRatio: $minQuorumRatio,\n'
        '  minimumQuorum: $minimumQuorum,\n'
        '  minGroupCount: $minGroupCount,\n'
        '  maxLatency: $maxLatency,\n'
        '  refreshInterval: $refreshInterval,\n'
        '  maxAllowedUncertaintyMs: $maxAllowedUncertaintyMs,\n'
        '  persistState: $persistState,\n'
        '  earlyExit: $earlyExit,\n'
        '  backgroundSyncInterval: $backgroundSyncInterval,\n'
        '  transientStreakThreshold: $transientStreakThreshold,\n'
        '  ntsBurstCount: $ntsBurstCount,\n'
        '  ntpBurstCount: $ntpBurstCount,\n'
        '  requireSleepAwareProjection: $requireSleepAwareProjection,\n'
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
    this.bootId,
    this.contributors = const [],
  });

  /// Deserializes a [TrustAnchor] from a JSON map with rigorous bounds checking.
  factory TrustAnchor.fromJson(Map<String, dynamic> json) {
    try {
      final confIdx = json['confidence'] as int? ?? 0;

      // CRITICAL-6: Prevent RangeError or malformed state during deserialization.
      //
      // authLevel is serialized by name (current format), a self-describing
      // encoding that survives enum changes: a verified anchor round-trips back
      // to verified rather than colliding with a legacy ordinal. Legacy v2.0.x
      // persisted it as a 3-variant ordinal (none=0, advisory=1, verified=2);
      // those int values are still decoded, with the removed advisory (1)
      // degrading to none so stale anchors never misidentify as verified.
      final rawAuth = json['authLevel'];
      final NtsAuthLevel authLevel;
      if (rawAuth is String) {
        authLevel = NtsAuthLevel.values.firstWhere(
          (v) => v.name == rawAuth,
          orElse: () => NtsAuthLevel.none,
        );
      } else if (rawAuth is int) {
        final remappedAuthIdx = rawAuth == 2 ? 1 : (rawAuth == 1 ? 0 : rawAuth);
        authLevel =
            (remappedAuthIdx >= 0 &&
                remappedAuthIdx < NtsAuthLevel.values.length)
            ? NtsAuthLevel.values[remappedAuthIdx]
            : NtsAuthLevel.none;
      } else {
        authLevel = NtsAuthLevel.none;
      }

      final confidence =
          (confIdx >= 0 && confIdx < ConfidenceLevel.values.length)
          ? ConfidenceLevel.values[confIdx]
          : ConfidenceLevel.none;

      // Contributor telemetry is diagnostic, never trust-critical: a
      // missing key (anchors persisted before the field existed) or a
      // malformed entry degrades to fewer/no contributors rather than
      // failing the whole anchor, which would discard a valid trust
      // reference over cosmetic metadata.
      final rawContributors = json['contributors'];
      var contributors = const <TrustAnchorContributor>[];
      if (rawContributors is List) {
        contributors = [
          for (final entry in rawContributors)
            if (entry is Map<String, dynamic>)
              ?TrustAnchorContributor.tryFromJson(entry),
        ];
      }

      return TrustAnchor(
        networkUtcMs: json['networkUtcMs'] as int,
        uptimeMs: json['uptimeMs'] as int,
        wallMs: json['wallMs'] as int,
        uncertaintyMs: json['uncertaintyMs'] as int,
        authLevel: authLevel,
        confidence: confidence,
        bootId: json['bootId'] as String?,
        contributors: contributors,
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

  /// Opaque identifier of the boot session this anchor was captured in,
  /// or `null` when the platform provides none.
  ///
  /// On warm restore the anchor is only honoured when this matches the
  /// device's current boot ID — identity comparison, not the uptime
  /// inequality, is what defeats the wait-out attack (reboot, then leave
  /// the device on until uptime exceeds the recorded value). Anchors
  /// without a boot ID fail closed: they are treated as rebooted.
  final String? bootId;

  /// Per-source telemetry for every sample that entered the consensus
  /// this anchor was minted from — winners and losers alike.
  ///
  /// Purely diagnostic: nothing in the trust chain reads it. It exists
  /// so an anchor documents *who* produced it (which servers, at what
  /// RTT/jitter/stratum, and whether each one's interval made the
  /// winning set), feeding source-quality refinement and the example
  /// app's telemetry views. Empty for anchors persisted before the
  /// field existed and for synthetic anchors (e.g. the background-sync
  /// probe path).
  final List<TrustAnchorContributor> contributors;

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
    'authLevel': authLevel.name,
    'confidence': confidence.index,
    if (bootId != null) 'bootId': bootId,
    if (contributors.isNotEmpty)
      'contributors': [for (final c in contributors) c.toJson()],
  };
}

@immutable
/// One time source's performance in the sync cycle that minted a
/// [TrustAnchor] — the per-server line item behind the anchor's
/// consensus.
///
/// Recorded for every sample that reached the consensus engine, not
/// just the winning set: a source whose interval was excluded from the
/// intersection ([wonConsensus] false) is exactly the signal
/// source-quality refinement needs. Purely diagnostic — nothing in the
/// trust chain reads these fields.
final class TrustAnchorContributor {
  /// Creates a contributor record from one cycle's telemetry.
  const TrustAnchorContributor({
    required this.sourceId,
    required this.groupId,
    required this.rttMs,
    required this.dispersionMs,
    required this.authLevel,
    required this.wonConsensus,
    this.stratum,
    this.jitterMs,
  });

  /// Deserializes a contributor, or returns null when required fields
  /// are missing or mistyped.
  ///
  /// Null rather than throw: contributor telemetry is diagnostic, so a
  /// corrupt entry must cost only itself, never the anchor it rides in
  /// (see [TrustAnchor.fromJson]).
  static TrustAnchorContributor? tryFromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId'];
    final groupId = json['groupId'];
    final rttMs = json['rttMs'];
    final dispersionMs = json['dispersionMs'];
    final wonConsensus = json['wonConsensus'];
    final stratum = json['stratum'];
    final jitterMs = json['jitterMs'];
    if (sourceId is! String ||
        groupId is! String ||
        rttMs is! int ||
        dispersionMs is! int ||
        wonConsensus is! bool ||
        stratum is! int? ||
        jitterMs is! int?) {
      return null;
    }
    // authLevel shares TrustAnchor's by-name encoding; an unknown name
    // degrades to none, matching the anchor-level policy.
    final rawAuth = json['authLevel'];
    final authLevel = rawAuth is String
        ? NtsAuthLevel.values.firstWhere(
            (v) => v.name == rawAuth,
            orElse: () => NtsAuthLevel.none,
          )
        : NtsAuthLevel.none;
    return TrustAnchorContributor(
      sourceId: sourceId,
      groupId: groupId,
      rttMs: rttMs,
      dispersionMs: dispersionMs,
      authLevel: authLevel,
      wonConsensus: wonConsensus,
      stratum: stratum,
      jitterMs: jitterMs,
    );
  }

  /// Stable source identifier (e.g. `ntp:pool.ntp.org`,
  /// `nts:time.cloudflare.com`).
  final String sourceId;

  /// Administrative group of the source in this cycle — ASN-derived
  /// for NTP, registrable domain for NTS (see ADR 0007).
  final String groupId;

  /// Network delay δ of the winning burst attempt, in milliseconds —
  /// peer delay when the clock-filter fields were available, else the
  /// whole round trip (the same value as [TimeSample.delayMs]).
  final int rttMs;

  /// Server-side error budget E = rootDelay/2 + rootDispersion, in
  /// milliseconds (the same value as [TimeSample.dispersionMs]).
  final int dispersionMs;

  /// Authentication level of the sample this source contributed.
  final NtsAuthLevel authLevel;

  /// Whether this source's interval was part of the winning
  /// intersection the anchor's UTC was derived from. False means the
  /// source answered but its interval fell outside the consensus.
  final bool wonConsensus;

  /// NTP stratum the server reported (1–15), or null when the source
  /// surfaces none.
  final int? stratum;

  /// In-cycle burst jitter (max − min network delay across the burst's
  /// successful attempts), in milliseconds; null when the burst had
  /// fewer than two successes or the source has no burst concept.
  final int? jitterMs;

  /// Serializes this contributor for storage inside
  /// [TrustAnchor.toJson].
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'groupId': groupId,
    'rttMs': rttMs,
    'dispersionMs': dispersionMs,
    'authLevel': authLevel.name,
    'wonConsensus': wonConsensus,
    if (stratum != null) 'stratum': stratum,
    if (jitterMs != null) 'jitterMs': jitterMs,
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
