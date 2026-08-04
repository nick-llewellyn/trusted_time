import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;

import '../data/ntp_inventory.dart';
import '../data/nts_inventory.dart';
import '../domain/time_source.dart';
import 'ntp_server_info.dart';
import 'nts_server_info.dart';

@immutable
/// Configuration parameters for the [TrustedTime] engine.
///
/// This class defines the behavioral policy of the engine, including quorum
/// requirements, security thresholds, and background synchronization intervals.
///
/// ## Mutability contract
///
/// [TrustedTimeConfig] is annotated `@immutable` and its scalar
/// fields are `final`. The list-typed fields ([additionalSources],
/// [customRootCerts]) are stored by
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
    this.disableNts = false,
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
    this.ntsQueryTarget = 5,
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
    @visibleForTesting this.disableNtpForTesting = false,
    @visibleForTesting this.ntpInventoryForTesting,
    @visibleForTesting this.ntsInventoryForTesting,
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
       ),
       assert(
         ntsQueryTarget >= minNtsQueryTarget,
         'ntsQueryTarget must be at least minNtsQueryTarget '
         '($minNtsQueryTarget): a cycle that asks fewer NTS hosts than '
         'the truth box needs responding can never form one. Rejected '
         'rather than clamped so the misconfiguration surfaces. Setting '
         'it to exactly the floor is legal and leaves zero failure '
         'headroom.',
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

  /// Suppresses every plain-NTP source, leaving [ntsServers] and
  /// [additionalSources] as the only inputs.
  ///
  /// The NTS counterpart is [disableNts], which differs in being a
  /// supported production posture rather than a test seam.
  ///
  /// Exists so the test suite (and the example app's NTS-only
  /// benchmarking harness) can keep [ntpServers] from doing live DNS
  /// and UDP. It is not a supported production knob: an install that
  /// disables NTP loses the unauthenticated breadth the consensus
  /// relies on.
  @visibleForTesting
  final bool disableNtpForTesting;

  /// The authoritative NTP server hostnames used for synchronization.
  ///
  /// Fixed to the library's curated inventory — see
  /// `lib/src/data/ntp_inventory.dart` for provenance, the
  /// leap-second policy, and the anycast vantage caveat. No host is a
  /// documented smearing operator: Google, AWS, and Meta are excluded
  /// on published-smear evidence, since a smeared source diverges
  /// from stepping sources by up to a full second around a leap event
  /// and can poison the consensus. Stepping is documented for the
  /// major operators and metrology institutes and presumed for the
  /// remaining public servers, which run stock `ntpd`/`chrony`.
  ///
  /// Empty when [disableNtpForTesting] is set, or when
  /// [ntpInventoryForTesting] replaces the inventory these names are
  /// the view of.
  ///
  /// This is the hostname view; [ntpInventory] carries each host's
  /// tier, observed stratum and autonomous system, and leap-second
  /// evidence.
  List<String> get ntpServers =>
      disableNtpForTesting || ntpInventoryForTesting != null
      ? const []
      : curatedNtpHostnames;

  /// The curated inventory behind [ntpServers], with per-host metadata.
  ///
  /// Empty when [disableNtpForTesting] is set and no
  /// [ntpInventoryForTesting] override is supplied: the override wins
  /// over the flag, so a test can disable the live hosts and still give
  /// the partition a shape to narrow. Both are test seams, so neither
  /// carries a guarantee the other can violate.
  ///
  /// [ntsInventory] resolves the opposite way — there the flag wins,
  /// because [disableNts] is a production posture that `ensureNtsRuntime`
  /// writes on a genuine FFI failure, and no substitute inventory makes a
  /// missing runtime work. The two getters differ because the precedence
  /// question is not the same question on both sides, not because one has
  /// drifted.
  List<NtpServerInfo> get ntpInventory =>
      ntpInventoryForTesting ??
      (disableNtpForTesting ? const [] : curatedNtpInventory);

  /// Replaces the inventory the per-cycle partition reads, without
  /// building any source for it.
  ///
  /// The partition is the one piece of engine behaviour that depends on
  /// inventory *shape* — tier mix and host count — rather than on the
  /// samples sources return. Exercising it offline therefore needs an
  /// inventory the test controls, which [disableNtpForTesting] alone
  /// cannot give: that flag empties the inventory, collapsing the
  /// partition to its "nothing to narrow" branch where the cycle set is
  /// the whole source pool. Assertions about narrowing then hold
  /// vacuously.
  ///
  /// Setting this empties [ntpServers], so no [NtpSource] is built for
  /// a hostname the partition no longer knows about. Without that, the
  /// curated 51 would still be queried live while eligibility keyed off
  /// the override — real DNS and UDP from a test, against sources the
  /// narrowing then lets through unpartitioned. A test supplies its own
  /// fakes through [additionalSources] under `ntp:`-prefixed ids
  /// matching these hosts; the partition narrows those with no network.
  ///
  /// [ntsInventoryForTesting] deliberately does not suppress in the same
  /// way. Keeping the network out of a unit test is solved differently on
  /// each side: an uninitialised [NtsSource] throws on its own, so the NTS
  /// seam can leave sources built and still stay offline, which the
  /// bootstrap-gate regressions require. An [NtpSource] has no equivalent
  /// self-limiting failure — it would resolve and send — so suppression
  /// has to happen here.
  ///
  /// Not a production knob: the inventory's provenance and leap-second
  /// vetting are what make the curated list safe to query, and an
  /// arbitrary substitute carries neither.
  @visibleForTesting
  final List<NtpServerInfo>? ntpInventoryForTesting;

  /// Suppresses every NTS source, leaving [ntpServers] and
  /// [additionalSources] as the only inputs.
  ///
  /// Unlike [disableNtpForTesting], this is a supported production
  /// posture. NTS-KE runs over TCP/4460, which some corporate and
  /// captive networks block outright; on such a network every handshake
  /// in the inventory costs a connect timeout before failing, so an
  /// install that knows NTS cannot succeed is better off not attempting
  /// it. The cost is real: without NTS the engine has no
  /// cryptographically authenticated source, so the anchor cannot be
  /// [ConfidenceLevel.secure] and projection falls back to a
  /// suspend-frozen `Stopwatch` timeline.
  ///
  /// Also set by the library itself. [TrustedTime.initialize] and
  /// `runBackgroundSync` route through `ensureNtsRuntime`, which
  /// degrades to a disabled copy when the `package:nts` FFI bootstrap
  /// genuinely fails — a missing native asset or an architecture
  /// mismatch — so the rest of the run does not open handshakes that
  /// cannot complete.
  final bool disableNts;

  /// The Network Time Security (NTS) hostnames used for
  /// cryptographically authenticated synchronization.
  ///
  /// Fixed to the library's curated inventory — see
  /// `lib/src/data/nts_inventory.dart` for provenance, the
  /// leap-second policy, and the coverage caveat. Every host completed
  /// a full live NTS-KE and AEAD-NTPv4 exchange before admission, and
  /// none is a documented smearing operator.
  ///
  /// Empty when [disableNts] is set.
  ///
  /// This is the hostname view of [ntsInventory], which carries each
  /// host's tier, observed stratum, and leap-second evidence — including
  /// when [ntsInventoryForTesting] substitutes the entries.
  ///
  /// Unmodifiable, like [ntpServers].
  List<String> get ntsServers {
    final inventory = ntsInventory;
    // The curated case is the only one production reaches, and its
    // hostname view is precomputed. Identity holds because [ntsInventory]
    // hands back the const inventory itself when nothing displaces it.
    // Reading the precedence off that getter rather than re-deriving it
    // here keeps the disable-flag-wins rule stated in exactly one place.
    if (identical(inventory, curatedNtsInventory)) return curatedNtsHostnames;
    if (inventory.isEmpty) return const [];
    return List.unmodifiable([for (final entry in inventory) entry.host]);
  }

  /// The curated inventory behind [ntsServers], with per-host metadata.
  ///
  /// Empty when [disableNts] is set, which overrides
  /// [ntsInventoryForTesting]: the flag is what `ensureNtsRuntime`
  /// writes when the FFI bootstrap fails, and a substitute inventory
  /// cannot make a missing runtime work.
  ///
  /// [ntpInventory] resolves the other way round, letting its override
  /// win over [disableNtpForTesting]. That pair is two test seams, where
  /// precedence is a convenience; this pair crosses the production
  /// boundary, where it is a guarantee — so the production flag has to be
  /// the final word.
  List<NtsServerInfo> get ntsInventory =>
      disableNts ? const [] : (ntsInventoryForTesting ?? curatedNtsInventory);

  /// Replaces the inventory the NTS sources and the per-cycle partition
  /// read, without reaching the curated hosts.
  ///
  /// The NTS counterpart of [ntpInventoryForTesting], and it exists for
  /// the same reason: the curated inventory is fixed, so a test that
  /// needs the partition to have a particular shape supplies its own
  /// entries here. Ignored when [disableNts] is set.
  ///
  /// Unlike the NTP seam this does *not* suppress source construction:
  /// an [NtsSource] is built per entry, which is what the bootstrap-gate
  /// regressions (trusted_time-y81) need — they assert on whether
  /// `ensureNtsRuntime` ran, which is gated on [ntsServers] being
  /// non-empty. Those sources throw "not initialised" per-source without
  /// aborting the cycle, so no network is touched from a unit test.
  /// Suppressing here would leave that gate untested; not suppressing on
  /// the NTP side would put live DNS and UDP in a unit test. Neither side
  /// is free to adopt the other's behaviour.
  ///
  /// Not a production knob: the inventory's provenance and leap-second
  /// vetting are what make the curated list safe to query, and an
  /// arbitrary substitute carries neither.
  @visibleForTesting
  final List<NtsServerInfo>? ntsInventoryForTesting;

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

  /// The smallest legal [ntsQueryTarget]: the truth box's validity floor.
  ///
  /// Three is the first population size at which the box survives one
  /// bad host — at a [minQuorumRatio] of 0.6 a 3-sample population needs
  /// an overlap of 2, so an outlier can be shed and a box still forms.
  /// At 2 the required overlap is also 2, meaning both must agree, which
  /// detects a liar rather than outvoting one. A target below this can
  /// never produce a truth box even with every host responding, which is
  /// why it is rejected rather than clamped.
  ///
  /// Distinct from [minimumQuorum], which floors the merged single-tier
  /// reduction and stays at 2; this floor is specific to the pass over
  /// the verified subset. See ADR 0007's 2026-08-02 postscript.
  static const minNtsQueryTarget = 3;

  /// How many NTS hosts a cycle asks for time, gating the truth box.
  ///
  /// The tier's size is a per-cycle property, not an inventory property:
  /// the engine narrows the curated inventory to this many blocking
  /// hosts each cycle rather than querying all of them. The three
  /// [TimeServerTier.anycast] hosts are members by identity every cycle
  /// and the remainder is promoted from the unicast ranking; the rest of
  /// the inventory is walked as non-blocking explorers.
  ///
  /// This is the number of hosts *asked*, which is deliberately above
  /// the [minNtsQueryTarget] number that must *respond*. The difference
  /// is the cycle's failure headroom — at the default of 5 two hosts can
  /// fail and the box still forms. Setting this to [minNtsQueryTarget]
  /// is legal and means a single timeout degrades the cycle to
  /// [NtsAuthLevel.none]; installs on a metered or battery-critical
  /// profile may still prefer it, since each host costs an NTS-KE
  /// handshake (TCP + TLS + key exchange).
  ///
  /// Values below [minNtsQueryTarget] are rejected by the constructor's
  /// assert rather than clamped: a target under the floor is a
  /// configuration that can never produce a truth box, so silently
  /// raising it would hide the mistake. No upper bound beyond the
  /// inventory itself — a target exceeding the promotable population
  /// simply yields a smaller quorum, the same as one whose promotions
  /// have not been ranked yet.
  final int ntsQueryTarget;

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
    bool? disableNts,
    int? ntsPort,
    int? maxConcurrentDnsLookups,
    int? ntsDnsConcurrencyCap,
    bool? usePlatformTrust,
    List<int>? customRootCerts,
    List<TimeSource>? additionalSources,
    double? minQuorumRatio,
    int? minimumQuorum,
    int? minGroupCount,
    int? ntsQueryTarget,
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
    @visibleForTesting bool? disableNtpForTesting,
    @visibleForTesting List<NtpServerInfo>? ntpInventoryForTesting,
    @visibleForTesting List<NtsServerInfo>? ntsInventoryForTesting,
  }) {
    return TrustedTimeConfig(
      disableNts: disableNts ?? this.disableNts,
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
      ntsQueryTarget: ntsQueryTarget ?? this.ntsQueryTarget,
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
      disableNtpForTesting: disableNtpForTesting ?? this.disableNtpForTesting,
      ntpInventoryForTesting:
          ntpInventoryForTesting ?? this.ntpInventoryForTesting,
      ntsInventoryForTesting:
          ntsInventoryForTesting ?? this.ntsInventoryForTesting,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrustedTimeConfig &&
        other.disableNtpForTesting == disableNtpForTesting &&
        listEquals(other.ntpInventoryForTesting, ntpInventoryForTesting) &&
        other.disableNts == disableNts &&
        listEquals(other.ntsInventoryForTesting, ntsInventoryForTesting) &&
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
        other.ntsQueryTarget == ntsQueryTarget &&
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
    disableNtpForTesting,
    // Nullable, and Object.hashAll rejects a null element, so the
    // absent case has to hash as something. A presence bit carries
    // "no override" on its own, leaving the second entry free to be
    // any placeholder when absent rather than one assumed unreachable
    // by a real inventory.
    ntpInventoryForTesting != null,
    ntpInventoryForTesting == null
        ? 0
        : Object.hashAll(ntpInventoryForTesting!),
    disableNts,
    ntsInventoryForTesting != null,
    ntsInventoryForTesting == null
        ? 0
        : Object.hashAll(ntsInventoryForTesting!),
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
    ntsQueryTarget,
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
        // Summarise rather than interpolate: the curated inventories are
        // fixed and dozens of entries long, so dumping them verbatim
        // would bury every other field. The count is what an operator
        // needs — paired with the two disable flags, since a zero on
        // either pool has more than one cause (the flag, or a seam
        // supplying an empty inventory) and the count alone cannot
        // tell them apart.
        '  ntpServers: ${ntpServers.length} hosts,\n'
        '  disableNtpForTesting: $disableNtpForTesting,\n'
        '  ntsServers: ${ntsServers.length} hosts,\n'
        '  disableNts: $disableNts,\n'
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
        '  ntsQueryTarget: $ntsQueryTarget,\n'
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
