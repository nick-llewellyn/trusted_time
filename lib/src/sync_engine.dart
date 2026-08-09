import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:nts/nts.dart' as nts;
import 'domain/explorer_shuffle.dart';
import 'domain/inventory_partition.dart';
import 'domain/marzullo_engine.dart';
import 'domain/time_sample.dart';
import 'domain/time_source.dart';
import 'domain/time_interval.dart';
import 'domain/vantage_baseline.dart';
import 'exceptions.dart' show TransientSourceError, TrustedTimeSyncException;
import 'models.dart';
import 'monotonic_clock.dart';
import 'source_quality_tracker.dart';
import 'sources/nts_auth_level.dart';
import 'sources/time_sources.dart';
import 'infra/dns_budget.dart';
import 'infra/sync_observer.dart';
import 'infra/consensus_cache.dart';
import 'infra/trusted_time_log.dart';

/// ## Absolute Top Tier: Distributed Lifecycle Orchestration
///
/// The [SyncEngine] is the heart of the time integrity subsystem. It implements
/// a self-healing operational state machine designed for adversarial robustness.
///
/// Key Refinements:
/// 1. **Racing Parallelism**: Minimizes cold-start latency through concurrent
///    multi-source querying.
/// 2. **Adaptive Stability Escalation**: Dynamically adjusts quorum requirements
///    based on population variance.
/// 3. **Mathematical Outlier Filtering**: Uses median-based guards to neutralize
///    malicious or jittery time authorities.
final class SyncEngine {
  /// Upper bound on any await of [Warmable.warm].
  ///
  /// warm() futures are memoized and not cancellable, so a timed-out
  /// await abandons the wait without aborting the handshake — the same
  /// future is re-joined by getTime()'s JIT warm, where the per-query
  /// maxLatency bound applies. Used by [sync]'s global warming barrier
  /// and the bootstrap's eager [warmAllSources] call, so a hung
  /// handshake can never stall a cycle (or a headless OS budget, or
  /// initialize()) beyond this cap.
  static const warmBarrierCap = Duration(seconds: 10);

  /// Documented.
  ///
  /// [explorerShuffle] orders this install's walk over the unicast
  /// inventory; see [explorerBudget]. Callers that can persist a seed
  /// (the foreground bootstrap and the background runner) pass the
  /// stored one so the walk survives process death. Omitting it mints a
  /// throwaway shuffle, which keeps direct construction — chiefly in
  /// tests — working, at the cost of restarting the walk each time.
  ///
  /// [explorerBudget] defaults to [defaultExplorerBudgetFor] applied to
  /// [defaultTargetPlatform]; [ntsExplorerBudget] to
  /// [defaultNtsExplorerBudgetFor] on the same platform. The two are
  /// separate because an NTS probe costs a TLS handshake an NTP probe
  /// does not — one shuffle orders both walks, but neither budget is
  /// derivable from the other.
  ///
  /// Both are clamped at zero, which [partitionInventory] reads as a
  /// quorum-only cycle. Negative is meaningless rather than erroneous —
  /// there is no width below "query the fixed members and stop" — so it
  /// degrades to that instead of throwing from inside selection, where
  /// a cycle that could have run on its quorum would fail entirely.
  SyncEngine({
    required TrustedTimeConfig config,
    required MonotonicClock clock,
    SyncObserver? observer,
    ConsensusCache? cache,
    SourceQualityTracker? qualityTracker,
    ExplorerShuffle? explorerShuffle,
    int? explorerBudget,
    int? ntsExplorerBudget,
  }) : _config = config,
       _clock = clock,
       _observer = observer,
       _cache = cache,
       _qualityTracker = qualityTracker ?? SourceQualityTracker(),
       _explorerShuffle = explorerShuffle ?? ExplorerShuffle.generate(),
       _explorerBudget = max(
         0,
         explorerBudget ?? defaultExplorerBudgetFor(defaultTargetPlatform),
       ),
       _ntsExplorerBudget = max(
         0,
         ntsExplorerBudget ??
             defaultNtsExplorerBudgetFor(defaultTargetPlatform),
       ),
       _engine = MarzulloEngine(
         minQuorumRatio: config.minQuorumRatio,
         maxAllowedUncertaintyMs: config.maxAllowedUncertaintyMs,
         minGroupCount: config.minGroupCount,
         minVerifiedQuorum: TrustedTimeConfig.minNtsQueryTarget,
       );

  /// Unicast hosts probed per cycle on iOS.
  ///
  /// A cycle always queries the 10-host anycast quorum first, so this is
  /// the *additional* width on top of it, not the total. iOS grants a
  /// `BGAppRefreshTask` roughly 30 s and hard-kills at expiry (ADR
  /// 0002); three explorers is what fits alongside the quorum with
  /// margin for the engine's warming barrier and per-query latency
  /// bound.
  static const iosExplorerBudget = 3;

  /// Unicast hosts probed per cycle everywhere else.
  ///
  /// Android's ~9-minute worker budget leaves room for a wider walk, so
  /// the whole 41-host explorer pool is covered in fewer cycles.
  static const standardExplorerBudget = 8;

  /// Unicast hosts probed per *foreground* cycle while the front-load is
  /// live.
  ///
  /// Deliberately equal to [standardExplorerBudget] rather than wider.
  /// The platform split exists because iOS hard-kills a
  /// `BGAppRefreshTask` at ~30 s (ADR 0002); a foreground cycle has no
  /// such deadline, so the narrow iOS budget has no reason to apply
  /// there. Holding the boost at the standard width keeps every
  /// individual cycle indistinguishable from some platform's steady
  /// state — only the aggregate rate over an install's first few days
  /// differs, and there is no single distinctive event of the kind the
  /// removed bootstrap sweep produced. A wider value would buy faster
  /// convergence at the cost of a cycle shape nothing else emits.
  ///
  /// The corollary is that the boost is a no-op wherever the steady
  /// budget is already [standardExplorerBudget]; it exists for iOS,
  /// which is where the convergence gap is (~14 cycles to sweep the
  /// explorer pool at 3/cycle, against ~5 at 8/cycle).
  static const boostedExplorerBudget = standardExplorerBudget;

  /// Per-query bound on an explorer probe.
  ///
  /// Much shorter than [TrustedTimeConfig.maxLatency], which sizes the
  /// window a source gets to *build the anchor* and so must tolerate a
  /// slow-but-usable path. An explorer is being measured, not relied
  /// on, and a host that cannot answer in two seconds is one the
  /// ranking should defer regardless — so the timeout doubles as the
  /// bound on how far an explorer's tail can outlive the cycle that
  /// launched it.
  static const explorerTimeout = Duration(seconds: 2);

  /// How many foreground cycles a freshly armed front-load covers.
  ///
  /// Eight boosted cycles at [boostedExplorerBudget] is ~1.6 sweeps of
  /// the 41-host explorer pool, which puts most hosts one probe past
  /// their first — enough for the EWMA to have something to smooth
  /// against rather than a single unsmoothed sample.
  static const explorerBoostCycles = 8;

  /// The default explorer budget for [platform].
  ///
  /// Exposed for tests pinning the platform split; production callers
  /// let the [SyncEngine] constructor resolve it from
  /// [defaultTargetPlatform].
  ///
  /// The split is two-way rather than three-way on purpose. iOS is the
  /// only platform whose OS kills the run at a deadline, and the budget
  /// exists to fit under that deadline; desktop and host-run tests have
  /// no deadline to fit under, so they take the standard width for the
  /// same reason Android does. Giving unconstrained hosts a *third*,
  /// wider value would mean sending more traffic to public NTP servers
  /// purely because nothing was stopping us, which is not a reason.
  @visibleForTesting
  static int defaultExplorerBudgetFor(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? iosExplorerBudget
      : standardExplorerBudget;

  /// NTS hosts probed per cycle on iOS, beyond the query target.
  ///
  /// Half [iosExplorerBudget], because an NTS probe is a TCP connect
  /// plus a TLS handshake plus a key exchange where an NTP probe is one
  /// UDP round trip. At roughly three times the cost, an equal budget
  /// would triple the cycle; halving puts the NTS explorer load in the
  /// same band as the query target itself. ADR 0007's postscript rules
  /// out sharing the NTP budget for exactly this reason.
  static const iosNtsExplorerBudget = 2;

  /// NTS hosts probed per cycle everywhere else, beyond the query target.
  ///
  /// Half [standardExplorerBudget], on the same cost argument as
  /// [iosNtsExplorerBudget].
  static const standardNtsExplorerBudget = 4;

  /// The default NTS explorer budget for [platform].
  ///
  /// Two-way on the same reasoning as [defaultExplorerBudgetFor]: iOS is
  /// the only platform whose OS kills the run at a deadline (ADR 0002),
  /// and the budget exists to fit under it.
  ///
  /// ## Sweep latency
  ///
  /// The curated inventory's 54 unicast NTS hosts are covered in 27
  /// cycles at the iOS budget and 14 at the standard one. At the 24 h
  /// establish cadence (ADR 0006) that is roughly 27 and 14 days — both
  /// slower than the NTP walk's ~14 and ~5, since the NTS pool is larger
  /// *and* its budget narrower. The cost is how long promotion runs on a
  /// partly-measured ranking, not correctness: the fixed anycast members
  /// are queried every cycle regardless of where the walk is.
  ///
  /// [armExplorerBoost] widens this walk alongside the NTP one, and it
  /// matters more here. NTP's quorum is whole on cycle 1 (10 fixed
  /// members against a floor of 2), so its ranking is a refinement,
  /// whereas the NTS tier pins 3 fixed members against a floor of 3 and
  /// promotion supplies the entire failure headroom — until the tracker
  /// has rank, every cycle runs the cold-start fill at zero headroom.
  /// Boosting iOS from 2 to 4 halves the time to rank-backed promotion.
  /// At [explorerBoostCycles] that covers ~32 of the 54 hosts, ~0.6 of a
  /// sweep against the NTP walk's ~1.6; the boost is deliberately not
  /// widened to close that gap, since the smoothing argument behind
  /// eight cycles is about promoted hosts having *a* measurement rather
  /// than about covering the pool.
  @visibleForTesting
  static int defaultNtsExplorerBudgetFor(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? iosNtsExplorerBudget
      : standardNtsExplorerBudget;

  final TrustedTimeConfig _config;
  final MonotonicClock _clock;
  final SyncObserver? _observer;

  final ConsensusCache? _cache;
  final MarzulloEngine _engine;
  final int _explorerBudget;
  final int _ntsExplorerBudget;

  ExplorerShuffle _explorerShuffle;

  /// Foreground cycles still owed the front-loaded explorer budget.
  ///
  /// Zero — the steady state — until something arms it. A headless
  /// engine is never armed for install age, since only the foreground
  /// bootstrap calls [armExplorerBoost] for that; it can still be armed
  /// mid-run by a vantage change, which is a condition the device is in
  /// whether or not the app is in front of anyone.
  int _explorerBoostRemaining = 0;

  /// The smoothed anycast round trip this install last measured.
  ///
  /// Folded once per banked cycle from the quorum's round trips; a rise
  /// in its epoch is the vantage-change signal. Starts cold, so an
  /// engine that is never given a persisted baseline spends its first
  /// [VantageBaseline] warmup cycles unable to report a shift.
  VantageBaseline _vantageBaseline = const VantageBaseline();

  /// Source ids of the inventory's self-localizing hosts.
  ///
  /// The vantage signal is theirs alone: a unicast host's round trip
  /// moves with where that host is, whereas an anycast one resolves to
  /// whatever instance is nearest the caller and so moves only with
  /// where the caller is. Mixing the two would read a distant unicast
  /// server as a vantage change.
  late final Set<String> _anycastIds = {
    for (final entry in _config.ntpInventory)
      if (entry.tier == TimeServerTier.anycast)
        '${TimeSource.prefixNtp}${entry.host}',
  };

  /// Shared DNS concurrency budget (ADR 0008).
  ///
  /// One budget governs all uncached host resolutions the engine can see
  /// in-process: it is handed to every [NtpSource] and its value is
  /// forwarded as each [NtsSource]'s `dnsConcurrencyCap`. Built lazily
  /// from [TrustedTimeConfig.effectiveMaxConcurrentDnsLookups] so the
  /// migration ladder (and its one-time deprecation warning) runs exactly
  /// once, the first time the source list is materialised.
  late final DnsBudget _dnsBudget = _buildDnsBudget();

  /// Process-wide guard so the [ntsDnsConcurrencyCap] deprecation notice
  /// is emitted at most once regardless of how many engines are built.
  static bool _deprecationWarned = false;

  /// Lazily-initialized list of authoritative time sources.
  ///
  /// DNS concurrency is governed by the shared [_dnsBudget] (ADR 0008):
  /// NTP sources resolve through it cache-first, and its value is
  /// forwarded as each NTS source's `dnsConcurrencyCap` so all source
  /// kinds draw on one unified cold-start budget rather than the former
  /// NTS-only `ntsServers.length + 2` auto-size.
  late final List<TimeSource> _sources = _buildSources();

  /// Resolves the unified DNS budget and emits the one-time
  /// [ntsDnsConcurrencyCap] deprecation warning when the legacy NTS-only
  /// knob is what supplies the value (ADR 0008 migration).
  DnsBudget _buildDnsBudget() {
    final cap = _config.effectiveMaxConcurrentDnsLookups;
    // ignore: deprecated_member_use_from_same_package
    final legacyCap = _config.ntsDnsConcurrencyCap;
    if (_config.maxConcurrentDnsLookups == null &&
        legacyCap != null &&
        !_deprecationWarned) {
      _deprecationWarned = true;
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] TrustedTimeConfig.ntsDnsConcurrencyCap is '
          'deprecated; use maxConcurrentDnsLookups. Honouring the legacy '
          'value ($cap) as the unified DNS budget. See ADR 0008.',
        );
      }
    }
    return DnsBudget(cap, acquireTimeout: _config.maxLatency);
  }

  /// Builds the authoritative source list for this engine.
  ///
  /// [TrustedTimeConfig.effectiveTrustMode] is resolved once up front —
  /// before any source is constructed — so an invalid trust
  /// configuration (`usePlatformTrust: true` together with a non-empty
  /// `customRootCerts`) fails closed with [ArgumentError] regardless of
  /// whether any NTS servers are configured. Resolving it inside the
  /// `ntsServers` comprehension would skip the check whenever that list
  /// is empty, letting an invalid config build NTP/additional
  /// sources and silently bypass the "fail closed" guarantee. The
  /// resolved mode is then reused for every [NtsSource].
  List<TimeSource> _buildSources() {
    final trustMode = _config.effectiveTrustMode;
    // Reuse the already-constructed budget's cap rather than re-reading
    // effectiveMaxConcurrentDnsLookups: the migration ladder (and its
    // one-time deprecation warning) then runs exactly once, in
    // _buildDnsBudget, and the NTS forwarding cap can never drift from
    // the budget actually handed to the NTP sources. See ADR 0008.
    final dnsCap = _dnsBudget.maxConcurrent;
    return [
      for (final host in _config.ntpServers)
        NtpSource(
          host,
          dnsBudget: _dnsBudget,
          maxLatency: _config.maxLatency,
          burstCount: _config.ntpBurstCount,
          onStratumObserved: (s) =>
              _qualityTracker.setStratum('${TimeSource.prefixNtp}$host', s),
        ),
      for (final host in _config.ntsServers)
        NtsSource(
          host,
          port: _config.ntsPort,
          dnsConcurrencyCap: dnsCap,
          maxLatency: _config.maxLatency,
          trustMode: trustMode,
          customRoots: _config.customRootCerts.isEmpty
              ? null
              : _config.customRootCerts,
          onStratumObserved: (s) =>
              _qualityTracker.setStratum('${TimeSource.prefixNts}$host', s),
          burstCount: _config.ntsBurstCount,
          // Pre-sync rescue hook: non-null only while a rescue retry
          // cycle is active, pinning the NTS-KE certificate
          // validity-window check to the coarse instant instead of a
          // badly-skewed system clock. Consulted per dispatch, so the
          // same source instances serve normal and rescue cycles.
          verificationTimeProvider: () => _rescueVerificationTime,
        ),
      ..._config.additionalSources,
    ];
  }

  /// Whether [source] could contribute a Tier 1 sample to a truth box.
  ///
  /// The declared capability and nothing else: a source counts when it
  /// implements [VerifiedCapable] and answers `true`. [NtsSource] does,
  /// under every trust mode that can reach a library-controlled anchor
  /// set — see [NtsSource.canProduceVerified], which owns the
  /// mode-by-mode reasoning. Plain NTP and a `platformOnly` NTS source
  /// always resolve to [NtsAuthLevel.none], so no wait on one could
  /// ever raise a cycle above degraded.
  ///
  /// An explicit interface rather than a type test, because
  /// [MarzulloEngine] admits any sample carrying
  /// [NtsAuthLevel.verified] regardless of what produced it. A type
  /// test made scheduling narrower than admission: a custom source
  /// whose sample would have closed the box was never waited for, so a
  /// cycle could publish a degraded anchor while the reply that would
  /// have lifted it was still in flight. Opting in aligns the two
  /// without widening admission — a source that stamps `verified`
  /// without implementing [VerifiedCapable] still enters a box it
  /// qualifies for, and still is not waited for.
  ///
  /// Read only to decide whether to keep waiting. A source counted here
  /// still earns its [NtsAuthLevel] from what its sample carries, so an
  /// [NtsSource] that answers through the platform trust store — where
  /// an inspection CA could have terminated the handshake off-device —
  /// is filtered from the box on arrival exactly as if it had never
  /// been waited for. Do not reuse this predicate to admit, weight, or
  /// label a sample; that would convert a scheduling hint into a trust
  /// claim the source cannot support.
  ///
  /// Provenance is not consulted, and could not be — [_buildSources]
  /// concatenates [TrustedTimeConfig.additionalSources] into one list
  /// and discards where each entry came from. So a capable source
  /// supplied through `additionalSources` counts here, which is what
  /// the tier tests rely on.
  static bool _canProduceVerified(TimeSource source) =>
      source is VerifiedCapable &&
      (source as VerifiedCapable).canProduceVerified;

  /// The source ids this cycle may query.
  ///
  /// Both curated inventories are partitioned, each on its own budget.
  /// The plain-NTP tier queries its 10 anycast hosts every cycle and
  /// walks the 41 unicast ones [effectiveExplorerBudget] at a time. The
  /// NTS tier does the same shape with an extra step above it, per ADR
  /// 0007's 2026-08-02 postscript:
  ///
  /// - The [TimeServerTier.anycast] hosts are **fixed members**, queried
  ///   every cycle. They are members by identity and are never displaced
  ///   by a better-ranked unicast host — an anycast host resolves near
  ///   the caller from any vantage, which is what makes pinning them
  ///   viable before any ranking exists.
  /// - **Promotion** fills the blocking set up to
  ///   [TrustedTimeConfig.ntsQueryTarget] from the unicast ranking.
  ///   Only a host with a recorded success is promotable
  ///   ([SourceQualityTracker.hasSucceeded]): one known solely from a
  ///   failed probe would fill a slot the target's failure headroom
  ///   depends on. When too few ranked hosts qualify the remaining
  ///   slots are filled from the *unmeasured* hosts in walk order,
  ///   which is the cold-start case — those hosts are probed this cycle
  ///   either way, and discarding their samples in the one cycle where
  ///   the truth-box floor is otherwise unmet is not defensible. Hosts
  ///   the tracker has already watched fail are not eligible: that
  ///   would route around the admission rule on precisely the
  ///   population it was written for. Where nothing qualifies the
  ///   quorum is the fixed members alone.
  /// - The remaining unicast hosts are walked
  ///   [effectiveNtsExplorerBudget] at a time. Promoted hosts come out
  ///   of that budget rather than widening the cycle.
  ///
  /// A cycle therefore opens at most
  /// `ntsQueryTarget + effectiveNtsExplorerBudget` NTS-KE handshakes,
  /// where the pre-partition engine opened one per inventory host. On
  /// the curated inventory at the default target that is single digits;
  /// [TrustedTimeConfig.ntsQueryTarget] has a floor but no ceiling, so a
  /// caller that raises it raises this with it. The count is also a
  /// ceiling rather than an equality: an inventory with fewer unicast
  /// hosts than the target has nothing to promote from, and one whose
  /// fixed members already meet or exceed the target — which test
  /// inventories can arrange — leaves promotion no slots at all.
  ///
  /// Rotating the tier does not make an anchor's authentication level
  /// cycle-dependent, which was the objection the pass-through rested
  /// on alongside the since-invalidated "there are few of them". The
  /// fixed members are queried every cycle, so a cycle's *access* to
  /// whatever trust the configuration affords never turns on where the
  /// walk is. What varies is the box's membership above them, and with
  /// it its width — a precision property, not a trust one.
  ///
  /// The partition is trust-neutral, not trust-conferring. Whether a
  /// member classifies [NtsAuthLevel.verified] is decided per query by
  /// the trust backend the NTS-KE handshake actually resolved, via
  /// [authLevelForTrustBackend] — not by the mode requested and not by
  /// the tier the host landed in. The bundled and custom root paths
  /// reach `verified`; [TrustedTimeConfig.usePlatformTrust] resolves
  /// `platformOnly`, which refuses the bundled fallback and so is the
  /// one mode that classifies [NtsAuthLevel.none] whatever happens. An
  /// [NtsSource] a caller constructs directly defaults to
  /// `platformWithFallback` and straddles the two: `none` where the
  /// native verifier answers, `verified` where it is unavailable and
  /// the handshake falls back to bundled roots. Either way the
  /// partition does not enter into it. So a configuration that cannot
  /// form a verified box could not form one before this change either;
  /// what the invariant above claims is that the walk never narrows
  /// the trust a configuration does afford.
  ///
  /// Classification is the ceiling, not the count: [sync] drops the
  /// ids still inside their `_blacklistUntil` cooldown, then re-admits
  /// any of them the starvation rescue finds overdue, so how many
  /// blocking hosts actually gate a cycle is decided downstream. The
  /// ceiling holds either way — the rescue only reaches ids already in
  /// this set, never widening it.
  ///
  /// Eligibility is decided by source id, not by where the source came
  /// from. A source passes through unpartitioned when its id is absent
  /// from both inventories — which is every caller source in practice,
  /// since the partition narrows lists the library curates, not whatever
  /// the caller supplied. The exception is a
  /// [TrustedTimeConfig.additionalSources] entry whose id is
  /// `ntp:<host>` or `nts:<host>` for a host that *is* in the matching
  /// inventory: the engine cannot tell it apart from the
  /// inventory-backed source it shadows, so it is partitioned like one.
  /// Offline partition tests rely on this (see
  /// [TrustedTimeConfig.ntpInventoryForTesting] and
  /// [TrustedTimeConfig.ntsInventoryForTesting]); callers wanting an
  /// unconditionally queried host should give it an id outside the
  /// curated sets.
  ///
  /// Visible for tests so the narrowing and the pass-through rule can
  /// be asserted without running a cycle against the live inventory.
  ///
  /// Returns both halves of the split as one set: this asserts *which*
  /// hosts a cycle touches, which is what the narrowing rule is about.
  /// Use [selectCycleRolesForTesting] to assert the split itself.
  @visibleForTesting
  Set<String> selectCycleHostsForTesting() {
    final roles = _selectCycleHosts();
    return {...roles.blocking, ...roles.explorers};
  }

  /// Visible for tests asserting which half of the cycle a host lands in.
  @visibleForTesting
  ({Set<String> blocking, Set<String> explorers})
  selectCycleRolesForTesting() => _selectCycleHosts();

  /// The source ids this cycle queries, split by whether they gate it.
  ///
  /// `blocking` sources build the anchor and the cycle waits on them;
  /// `explorers` are fired alongside and feed only the ranking.
  ///
  /// The split is decided by id, on the same rule as the pass-through
  /// documented on [selectCycleHostsForTesting]: a source lands in
  /// `explorers` only when its id is one the partition assigned to the
  /// explorer walk. That is every inventory host outside the quorum,
  /// and it includes a [TrustedTimeConfig.additionalSources] entry
  /// whose id shadows such a host — the engine cannot tell it apart
  /// from the inventory source, so it is probed like one. A caller
  /// source with an id outside either inventory always blocks.
  ({Set<String> blocking, Set<String> explorers}) _selectCycleHosts() {
    final ntpInventory = _config.ntpInventory;
    final ntsInventory = _config.ntsInventory;
    // Both empty means there is nothing curated to narrow, so every
    // source is a caller source and blocks. Keyed on both because
    // either seam can empty one side alone, and treating one empty
    // inventory as "nothing to narrow" would re-flatten the other.
    if (ntpInventory.isEmpty && ntsInventory.isEmpty) {
      return (blocking: {for (final s in _sources) s.id}, explorers: const {});
    }

    final ntpPartition = partitionInventory(
      inventory: ntpInventory,
      shuffle: _explorerShuffle,
      explorerBudget: effectiveExplorerBudget,
      lastProbedUtcMs: (host) =>
          _qualityTracker.lastProbedUtcMs('${TimeSource.prefixNtp}$host'),
    );
    final ntsPartition = _partitionNtsInventory(ntsInventory);

    final quorum = <String>{
      for (final host in ntpPartition.quorum) '${TimeSource.prefixNtp}$host',
      for (final host in ntsPartition.quorum) '${TimeSource.prefixNts}$host',
    };
    final explorers = <String>{
      for (final host in ntpPartition.explorers) '${TimeSource.prefixNtp}$host',
      for (final host in ntsPartition.explorers) '${TimeSource.prefixNts}$host',
    };
    // Every id the partition had a say over. A source whose id is in
    // here but in neither half was narrowed out of this cycle; one
    // absent from it entirely is a caller source and passes through.
    // Both prefixes are required: keyed on the NTP ids alone, an NTS
    // host the walk left out would fall through to blocking, which is
    // the pass-through this partition replaced.
    final inventoryIds = <String>{
      for (final entry in ntpInventory) '${TimeSource.prefixNtp}${entry.host}',
      for (final entry in ntsInventory) '${TimeSource.prefixNts}${entry.host}',
    };
    final blocking = <String>{};
    final probing = <String>{};
    for (final s in _sources) {
      if (explorers.contains(s.id)) {
        probing.add(s.id);
      } else if (quorum.contains(s.id) || !inventoryIds.contains(s.id)) {
        blocking.add(s.id);
      }
    }
    return (blocking: blocking, explorers: probing);
  }

  /// Splits [inventory] into this cycle's NTS quorum and explorers.
  ///
  /// [partitionInventory] gives the tier split and the staleness-ordered
  /// walk; promotion to [TrustedTimeConfig.ntsQueryTarget] happens here
  /// rather than inside it, so the NTP path keeps its pure tier split.
  ///
  /// The promoted hosts are taken out of the explorer budget rather than
  /// added on top, so filling the target reallocates within the cycle
  /// instead of widening it — the handshake count is the target plus the
  /// budget either way.
  InventoryPartition _partitionNtsInventory(List<TimeServerEntry> inventory) {
    if (inventory.isEmpty) {
      return const InventoryPartition(quorum: [], explorers: []);
    }
    final target = _config.ntsQueryTarget;

    // Tier split at zero budget: this yields the fixed members and how
    // many slots promotion has to fill, without committing to a walk
    // the promotions would then have to be subtracted from.
    final fixed = partitionInventory(
      inventory: inventory,
      shuffle: _explorerShuffle,
      explorerBudget: 0,
      lastProbedUtcMs: (host) =>
          _qualityTracker.lastProbedUtcMs('${TimeSource.prefixNts}$host'),
    ).quorum;

    final slots = max(0, target - fixed.length);
    final unicast = [
      for (final entry in inventory)
        if (entry.tier != TimeServerTier.anycast) entry.host,
    ];

    // Rank-backed promotion draws on the whole unicast population, not
    // on this cycle's explorer slice. A host the walk measured and
    // found fast is exactly what promotion is for, and having just been
    // probed it sorts to the *end* of the staleness walk — scoping
    // candidates to the current slice would make a host unpromotable
    // for having been measured, leaving the walk with no consumer.
    //
    // Restricted to hosts with a recorded success, since ranked()
    // scores an unmeasured source neutrally: without the filter a host
    // known only from a timeout could outrank one never tried and fill
    // a slot the target's failure headroom depends on.
    final promoted = _qualityTracker
        .ranked([for (final host in unicast) '${TimeSource.prefixNts}$host'])
        .where(_qualityTracker.hasSucceeded)
        .take(slots)
        .map((id) => id.substring(TimeSource.prefixNts.length))
        .toList();

    // Walk the rest, promoted hosts excluded so none is ever both. The
    // budget is widened by the slots promotion could not fill, so a
    // cold-start cycle still spends its full target + budget instead of
    // shrinking to the anycast count — that surplus is the fill below.
    final shortfall = slots - promoted.length;
    final promotedSet = promoted.toSet();
    final walk = partitionInventory(
      inventory: [
        for (final entry in inventory)
          if (!promotedSet.contains(entry.host)) entry,
      ],
      shuffle: _explorerShuffle,
      explorerBudget: effectiveNtsExplorerBudget + shortfall,
      lastProbedUtcMs: (host) =>
          _qualityTracker.lastProbedUtcMs('${TimeSource.prefixNts}$host'),
    ).explorers;

    // Cold-start fill: with fewer qualifying ranked hosts than slots,
    // draw from the walk. partitionInventory already sorts never-probed
    // hosts first with the per-install shuffle breaking ties, so this
    // consumes a traversal the cycle computes anyway — no new selection
    // rule and no new randomness. Those hosts are probed this cycle
    // regardless; the fill decides only whether the cycle may *use* the
    // result, and discarding it in the one cycle where the truth-box
    // floor is otherwise unmet is not defensible. The cost is latency: a
    // filled host gates the cycle while nothing is known about it.
    // Accepted, since a cold cycle has no cached anchor either and
    // maxLatency bounds it.
    //
    // Only *unmeasured* hosts qualify, which is the difference between
    // knowing nothing and knowing something bad. Taking the head
    // unconditionally reads the same on a genuinely cold install, where
    // the head is unmeasured by construction — but once every unicast
    // candidate carries a failure the head is merely the oldest failure,
    // and seating it would route around `hasSucceeded` on exactly the
    // population that rule was written for. The fill would stop being a
    // cold-start allowance and become a standing exemption, leaving the
    // target's failure headroom nominal on a permanently degraded
    // network. Where nothing qualifies the quorum falls back to the
    // fixed members, which still meet the verified floor; the failed
    // hosts stay explorers and are retried there.
    final filled = <String>[];
    for (final host in walk) {
      if (filled.length == shortfall) break;
      if (!_qualityTracker.hasBeenProbed('${TimeSource.prefixNts}$host')) {
        filled.add(host);
      }
    }
    final filledSet = filled.toSet();

    // Trimmed rather than left at the widened budget: the surplus was
    // borrowed for the fill, so what the fill declined goes back rather
    // than quietly widening the cycle beyond target + budget.
    return InventoryPartition(
      quorum: [...fixed, ...promoted, ...filled],
      explorers: [
        for (final host in walk)
          if (!filledSet.contains(host)) host,
      ].take(effectiveNtsExplorerBudget).toList(),
    );
  }

  /// Tracks consecutive failures for each source to implement exponential cooldown.
  final _sourceHealth = <String, int>{};

  /// Precise timestamps until which a source is considered "blacklisted."
  final _blacklistUntil = <String, DateTime>{};

  /// Counts consecutive [TransientSourceError] failures from a single
  /// source so a sustained "transient" condition (e.g. permanent DNS
  /// pool saturation) eventually escalates to the regular cooldown
  /// ladder rather than retrying every cycle indefinitely. Reset on a
  /// successful query, on a regular (non-transient) failure, and on
  /// each escalation. The escalation threshold is
  /// [TrustedTimeConfig.transientStreakThreshold].
  final _sourceTransientStreak = <String, int>{};

  /// Per-source quality tracker introduced by upstream 2.1.0. Ranks
  /// healthy sources by a weighted score (RTT/uncertainty 40% +
  /// consensus participation 40% + NTP stratum 20%) so high-quality
  /// sources are queried first. Paired with a starvation rescue in
  /// [sync] that force-includes a source the cooldown filter excluded
  /// once it has gone unqueried for 5 consecutive successful cycles.
  /// Composes with our outer-fast-path source filtering: the fast-path
  /// still bails the cycle when `_sources` is empty or every cooled-down
  /// source is also not yet starved; ranking re-orders what survives the
  /// cooldown filter, and the rescue re-admits a long-ignored cooled
  /// source so it cannot be starved indefinitely.
  ///
  /// Constructor-injectable so tests can observe the recorded
  /// observations; defaults to a fresh instance in production.
  final SourceQualityTracker _qualityTracker;

  /// Seeds the quality tracker's durable stats from a persisted
  /// snapshot. Call before the first [sync] so the first cycle already
  /// ranks on RTT/success history instead of starting blind.
  void restoreSourceStats(Map<String, SourceQualityStats> stats) =>
      _qualityTracker.restore(stats);

  /// Returns the quality tracker's durable stats for persistence.
  Map<String, SourceQualityStats> sourceStatsSnapshot() =>
      _qualityTracker.snapshot();

  /// Adopts a persisted explorer walk order. Call before the first
  /// [sync]; a cycle already under way keeps the shuffle it started
  /// with.
  ///
  /// Pairs with [restoreSourceStats] rather than the constructor
  /// because the seed is a storage read and the engine is built
  /// synchronously. Without it the engine walks a throwaway
  /// permutation, which still probes every host eventually but
  /// re-anchors to a fresh prefix on every process start.
  void restoreExplorerShuffle(ExplorerShuffle shuffle) =>
      _explorerShuffle = shuffle;

  /// This install's explorer walk order.
  ExplorerShuffle get explorerShuffle => _explorerShuffle;

  /// Adopts a persisted anycast baseline. Call before the first [sync].
  ///
  /// Without it the detector re-warms from cold on every process start,
  /// and a vantage change that happened while the process was dead is
  /// never seen: the first observation after launch becomes the
  /// baseline, so the new network is simply where this install has
  /// always been.
  void restoreVantageBaseline(VantageBaseline baseline) =>
      _vantageBaseline = baseline;

  /// The current anycast baseline, for persistence.
  VantageBaseline get vantageBaseline => _vantageBaseline;

  /// Widens the explorer budget to [boostedExplorerBudget] for the next
  /// [cycles] cycles, then decays to the platform steady state.
  ///
  /// Called by the foreground bootstrap with the persisted remaining
  /// count, so a front-load spans launches instead of restarting (or
  /// evaporating) on every process start. No background *bootstrap*
  /// calls it, so the install-age front-load stays foreground-only.
  ///
  /// Parameterized by count rather than latched to "is this a new
  /// install" because the same primitive serves vantage-epoch recovery,
  /// which re-arms on a trigger that has nothing to do with install
  /// age. That path runs from inside a cycle and so can arm a headless
  /// engine — deliberately, since a device that moved networks needs
  /// re-exploration whether or not anyone is looking at it. The boost
  /// it arms lives only as long as that process: only the foreground
  /// path persists the remaining count, so a headless recovery is
  /// re-armed by the next observation instead of resumed.
  ///
  /// Re-arming while a boost is live replaces the remainder rather than
  /// accumulating: two overlapping triggers mean the exploration should
  /// stay wide for [cycles] more cycles, not for the sum.
  ///
  /// [cycles] must be non-negative; zero is the no-op that disarms.
  /// Enforced with a [RangeError] in all build modes: the count reaches
  /// here from persisted storage via the foreground bootstrap, so a
  /// release build would otherwise clamp a corrupt value silently.
  void armExplorerBoost(int cycles) {
    _explorerBoostRemaining = RangeError.checkNotNegative(cycles, 'cycles');
  }

  /// Foreground cycles still owed the front-loaded explorer budget.
  ///
  /// Read by the foreground path after a banked cycle to persist the
  /// decayed count.
  int get explorerBoostRemaining => _explorerBoostRemaining;

  /// The explorer budget the *next* cycle will use.
  ///
  /// Widened while a front-load is live; the platform steady state
  /// otherwise. Exposed for tests asserting the decay curve without
  /// inspecting the selected host set.
  ///
  /// A boost only ever widens. [boostedExplorerBudget] is the standard
  /// platform width, so a caller that constructed the engine with a
  /// *wider* explicit budget would otherwise see the boost narrow its
  /// cycles — a front-load that front-loads less.
  @visibleForTesting
  int get effectiveExplorerBudget => _explorerBoostRemaining > 0
      ? max(_explorerBudget, boostedExplorerBudget)
      : _explorerBudget;

  /// The NTS explorer budget the *next* cycle will use.
  ///
  /// Same boost rule as [effectiveExplorerBudget], widening to
  /// [standardNtsExplorerBudget] while a front-load is live and never
  /// narrowing an explicitly wider budget. The boost is the standard
  /// width, so it is a no-op off iOS — which is where the convergence
  /// gap it exists to close actually is. See
  /// [defaultNtsExplorerBudgetFor] for why the front-load matters more
  /// on this tier than on the NTP one.
  @visibleForTesting
  int get effectiveNtsExplorerBudget => _explorerBoostRemaining > 0
      ? max(_ntsExplorerBudget, standardNtsExplorerBudget)
      : _ntsExplorerBudget;

  int _syncAttempts = 0;

  /// Plausibility floor for the pre-sync rescue's coarse estimate.
  ///
  /// An unauthenticated NTP reply steers only the TLS validity-window
  /// check, but an attacker feeding absurd backdated time must not be
  /// able to drag the verification instant arbitrarily backwards into
  /// the validity window of an old compromised certificate. This
  /// binary cannot predate its own release, so any coarse estimate
  /// before this floor is rejected and the rescue is not armed.
  /// Bumped per release.
  @visibleForTesting
  static final rescueFloorUtc = DateTime.utc(2026, 7, 1);

  /// Coarse verification instant for the active pre-sync rescue, or
  /// null when no rescue is active (the steady state). Non-null only
  /// for the duration of the single rescue retry cycle; consulted by
  /// every [NtsSource] via its `verificationTimeProvider`.
  ///
  /// Deliberately engine-scoped, unlike [_CycleRescueState]: sources
  /// are engine-lifetime objects whose [TimeSource.getTime] takes no
  /// arguments, so the armed instant must be visible outside any one
  /// cycle's scope. This is safe where engine-scoped *bookkeeping*
  /// was not: the [_rescueAttempted] latch is checked and set with no
  /// await in between, so under Dart's single-threaded execution
  /// exactly one invocation per cold start can ever write here —
  /// there is no arm/arm or clear-while-arming race. If an
  /// overlapping cycle's NTS dispatch happens to read the armed
  /// instant, its handshake verifies the certificate validity window
  /// against the same floor-checked coarse instant the rescue retry
  /// itself uses — an identical security posture for the same bounded
  /// window. Conversely, a late dispatch that reads null after the
  /// retry clears it reverts to system-clock verification, the
  /// strictly more conservative pre-rescue behaviour.
  DateTime? _rescueVerificationTime;

  /// Whether the rescue has already been attempted this cold start.
  /// One-shot: a rescue that fails must not re-arm on the next cert
  /// failure, or a persistent middlebox/cert problem would double
  /// every cycle's network cost indefinitely.
  bool _rescueAttempted = false;

  /// Set once [_createAnchor] mints the first anchor of this engine's
  /// lifetime. The clock-skew deadlock is a cold-start condition: once
  /// any anchor exists the engine has an internal time reference, and
  /// mid-run re-skew is out of scope for the rescue.
  bool _hasAnchored = false;

  /// Test seam replacing the direct-NTP fallback the rescue uses when
  /// the failed cycle collected no NTP samples. When non-null it is
  /// invoked instead of the sequential [TrustedTimeConfig.ntpServers]
  /// probe loop; production leaves it null.
  @visibleForTesting
  Future<TimeSample> Function()? rescueProbeOverride;

  /// Eagerly invokes [Warmable.warm] on every source that supports it,
  /// in parallel.
  ///
  /// Called during application bootstrap so per-source setup costs
  /// (e.g., the NTS-KE TCP+TLS+key-exchange handshake) complete before
  /// the first [sync] cycle, and again by [sync] itself as the global
  /// warming barrier so every cycle's queries — foreground or
  /// background — launch against fully-warmed state with converged
  /// start times. Without this, those costs fall inside the cycle's
  /// wall clock and contaminate sample timestamps with hundreds of
  /// milliseconds of skew, preventing Marzullo intervals from
  /// overlapping.
  ///
  /// Scoped to the hosts the *next* cycle will query — the union of both
  /// halves of [_selectCycleHosts], not the whole source list. An NTS
  /// warm is a TCP connect plus a TLS handshake plus a key exchange, so
  /// warming the full curated inventory would open ~57 of them per
  /// bootstrap to prime cookie jars for hosts the cycle then narrows
  /// away. Explorers are included rather than just the quorum: they are
  /// queried this cycle too, and [_launchExplorerProbes] bounds each
  /// probe at `explorerTimeout` — a cold NTS-KE inside that window would
  /// time out and be recorded as the *host* being slow, teaching the
  /// ranking the opposite of the truth.
  ///
  /// Each [Warmable.warm] is itself idempotent and memoized, so calling
  /// this method multiple times is safe and cheap. Failures from
  /// individual sources are swallowed: warming is best-effort, and
  /// [sync] retains its existing JIT-warm fallback path.
  ///
  /// [sync] does not call this method — it calls [_warmHosts] with the
  /// selection it already made. See there for why re-deriving one would
  /// not do.
  ///
  /// `async` rather than returning [_warmHosts] directly: the selection
  /// is the first thing to touch the late-built `_sources`, so an
  /// invalid trust config throws here. Callers are promised a rejected
  /// future, not a synchronous throw.
  Future<void> warmAllSources() async {
    final roles = _selectCycleHosts();
    await _warmHosts({...roles.blocking, ...roles.explorers});
  }

  /// Warms every [Warmable] source whose id is in [wanted].
  ///
  /// Takes the selection rather than deriving it so a caller that has
  /// already partitioned the cycle warms the hosts it is about to
  /// query, not a fresh partition. The two can differ: explorer probes
  /// are unawaited and outlive their cycle, so one landing in
  /// [_qualityTracker] between a cycle's selection and its warm barrier
  /// would re-rank the inventory and move NTS promotion or the walk
  /// under it. The barrier would then prime cookie jars for hosts the
  /// cycle is not querying and leave the ones it is cold — the reverse
  /// of what the barrier exists for.
  ///
  /// First-seen wins for a colliding id, matching the blocking path's
  /// `healthyById` dedup and [_launchExplorerProbes]. An
  /// `additionalSources` entry shadowing an inventory host is queried
  /// once; warming both instances would prime a jar nothing then reads
  /// and, for NTS, pay a second NTS-KE handshake for it — inside the
  /// barrier, where the cost is start latency.
  Future<void> _warmHosts(Set<String> wanted) async {
    final byId = <String, TimeSource>{};
    for (final s in _sources) {
      if (wanted.contains(s.id)) byId.putIfAbsent(s.id, () => s);
    }
    final warmables = byId.values.whereType<Warmable>().toList(growable: false);
    if (warmables.isEmpty) return;
    await Future.wait(
      warmables.map((s) async {
        try {
          await s.warm();
        } catch (_) {
          // Same semantics as the warm-phase failure handling in
          // sync(): swallow so a single misbehaving source cannot
          // block bootstrap.
        }
      }),
    );
  }

  /// Executes a full synchronization cycle across all healthy sources.
  ///
  /// This method is the primary driver of trust establishment. It races sources,
  /// performs adaptive outlier filtering, and requires stability across
  /// multiple samples before finalizing an anchor.
  ///
  /// ### Pre-sync rescue (cold-start clock-skew deadlock)
  ///
  /// A device whose RTC is badly wrong (dead CMOS battery, factory
  /// reset, manual mis-set) cannot complete the NTS-KE TLS handshake:
  /// the server certificate is judged expired or not-yet-valid against
  /// the skewed system clock — yet NTS is the very mechanism that
  /// would fix the clock. When a cold-start cycle fails and at least
  /// one NTS source's failure carried that certificate
  /// validity-window signature, this wrapper obtains a coarse
  /// unauthenticated estimate from NTP, clamps it against
  /// [rescueFloorUtc], arms it as the NTS verification instant, and
  /// re-runs exactly one cycle. The coarse instant pins *only* the
  /// certificate validity-window check — chain-of-trust, hostname, and
  /// signature validation are untouched, the sample's auth level still
  /// derives solely from the trust backend, and the NTP estimate never
  /// becomes an anchor by itself. One-shot per cold start; never armed
  /// once any anchor exists.
  Future<TrustAnchor> sync() async {
    // Rescue bookkeeping is cycle-scoped, like [_CompletionGuard]: a
    // fresh holder per invocation, threaded through [_runSyncCycle]
    // into [_querySafe], instead of engine-scoped collections cleared
    // at the top of this method. An engine-scoped reset would race
    // under overlapping `sync()` invocations (which the public-API
    // wrapper does not strictly rule out — see the note inside
    // [_runSyncCycle]): one cycle could clear the collections while
    // another is still populating them, skipping or mis-arming the
    // rescue and consuming the one-shot latch unpredictably.
    final rescueState = _CycleRescueState();
    try {
      return await _runSyncCycle(rescueState);
    } catch (e) {
      if (_hasAnchored ||
          _rescueAttempted ||
          rescueState.certValidityFailedIds.isEmpty) {
        rethrow;
      }
      _rescueAttempted = true;
      final coarse = await _acquireCoarseRescueTime(rescueState);
      if (coarse == null) {
        if (TrustedTimeLog.enabled) {
          TrustedTimeLog.log(
            TrustedTimeLogLevel.warning,
            '[TrustedTime] pre-sync rescue unavailable: NTS cert-validity '
            'failure detected but no plausible coarse NTP estimate could '
            'be obtained (ntpServers empty, all queries failed, or every '
            'candidate fell below the plausibility floor).',
          );
        }
        rethrow;
      }
      if (coarse.isBefore(rescueFloorUtc)) {
        // Backstop only: [_acquireCoarseRescueTime] already floor-
        // filters every candidate, so this cannot fire today. Kept as
        // defence in depth — the floor is a security invariant, and a
        // future acquisition path must not be able to bypass it
        // silently.
        if (TrustedTimeLog.enabled) {
          TrustedTimeLog.log(
            TrustedTimeLogLevel.warning,
            '[TrustedTime] pre-sync rescue rejected: coarse estimate '
            '${coarse.toIso8601String()} predates plausibility floor '
            '${rescueFloorUtc.toIso8601String()}.',
          );
        }
        rethrow;
      }
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.info,
          '[TrustedTime] pre-sync rescue armed: '
          'coarse=${coarse.toIso8601String()} — retrying sync with the '
          'NTS-KE certificate validity check pinned to the coarse instant.',
        );
      }
      // The cert failure was structural (skewed clock), not host
      // unhealthiness — lift the cooldown the failing cycle just armed
      // so the retry actually re-queries the NTS sources, and drop the
      // health score those failures accrued.
      for (final id in rescueState.certValidityFailedIds) {
        _blacklistUntil.remove(id);
        _sourceHealth.remove(id);
        _sourceTransientStreak.remove(id);
      }
      _rescueVerificationTime = coarse;
      try {
        // The retry gets its own fresh bookkeeping: it can only run
        // once (the latch above is already set), so nothing reads it,
        // but sharing the failed cycle's holder would conflate the two
        // cycles' samples if this ever changes.
        return await _runSyncCycle(_CycleRescueState());
      } finally {
        // One retry cycle only: subsequent handshakes verify against
        // the system clock again. On success the anchor keeps
        // projection correct regardless of the RTC; on failure the
        // one-shot _rescueAttempted latch prevents re-arming.
        _rescueVerificationTime = null;
      }
    }
  }

  /// Whether the one-shot pre-sync rescue has already been consumed
  /// this cold start. Exposed for tests.
  @visibleForTesting
  bool get rescueAttempted => _rescueAttempted;

  /// The rescue verification instant currently armed, or null outside
  /// the rescue retry cycle. Exposed for tests.
  @visibleForTesting
  DateTime? get debugRescueVerificationTime => _rescueVerificationTime;

  /// Acquires the coarse unauthenticated estimate used to pin the
  /// NTS-KE certificate validity check during the rescue retry.
  ///
  /// Prefers NTP samples already collected by the failed cycle
  /// (recorded in [rescueState]; mixed NTP+NTS configs get the
  /// estimate for free), picking the sample with the smallest
  /// round-trip delay. Falls back to direct sequential NTP queries
  /// against [TrustedTimeConfig.ntpServers] until one succeeds.
  ///
  /// Every candidate is filtered against [rescueFloorUtc] here, so a
  /// single backdated reply (broken server or attacker replaying old
  /// time) is skipped rather than poisoning the whole rescue while
  /// plausible siblings remain. Returns null when no plausible
  /// estimate is obtainable (NTS-only config with empty ntpServers,
  /// every query failed, or every candidate fell below the floor).
  Future<DateTime?> _acquireCoarseRescueTime(
    _CycleRescueState rescueState,
  ) async {
    TimeSample? best;
    for (final s in rescueState.ntpSamples) {
      final candidate = _plausibleCoarseFrom(s);
      if (candidate == null) continue;
      final delay = s.delayMs;
      final bestDelay = best?.delayMs;
      if (best == null ||
          (delay != null && (bestDelay == null || delay < bestDelay))) {
        best = s;
      }
    }
    if (best != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        best.interval.midpoint,
        isUtc: true,
      );
    }
    final override = rescueProbeOverride;
    if (override != null) {
      try {
        final sample = await override().timeout(_config.maxLatency);
        return _plausibleCoarseFrom(sample);
      } catch (_) {
        return null;
      }
    }
    for (final host in _config.ntpServers) {
      try {
        final sample = await _defaultRescueProbe(
          host,
        ).timeout(_config.maxLatency);
        final candidate = _plausibleCoarseFrom(sample);
        if (candidate != null) return candidate;
      } catch (e) {
        if (TrustedTimeLog.enabled) {
          TrustedTimeLog.log(
            TrustedTimeLogLevel.debug,
            '[TrustedTime] pre-sync rescue probe against ntp:$host '
            'failed: $e',
          );
        }
      }
    }
    return null;
  }

  /// Converts [sample]'s interval midpoint to the coarse rescue
  /// instant, or null (with a warning) when it falls below
  /// [rescueFloorUtc] — the per-candidate arm of the plausibility
  /// floor, letting acquisition skip a backdated reply and keep
  /// searching instead of aborting the rescue on the first poison.
  DateTime? _plausibleCoarseFrom(TimeSample sample) {
    final candidate = DateTime.fromMillisecondsSinceEpoch(
      sample.interval.midpoint,
      isUtc: true,
    );
    if (candidate.isBefore(rescueFloorUtc)) {
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] pre-sync rescue candidate from '
          '${sample.sourceId} rejected: ${candidate.toIso8601String()} '
          'predates plausibility floor '
          '${rescueFloorUtc.toIso8601String()}.',
        );
      }
      return null;
    }
    return candidate;
  }

  /// Production rescue probe: one plain NTP query against [host],
  /// sharing the engine's DNS budget and latency budget.
  Future<TimeSample> _defaultRescueProbe(String host) => NtpSource(
    host,
    dnsBudget: _dnsBudget,
    maxLatency: _config.maxLatency,
  ).getTime();

  /// Classifies whether [error] carries the NTS-KE certificate
  /// validity-window failure signature that the pre-sync rescue can
  /// break.
  ///
  /// Strong signal: [nts.NtsErrorKeProtocol] whose rustls diagnostic
  /// names an expired / not-yet-valid peer certificate. Other rustls
  /// certificate rejections (UnknownIssuer, BadSignature, hostname
  /// mismatch, ...) share the `invalid peer certificate` prefix but
  /// are diagnostically specific non-skew failures — matching them
  /// would burn the one-shot rescue latch on a problem the rescue
  /// cannot fix. Weak signal: [nts.NtsErrorTimeout] in the TLS phase
  /// — some middleboxes kill the handshake instead of surfacing an
  /// alert; accepted because the rescue retry is cheap, one-shot, and
  /// can only fail again, never weaken validation.
  @visibleForTesting
  static bool isCertValidityFailure(Object error) {
    if (error is nts.NtsErrorKeProtocol) {
      final message = error.message.toLowerCase();
      return message.contains('expired') ||
          message.contains('notvalidyet') ||
          message.contains('not valid yet');
    }
    if (error is nts.NtsErrorTimeout) {
      return error.phase == nts.TimeoutPhase.tls;
    }
    return false;
  }

  Future<TrustAnchor> _runSyncCycle(_CycleRescueState rescueState) async {
    // Per-cycle synchronous re-entry guard for [_completeSync].
    // Allocated fresh on every [sync] call and captured by the sample
    // listener closure, so the guard's lifetime is exactly one sync
    // cycle. This is the deliberate alternative to an engine-instance
    // flag with a top-of-`sync()` reset: a per-cycle holder is robust
    // against overlapping `sync()` invocations (which would otherwise
    // race on the engine-scoped reset). [rescueState] follows the
    // same pattern for the pre-sync rescue's bookkeeping.
    //
    // [SyncEngine] itself does not gate against concurrent `sync()`
    // entries — that responsibility lives in the public-API wrapper
    // (`TrustedTimeImpl._performSync` in `lib/src/trusted_time_impl.dart`,
    // which uses a `_syncInProgress` Completer to coalesce concurrent
    // callers into a single in-flight cycle). That guard is currently
    // imperfect under tight retry/timer scheduling (tracked as
    // `trusted_time-exw`), but even if two `sync()` invocations slip
    // past it, each cycle's `_completeSync` pair operates on its own
    // [_CompletionGuard] and cannot reset the other's in-flight state.
    final completionGuard = _CompletionGuard();
    _observer?.onSyncStarted();
    final swSync = Stopwatch()..start();

    // Empty-pool fast path: bail out *before* allocating the
    // StreamController. A single-subscription StreamController whose
    // listener is never attached has a `close()` future that does not
    // complete on the test event loop, so awaiting it from the finally
    // block of the try/catch below would hang the whole sync cycle
    // (and the bootstrap that waits on it). Surfacing the failure
    // through the observer here keeps the no-op cycle's telemetry
    // shape identical to a populated cycle that produced zero
    // eligible samples.
    //
    // Source ordering composes cooldown filtering (this code path)
    // with upstream 2.1.0's quality-ranked + starvation-guarded
    // composition from `_qualityTracker`: the cooldown filter
    // determines which sources are even eligible this cycle, then
    // the quality tracker re-orders the survivors so high-quality
    // sources are queried first (for early-exit latency). A
    // starvation rescue then re-admits any source the cooldown filter
    // excluded that has gone unqueried for too long, so a source stuck
    // in exponential cooldown cannot be permanently ignored. Empty-pool
    // detection stays here so the actionable error distinguishing "no
    // sources configured" from "all in cooldown" is preserved — it now
    // fires only when no cooled-down source is yet due for rescue.
    final now = DateTime.now();
    final cycleRoles = _selectCycleHosts();
    final cycleHosts = cycleRoles.blocking;
    // Explorers are excluded from the denominator on purpose: they
    // cannot contribute to consensus, so counting them would deflate
    // every coverage ratio by the explorer width and make the reported
    // confidence move with the front-load rather than with time quality.
    completionGuard.cycleHostCount = cycleHosts.length;
    final healthySources = _sources.where((s) {
      if (!cycleHosts.contains(s.id)) return false;
      final until = _blacklistUntil[s.id];
      return until == null || now.isAfter(until);
    }).toList();
    // Index healthy sources by id so the ranked-order construction below
    // is O(n) (one map lookup per id) instead of O(n^2) (a firstWhere
    // scan per id). Doubles as the O(1) membership test for the
    // starvation rescue pass.
    //
    // putIfAbsent keeps the first-seen source for a colliding id, which
    // must agree with ranked()'s toSet() dedup (also first-seen): the
    // ranked slot for a duplicated id and the source actually queried for
    // it have to resolve to the same instance. A map literal would instead
    // keep the last-seen source, making that choice depend on _sources
    // construction order.
    final healthyById = <String, TimeSource>{};
    for (final s in healthySources) {
      healthyById.putIfAbsent(s.id, () => s);
    }
    final rankedIds = _qualityTracker.ranked(healthySources.map((s) => s.id));
    final activeSources = <TimeSource>[
      // High-quality sources first, in ranked order.
      for (final id in rankedIds) healthyById[id]!,
      // Starvation rescue: a source the cooldown filter excluded that has
      // gone unqueried for _kStarvationCycles successful cycles is
      // force-included for a single query, so a source stuck in
      // exponential cooldown cannot be permanently ignored and its
      // quality estimate stays fresh. Iterating _sources (rather than
      // healthySources, which are all already in rankedIds) is what makes
      // this branch reachable; the healthyById membership check prevents
      // double-inclusion.
      //
      // Restricted to this cycle's hosts: a source the partition left
      // out is not starved, it is simply not this cycle's turn, and
      // re-admitting it here would undo the narrowing every cycle. The
      // explorer walk is itself the anti-starvation mechanism for those
      // hosts — see [partitionInventory].
      for (final s in _sources)
        if (cycleHosts.contains(s.id) &&
            !healthyById.containsKey(s.id) &&
            _qualityTracker.isStarved(s.id))
          s,
    ];
    if (activeSources.isEmpty) {
      // Distinguish "no sources configured" from "all sources in
      // cooldown" so the surfaced error is actionable. Both collapse
      // to the same fast-path here, but the operator's next step is
      // very different — adding sources vs. waiting for the
      // exponential cooldown to expire.
      final emptyError = _sources.isEmpty
          // An empty source configuration fails identically on every
          // attempt — non-transient, so retry schedulers give up rather
          // than loop the same failure forever. Cooldown, by contrast,
          // expires with time, so a retry can plausibly recover.
          ? const TrustedTimeSyncException(
              'No time sources are configured: ntpServers, '
              'ntsServers, and additionalSources are all empty.',
              transient: false,
            )
          : const TrustedTimeSyncException(
              'All configured time sources are currently in exponential '
              'cooldown due to persistent failures.',
            );
      _markSyncFailed(emptyError);
      throw emptyError;
    }

    final samples = <TimeSample>[];
    final completer = Completer<TrustAnchor>();
    var streamClosed = false;
    // Each event carries the source that produced it alongside its
    // outcome. A failed query arrives as a null sample, which on its own
    // says nothing about which host fell silent — and the verified-floor
    // bookkeeping below has to decrement for a verified-capable source
    // whether it answered, was rejected, or failed.
    StreamSubscription<(TimeSource, TimeSample?)>? streamSub;
    final sampleController = StreamController<(TimeSource, TimeSample?)>();

    try {
      var pendingQueries = activeSources.length;

      // Which verified-capable hosts are still in flight.
      //
      // The truth box needs [MarzulloEngine.minVerifiedQuorum] distinct
      // verified hosts, so a cycle can hold a degraded result that a
      // later verified reply would have lifted. Knowing what is still
      // outstanding is what lets the early exit tell "degraded" from
      // "degraded so far". Emptied one host at a time on terminal
      // outcomes — sample, rejection, or failure — so it runs out on
      // any path [pendingQueries] does.
      //
      // Keyed by host id rather than a count of query objects, because
      // the floor it is compared against counts hosts. [activeSources]
      // can hold two instances of one id: the starvation rescue
      // re-admits from [_sources] directly, so a blacklisted id backed
      // by two instances is queried once per instance (the same
      // asymmetry [_observeVantage] guards). A per-instance tally would
      // then claim a floor of three still reachable on two distinct
      // hosts, and the cycle would hold a stable degraded result for the
      // full latency budget waiting on a box that cannot form.
      //
      // A multiset rather than a set, because a host is still in flight
      // until its last instance has ended: dropping the id on the first
      // outcome would understate reachability and release a hold whose
      // remaining query could still have closed the box — the opposite
      // error, and the one that costs an anchor's trust level rather
      // than latency.
      final pendingVerifiedHosts = <String, int>{};
      for (final s in activeSources.where(_canProduceVerified)) {
        pendingVerifiedHosts[s.id] = (pendingVerifiedHosts[s.id] ?? 0) + 1;
      }

      TimeInterval? lastStabilityInterval;
      var stableCount = 0;
      var rejectedInvalid = 0;

      // Whether the hold below is withholding a result that had reached
      // stability, and that no later resolve has published or retracted.
      //
      // The hold has to be re-examined on outcomes that never reach a
      // resolve: a failed or rejected verified query empties
      // [pendingVerifiedHosts] without producing a sample, so nothing
      // downstream would notice that the wait had become pointless.
      // Without this such a cycle stays blocked until an unrelated query
      // times out — the hold outliving the queries it waits on, which is
      // the one thing it must not do.
      //
      // A flag rather than the withheld result itself, because by the
      // time the hold ends the population it was reduced from may no
      // longer be the cycle's. The arrival that ends the wait is often
      // the one that moves it: a third verified reply can close the box
      // on a different interval. Publishing the old result there would
      // discard the very box the wait was for, so the release path
      // resolves the population as it stands. The same arrival also
      // resets the stability counter, and a cycle is never published on
      // an interval that has not held twice — so the flag is cleared
      // wherever a resolve fails to re-reach stability, leaving the
      // normal stability path and _finalizeSync to decide the cycle.
      var holdWithheld = false;

      /// Whether [result] should still be withheld.
      ///
      /// Degraded, something verified-capable outstanding, and — the
      /// part an outstanding query alone does not establish — enough of
      /// the floor still reachable for the wait to be able to pay off. A
      /// cycle that has banked two verified hosts and lost one of three
      /// queries can never reach a floor of three, so holding it would
      /// spend up to the full maxLatency on an outcome already decided.
      ///
      /// Reachability is over hosts, and banked and outstanding hosts
      /// are not disjoint sets: a host can answer once and still have a
      /// second query in flight under the starvation rescue, and a
      /// verified host whose sample was banked but judged unusable is
      /// outstanding to neither. Adding the two tallies would double
      /// count such a host into a floor it cannot reach twice, so they
      /// are unioned instead. Collapsed through the engine so the hold
      /// and the floor agree on what a verified host is.
      bool holdApplies(ConsensusResult result) {
        if (!result.degradedTier || pendingVerifiedHosts.isEmpty) return false;
        final reachable = _engine.usableVerifiedHostIds(samples)
          ..addAll(pendingVerifiedHosts.keys);
        return reachable.length >= _engine.minVerifiedQuorum;
      }

      void fireEarlyExit(ConsensusResult result, List<TimeSample> population) {
        // Early Exit: If configured, we return as soon as a stable quorum
        // is reached to minimize power and network consumption.
        if (_config.earlyExit || population.length == activeSources.length) {
          swSync.stop();
          unawaited(
            _completeSync(
              result,
              population,
              swSync.elapsedMilliseconds,
              completer,
              completionGuard,
            ),
          );
        }
      }

      /// Publishes the cycle once a hold no longer applies.
      ///
      /// Runs on every terminal outcome, after the balance has dropped,
      /// so the cycle resumes the moment the last query it was waiting
      /// on ends rather than when some unrelated query does.
      ///
      /// Resolves rather than replaying what was withheld, so a sample
      /// that arrived during the hold is reflected in what gets
      /// published — including the case where it formed the truth box the
      /// wait existed for.
      ///
      /// Not a second route past the stability guard. [holdWithheld] is
      /// true only while the population as it stands has resolved to the
      /// same interval [requiredStability] times over: the stability
      /// block clears the flag on any accepted sample that does not
      /// re-establish that, and no other path adds to [samples]. So the
      /// resolve here is over the population that was already judged
      /// stable, and reproduces the interval it was judged on.
      void releaseHoldIfPossible() {
        if (!holdWithheld) return;
        final (normalized, _) = _normalizedToLatestReceipt(samples);
        final result = _engine.resolve(normalized);
        if (result == null || holdApplies(result)) return;
        holdWithheld = false;
        fireEarlyExit(result, List<TimeSample>.of(samples));
      }

      // 1. Process samples sequentially via a stream to preserve determinism
      // and prevent race conditions during list mutation. This ensures that
      // outlier filtering and consensus resolution always happen on a consistent
      // snapshot of the sample population.
      streamSub = sampleController.stream.listen((event) {
        if (completer.isCompleted) return;

        final (source, sample) = event;
        // Every branch below is terminal for this source, so the
        // verified-capable tally drops here once rather than at each
        // exit. Reads of it further down are therefore already
        // exclusive of the query being processed. The host leaves only
        // when its last instance has ended, since two instances of one
        // id can be in flight together.
        if (_canProduceVerified(source)) {
          final left = (pendingVerifiedHosts[source.id] ?? 1) - 1;
          if (left <= 0) {
            pendingVerifiedHosts.remove(source.id);
          } else {
            pendingVerifiedHosts[source.id] = left;
          }
        }

        if (sample != null) {
          // Filter samples with negative uncertainty early, before both Marzullo
          // and the anchor reduce. Negative uncertainty indicates clock errors.
          if (sample.uncertaintyMs < 0) {
            rejectedInvalid++;
            _observer?.onSourceFailed(
              sample.sourceId,
              'Sample rejected: negative uncertainty (RTT)',
            );
            pendingQueries--;
            releaseHoldIfPossible();
            if (pendingQueries == 0 && !completer.isCompleted) {
              _finalizeSync(
                samples,
                rejectedInvalid,
                activeSources.length,
                completer,
                completionGuard,
              );
            }
            return;
          }

          samples.add(sample);
          _observer?.onSampleReceived(sample);

          // Adaptive Outlier Filtering: Uses a median-based guard to identify
          // and exclude sources that deviate significantly from the population.
          if (samples.length >= 3) {
            final uncertainties = samples.map((s) => s.uncertaintyMs).toList()
              ..sort();
            final medianU = uncertainties[uncertainties.length ~/ 2];

            // Heuristic: If a sample's uncertainty is > 3x the median, it is
            // likely malicious or experiencing extreme network jitter.
            if (sample.uncertaintyMs > max(medianU * 3, 500)) {
              samples.remove(sample);
              _observer?.onSourceFailed(
                sample.sourceId,
                'Adaptive exclusion: statistical outlier detected',
              );
            }
          }

          final (normalized, refMs) = _normalizedToLatestReceipt(samples);
          final result = _engine.resolve(normalized);
          if (result != null) {
            // Stability Check: Escalates quorum requirements if high variance
            // is detected, ensuring we don't anchor to a jittery consensus.
            final varianceDetected = normalized.any(
              (s) =>
                  (s.interval.midpoint - result.utc.millisecondsSinceEpoch)
                      .abs() >
                  500,
            );
            final requiredStability = varianceDetected ? 3 : 2;

            // Compare intervals relative to the normalization reference:
            // the reference advances as later samples arrive, so the
            // absolute consensus interval shifts by the receipt delta
            // between resolves even when the consensus itself is stable.
            final absoluteInterval = result.interval;
            final relativeInterval = absoluteInterval == null
                ? null
                : TimeInterval(
                    startMs: absoluteInterval.startMs - refMs,
                    endMs: absoluteInterval.endMs - refMs,
                  );
            if (lastStabilityInterval == relativeInterval) {
              stableCount++;
            } else {
              stableCount = 1;
            }
            lastStabilityInterval = relativeInterval;

            // Hold the early exit while a verified reply that could
            // lift this result is still outstanding.
            //
            // A degraded result is non-null, so without this the
            // stability counter can complete the cycle on the first two
            // agreeing replies and publish NtsAuthLevel.none while the
            // third verified query is in flight — a cycle whose
            // verified hosts all answer degrading on response order
            // alone. The floor is what makes that reachable: two
            // agreeing verified samples used to form a truth box, and
            // now they do not.
            //
            // Scoped by [holdApplies] to results that are degraded and
            // to cycles where the floor is still arithmetically within
            // reach, so it costs nothing where the box has already
            // formed, nothing at all to an all-NTP configuration, and
            // nothing to a cycle that has already lost too many
            // verified hosts to close a box. Not a correctness gate:
            // [releaseHoldIfPossible] publishes as soon as the queries
            // it waits on end — with _finalizeSync as the backstop when
            // they were the last outstanding.
            //
            // The flag tracks stability rather than merely accumulating,
            // which is what keeps the release path from becoming a way
            // around this guard: a sample that moves the interval resets
            // [stableCount] and so clears the hold, leaving the cycle to
            // be decided here on a later resolve or by _finalizeSync.
            if (stableCount >= requiredStability) {
              if (holdApplies(result)) {
                holdWithheld = true;
              } else {
                holdWithheld = false;
                fireEarlyExit(result, List<TimeSample>.of(samples));
              }
            } else {
              holdWithheld = false;
            }
          } else {
            // No consensus over the new population at all, so there is
            // nothing stable left to withhold.
            holdWithheld = false;
          }
        }

        pendingQueries--;
        releaseHoldIfPossible();
        if (pendingQueries == 0 && !completer.isCompleted) {
          _finalizeSync(
            samples,
            rejectedInvalid,
            activeSources.length,
            completer,
            completionGuard,
            elapsedMs: swSync.elapsedMilliseconds,
          );
        }
      });

      // 2. Warming barrier: complete every Warmable's warm() before the
      // first timed query is issued, so all queries launch against
      // fully-warmed state (e.g. primed NTS cookie jars) with converged
      // start times. Without the barrier, each source queries the
      // moment its own handshake finishes, and the receipt spread
      // between the fastest and slowest handshake widens the
      // normalization shifts the consensus must absorb. The barrier is
      // a completion gate, not a fixed delay: when handshakes are fast
      // (or already memoized, as after initialize()'s explicit
      // warmAllSources()) it costs nothing. The warmBarrierCap only
      // bounds a pathological hang — _warmHosts() already swallows
      // per-source failures, so on timeout the cycle proceeds and the
      // per-source Phase A warm below covers any laggard.
      //
      // Warms this cycle's own selection rather than re-deriving one,
      // so a probe landing in the tracker before the barrier cannot
      // repartition the inventory underneath it.
      await _warmHosts({
        ...cycleRoles.blocking,
        ...cycleRoles.explorers,
      }).timeout(warmBarrierCap, onTimeout: () {});

      // 3. Launch racing queries.
      //
      // Each source runs a per-source two-phase sequence concurrently
      // with the others:
      //   Phase A — for sources that implement [Warmable], warm() runs
      //     outside the per-query maxLatency budget, so slow handshakes
      //     (e.g., NTS-KE) do not eat into the timed query window.
      //     After the barrier above, warm() is memoized and Phase A is
      //     a no-op for every source the barrier reached; it remains
      //     the JIT fallback for a source whose handshake outlived the
      //     barrier cap. Sources that don't implement Warmable skip
      //     Phase A and proceed straight to the query, so they are not
      //     blocked by slower siblings.
      //   Phase B — _querySafe() runs the timed getTime() under
      //     _config.maxLatency.
      // warm() is wrapped in Future.sync to capture both synchronous
      // and asynchronous throws so a misbehaving source cannot abort
      // its own query (we still proceed to _querySafe) nor the batch.
      for (final source in activeSources) {
        unawaited(() async {
          if (source is Warmable) {
            try {
              await Future.sync(() => (source as Warmable).warm());
            } catch (e) {
              _observer?.onSourceFailed(source.id, 'warm: $e');
            }
          }

          final sample = await _querySafe(source, rescueState);
          if (!streamClosed && !sampleController.isClosed) {
            sampleController.add((source, sample));
          }
        }());
      }

      // 3b. Launch the explorer probes.
      //
      // Deliberately not fed into [sampleController]: an explorer
      // sample must reach neither the Marzullo population nor
      // [pendingQueries]. The first would let a host the ranking has
      // not yet vetted steer the anchor; the second would put the
      // cycle's completion behind a probe whose only product is a
      // ranking update, which is precisely the latency the front-load
      // was buying convergence with.
      //
      // These futures outlive the cycle by design. `sync()` returns on
      // quorum and the probes land in [_qualityTracker] whenever they
      // finish, so a slow explorer costs the next cycle's ranking
      // nothing and this cycle's latency nothing. [explorerTimeout]
      // bounds how long that tail can run.
      _launchExplorerProbes(cycleRoles.explorers);

      // Outer safety timeout. The warming barrier above completes (or
      // caps out) before this deadline starts counting, so the common
      // case consumes none of this budget on handshakes. The 5 s
      // handshake allowance is retained for the residual path where a
      // handshake outlived the barrier cap and Phase A re-awaits the
      // same memoized warm() inside this window. Budget = maxLatency
      // (timed query window) + 5s for that residual NTS-KE completion
      // + 1s for stream processing and consensus resolution overhead.
      final anchor = await completer.future.timeout(
        _config.maxLatency + const Duration(seconds: 6),
        onTimeout: () async {
          // Safety-net path: [completer] was not resolved within the
          // deadline. The per-cycle re-entry guard splits this into two
          // sub-cases that must be handled differently.
          //
          // (1) A sibling _completeSync is already in flight: an
          // early-exit or finalize invocation set guard.inFlight and is
          // awaiting _createAnchor. It owns this cycle's completion — it
          // will record the per-source quality observations and resolve
          // [completer] with the anchor momentarily. Defer to it by
          // returning [completer.future]. Calling _completeSync here
          // would no-op on the guard, and then throwing would discard an
          // anchor that resolves microtasks later (the functional
          // regression flagged in r3369282558). The only way the guard
          // is still in flight this far past the query window is a
          // stalled monotonic _createAnchor read, in which case no path
          // can produce an anchor anyway; we do not trade that reachable
          // discard-a-success regression for an unreachable hang.
          if (completionGuard.inFlight) {
            return completer.future;
          }
          // (2) No completion is in flight: the machinery never resolved
          // [completer], yet enough samples arrived to form a consensus.
          // Drive completion ourselves, routing through [_completeSync]
          // rather than building a raw anchor inline so this path
          // performs the same bookkeeping as the early-exit and finalize
          // paths:
          //  - per-source quality observations are recorded for the
          //    collected samples (flagged against the winning set), so
          //    the advanceCycle() below does not treat sources that
          //    answered this cycle as unqueried — which would otherwise
          //    skew the next cycle's ranking and starvation rescue; and
          //  - [completer] is resolved, so the sample-stream listener
          //    short-circuits instead of running on after sync() returns.
          if (!completer.isCompleted &&
              samples.length >= _config.minimumQuorum) {
            final (normalized, _) = _normalizedToLatestReceipt(samples);
            final result = _engine.resolve(normalized);
            if (result != null) {
              await _completeSync(
                result,
                List<TimeSample>.of(samples),
                swSync.elapsedMilliseconds,
                completer,
                completionGuard,
              );
              // _completeSync resolved [completer] with the anchor (or
              // errored it if _createAnchor threw); surface that same
              // outcome as the timeout result so the returned/raised
              // value and the bookkeeping match the non-timeout paths.
              if (completer.isCompleted) return completer.future;
            }
          }
          throw TrustedTimeSyncException(
            'Synchronization timed out before reaching a stable quorum.',
          );
        },
      );

      _syncAttempts = 0;
      _hasAnchored = true;
      _cache?.update(anchor);
      _qualityTracker.advanceCycle();
      // Decay the front-load alongside the cycle counter, and for the
      // same reason: only a cycle that actually banked an anchor
      // produced the explorer observations the boost exists to gather.
      // Spending it on a failed cycle would let a run of network
      // outages burn the whole front-load having probed nothing.
      //
      // Decaying *here* rather than at host selection is what makes the
      // width stable for the duration of a cycle: [effectiveExplorerBudget]
      // is read once, at selection, and the count it depends on cannot
      // move again until that cycle has completed.
      if (_explorerBoostRemaining > 0) _explorerBoostRemaining--;
      // After the decay, so a change detected on this cycle arms its
      // full width rather than immediately losing a cycle of it.
      _observeVantage(rescueState.ntpSamples);
      return anchor;
    } catch (e) {
      _markSyncFailed(e);
      // The local `completer` has exactly one consumer: the
      // `completer.future.timeout(...)` await at the top of this
      // method. The rethrow below already propagates the error to
      // that awaiter (or to the catch site if the throw happened
      // before we reached the await). Calling completer.completeError
      // here would error a future whose only listener is the derived
      // timeout-wrapped future — which is already done by the time we
      // reach this catch in the timeout / quorum-failure paths —
      // resulting in an unhandled async error that flutter_test's
      // FakeAsync zone surfaces as a test failure. Leaving the
      // completer pending lets it be collected without leaking.
      rethrow;
    } finally {
      streamClosed = true;
      // Cancel the subscription before closing the controller so
      // close() cannot hang waiting on undelivered events. Neither
      // future is awaited: cancellation of a plain listener (no
      // onCancel handler) is synchronous, and the futures returned by
      // cancel()/close() resolve through the shared root-zone
      // `Future._nullFuture` (dart-lang/sdk#40131) — awaiting them
      // schedules root-zone microtasks that fakeAsync can never
      // flush, wedging every sync() cycle under fake-clock tests.
      // The [streamClosed] flag above already guards late adds.
      unawaited(streamSub?.cancel());
      unawaited(sampleController.close());
    }
  }

  Future<void> _completeSync(
    ConsensusResult result,
    List<TimeSample> samples,
    int latencyMs,
    Completer<TrustAnchor> completer,
    _CompletionGuard guard,
  ) async {
    // Synchronous re-entry guard: if the completer is already done OR
    // a sibling _completeSync invocation in *this same cycle* has
    // already started its _createAnchor await, bail before doing any
    // observable work. Both checks must happen together with the
    // [guard] assignment, before the first await, so the second
    // caller observes the in-flight flag set by the first.
    //
    // [guard] is per-cycle (allocated in [sync] and captured by the
    // sample-stream listener), so this guard cannot be reset by an
    // overlapping `sync()` invocation on the same engine instance.
    if (completer.isCompleted || guard.inFlight) return;
    guard.inFlight = true;

    try {
      final anchor = await _createAnchor(result, samples);
      // Defensive re-check after the await: no public path currently
      // completes [completer] while [_createAnchor] is in-flight (the
      // no-quorum branch of [_finalizeSync] is unreachable once
      // early-exit has fired, and the outer timeout wraps
      // [completer.future] rather than the completer itself), but a
      // future code change that introduces such a path would
      // otherwise cause `success` observer events to be emitted for
      // a cycle that ultimately failed. Bail before any observable
      // work if the completer has been resolved (or errored)
      // out-of-band.
      if (completer.isCompleted) return;
      // Winning-set ids, shared by the consensus attribution log below
      // and the per-source quality bookkeeping further down.
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
      if (TrustedTimeLog.enabled) {
        // Cross-source receipt spread at consensus time: how far apart
        // (on the monotonic receipt timeline) the population's samples
        // arrived, i.e. the exact shift _normalizedToLatestReceipt
        // absorbed for this resolve. `n/m` counts samples carrying a
        // receipt stamp out of the population.
        final receipts = samples
            .map((s) => s.receivedAtMs)
            .whereType<int>()
            .toList(growable: false);
        final spread = receipts.isEmpty
            ? 'n/a'
            : '${receipts.reduce(max) - receipts.reduce(min)}ms';
        // Attribution: which of the collected population the anchor is
        // actually standing on (won) versus which entered consensus but
        // were filtered by Marzullo / the tier truth box (rejected).
        // Both lists are sorted (and rejected de-duplicated) so the
        // structured line is stable for log parsers and tests.
        final truthBoxDropped = result.droppedOutsideTruthBox
            .map((s) => s.sourceId)
            .toSet();
        final won = participantIds.toList()..sort();
        final rejected = <String>{
          for (final s in samples)
            if (!participantIds.contains(s.sourceId))
              truthBoxDropped.contains(s.sourceId)
                  ? '${s.sourceId} (outside truth box)'
                  : '${s.sourceId} (outlier)',
        }.toList()..sort();
        TrustedTimeLog.log(
          TrustedTimeLogLevel.debug,
          '[TrustedTime] consensus won=[${won.join(', ')}] '
          'rejected=[${rejected.join(', ')}] '
          'receiptSpread=$spread '
          '(${receipts.length}/${samples.length} stamped) '
          'authLevel=${result.authLevel.name}',
        );
      }
      _observer?.onConsensusReached(result);

      // Tier-aware admission bookkeeping. A degraded cycle (no Tier 1
      // truth box) mints an authLevel-none anchor, which the assessment
      // API surfaces as TrustStatusReason.degraded; lower-tier samples
      // dropped for falling outside the truth box are surfaced as
      // per-source failures for telemetry.
      if (result.degradedTier) {
        // Without this log line, a cycle that minted an authLevel-none
        // anchor looks identical to a fully-verified success in the
        // logs, and the degradation only surfaces later where the
        // consumer inspects an assessment — far from the cycle that
        // caused it.
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] anchor DEGRADED: consensus reached without a '
          'verified-NTS quorum; authLevel=none. Assessments will report '
          'TrustStatusReason.degraded until a verified anchor is minted.',
        );
      }
      for (final dropped in result.droppedOutsideTruthBox) {
        _observer?.onSourceFailed(dropped.sourceId, 'tier2: outside truth box');
      }

      // Record one quality observation per source that returned a sample
      // this cycle, flagging whether it landed in the consensus winning
      // set. Iterating the full collected `samples` population (not just
      // `result.participants`) is what lets the tracker tell a
      // consistently-rejected source apart from a consistently-agreeing
      // one; looping participants alone pins every participation rate at
      // 1.0 because every iterated sample is a participant by definition.
      final recorded = <String>{};
      for (final sample in samples) {
        if (!recorded.add(sample.sourceId)) continue;
        _qualityTracker.record(
          sourceId: sample.sourceId,
          uncertaintyMs: sample.uncertaintyMs,
          participatedInConsensus: participantIds.contains(sample.sourceId),
          delayMs: sample.delayMs,
          jitterMs: sample.jitterMs,
        );
      }

      // Denominator for the coverage ratios below: the sources this
      // cycle was allowed to query, not the whole materialised pool.
      // Both inventories are partitioned per cycle, so dividing by the
      // full 108-host pool (51 NTP + 57 NTS) would report a healthy
      // quorum as a fraction of hosts the cycle never intended to
      // contact, and the ratio would drift with inventory size rather
      // than with consensus quality.
      //
      // Read off [guard] rather than an engine field so the count
      // belongs to *this* cycle: two `sync()` invocations that slip
      // past the public-API coalescer each own a guard, whereas a
      // shared field would let the later selection retroactively
      // rebase the earlier cycle's ratios.
      //
      // The pool fallback is defensive only: `_runSyncCycle` sets the
      // count immediately after selecting the host set, which precedes
      // every path that can reach here. It keeps a future reordering
      // from silently dividing by zero.
      final cycleSourceCount = guard.cycleHostCount ?? _sources.length;

      _observer?.onMetricsReported(
        SyncMetrics(
          latencyMs: latencyMs,
          uncertaintyMs: result.uncertaintyMs,
          participantCount: result.participantCount,
          quorumDepth: result.quorumDepth,
          groupCount: result.groupCount,
          confidence: result.confidence,
          confidenceBreakdown: {
            // Both 'depth' and 'quorumDepth' are coarse "fraction of
            // the configured source pool that participated" ratios,
            // not the engine's actual quorum-floor comparison. The
            // engine's quorum check is `quorumDepth >= ceil(eligible *
            // minQuorumRatio)`, where `eligible` is the per-cycle
            // count of valid samples (which can be smaller than the
            // configured pool when sources are cooled down or fail to
            // produce a sample). Neither ratio surfaces `eligible`,
            // so they cannot reproduce the engine's quorum-floor
            // decision; consumers that need quorum-floor reasoning
            // should key off the raw integer SyncMetrics.quorumDepth
            // field instead.
            //
            // 'depth' preserves the historical participantCount-based
            // ratio for backward compatibility with existing
            // dashboards. 'quorumDepth' is the additive companion
            // showing the same coarse ratio computed from the
            // sweep-depth integer rather than the midpoint-containment
            // integer; the two diverge under the same conditions
            // documented on ConsensusResult.participantCount.
            'depth': result.participantCount / cycleSourceCount,
            'quorumDepth': result.quorumDepth / cycleSourceCount,
            'diversity': result.groupCount / 2.0,
            'stability': 1.0,
            // Fraction of the configured source pool that contributed a
            // Tier 1 (verified) sample to the published consensus winning
            // set (participants containing the consensus window's
            // midpoint, the engine's structural anchor). 0.0 when no
            // verified sample contained that midpoint; can be
            // low-but-positive on a degraded cycle when verified samples
            // contained the fallback window's midpoint without having
            // formed a truth box. Read alongside degradedTier, not as a
            // degradation discriminant on its own.
            'tier1Quorum': cycleSourceCount == 0
                ? 0.0
                : result.participants
                          .where((s) => s.authLevel == NtsAuthLevel.verified)
                          .length /
                      cycleSourceCount,
          },
        ),
      );

      if (!completer.isCompleted) completer.complete(anchor);
    } catch (e) {
      // Unlike the redundant `completer.completeError(e)` removed from
      // sync()'s catch block, this one is the *only* path that
      // propagates the failure to the awaiter. _completeSync runs
      // inside the per-source pipeline (via the unawaited fan-out at
      // sync() line ~268 → sample stream listener → _completeSync),
      // so any throw here happens on a future the awaiter never sees
      // directly — the only listener is sync()'s
      // `completer.future.timeout(...)`. Without this completeError,
      // a failure inside _createAnchor (e.g., monotonic clock channel
      // throws, or the consensus result has no participant samples)
      // would be swallowed and sync() would block until its outer
      // timeout fires, masking the real cause behind a generic
      // 'Synchronization timed out' message.
      if (!completer.isCompleted) completer.completeError(e);
    }
  }

  Future<TrustAnchor> _createAnchor(
    ConsensusResult result,
    List<TimeSample> samples,
  ) async {
    // Anchor selection validates that consensus has participant samples.
    // This prevents outliers from corrupting the monotonic clock reference.
    final participantSamples = result.participants;
    if (participantSamples.isEmpty) {
      // Structural invariant violation, not network weather: a retry of
      // the same cycle would produce the same empty participant set.
      throw const TrustedTimeSyncException(
        'Consensus result has no participant samples',
        transient: false,
      );
    }

    // Stamp the boot-session identity so warm restore can compare it
    // against the device's current boot ID. Null when the platform
    // cannot supply one, in which case warm restore fails closed.
    // Read *before* the clock readings below: bootId is a
    // platform-channel round trip whose latency must not fall between
    // the uptime reading and the age measurement, or it would be
    // subtracted from an uptime it never aged (over-backdating).
    final bootId = await _clock.getBootId();
    final uptimeMs = await _clock.uptimeMs();
    final wallMs = DateTime.now().millisecondsSinceEpoch;
    // Age reference stamp, taken synchronously right after the readings
    // it corrects so the interval [receipt reference → this stamp]
    // brackets uptimeMs/wallMs as tightly as possible. Only the
    // uptimeMs channel-return latency remains inside the measurement.
    final currentReceiptMs = TimeSample.monotonicReceiptNowMs();

    // Backdate the anchor readings to the consensus reference instant.
    // The consensus UTC estimates the true time at the normalization
    // reference (the latest receipt stamp, which every normalized
    // participant carries after normalizedTo), while uptimeMs / wallMs
    // above were read moments *later* — after stream processing,
    // consensus resolution, and the awaits. Left uncorrected, that
    // age is baked into the anchor as permanent skew: projection pairs
    // an older UTC with younger clock readings. Subtracting the age
    // makes all three anchor fields describe the same instant.
    //
    // The age is measured on the receipt timeline and accepted only
    // within (0, min(maxLatency, uptimeMs)]: negative ages cannot
    // arise from real stamps (receipts precede anchor creation) but
    // do arise from synthetic fixture stamps on an unrelated scale,
    // an age beyond the whole query budget likewise indicates stamps
    // this arithmetic must not trust, and an age exceeding the device
    // uptime would backdate the anchor to before boot — impossible on
    // a real device (the receipt timeline starts after process start,
    // which starts after boot) and a violation of the "ms since boot"
    // invariant on uptimeMs. All degenerate cases fall back to the
    // pre-existing behaviour (no backdating) rather than corrupting
    // the anchor.
    int? refMs;
    for (final s in participantSamples) {
      final r = s.receivedAtMs;
      if (r != null && (refMs == null || r > refMs)) refMs = r;
    }
    var ageMs = 0;
    if (refMs != null) {
      final rawAge = currentReceiptMs - refMs;
      if (rawAge > 0 &&
          rawAge <= _config.maxLatency.inMilliseconds &&
          rawAge <= uptimeMs) {
        ageMs = rawAge;
      }
    }

    // Contributor telemetry: one record per collected sample —
    // winners and losers alike — so the anchor documents who produced
    // it and how each source performed. Built from the raw (pre-
    // normalization) population handed to _completeSync, so rttMs is
    // the delay actually measured; wonConsensus is attributed by
    // sourceId against the winning set. Samples without a measured
    // delay (custom sources, legacy fixtures) fall back to the
    // interval width (2 × uncertainty ≈ RTT), mirroring the reducer's
    // key so the recorded value stays in delay units.
    final participantIds = result.participants.map((s) => s.sourceId).toSet();
    final contributors = [
      for (final s in samples)
        TrustAnchorContributor(
          sourceId: s.sourceId,
          groupId: s.groupId,
          rttMs: s.delayMs ?? 2 * s.uncertaintyMs,
          dispersionMs: s.dispersionMs,
          authLevel: s.authLevel,
          wonConsensus: participantIds.contains(s.sourceId),
          stratum: s.stratum,
          jitterMs: s.jitterMs,
        ),
    ];

    return TrustAnchor(
      networkUtcMs: result.utc.millisecondsSinceEpoch,
      uptimeMs: uptimeMs - ageMs,
      wallMs: wallMs - ageMs,
      uncertaintyMs: result.uncertaintyMs,
      authLevel: result.authLevel,
      confidence: result.confidence,
      bootId: bootId,
      contributors: contributors,
    );
  }

  /// Finalizes synchronization when all queries complete.
  void _finalizeSync(
    List<TimeSample> samples,
    int rejectedInvalid,
    int totalSources,
    Completer<TrustAnchor> completer,
    _CompletionGuard guard, {
    int? elapsedMs,
  }) {
    if (completer.isCompleted) return;

    // All sources responded but we haven't reached stability.
    // Try one final resolve with all samples before failing.
    final (normalized, _) = _normalizedToLatestReceipt(samples);
    final finalResult = _engine.resolve(normalized);
    if (finalResult != null && samples.length >= _config.minimumQuorum) {
      unawaited(
        _completeSync(finalResult, samples, elapsedMs ?? 0, completer, guard),
      );
    } else {
      // Improved quorum-failure messaging with accurate counts
      final eligibleCount = samples.length;
      final sampleWord = eligibleCount == 1 ? 'sample' : 'samples';
      final rejectedWord = rejectedInvalid == 1 ? 'source was' : 'sources were';

      completer.completeError(
        TrustedTimeSyncException(
          'Failed to reach quorum: got $eligibleCount eligible $sampleWord '
          '($rejectedInvalid $rejectedWord rejected as invalid) from $totalSources total sources.',
        ),
      );
    }
  }

  /// Shifts every sample carrying a receipt timestamp so all intervals
  /// estimate the true time at one shared reference instant — the
  /// latest receipt in the population — before Marzullo intersection.
  ///
  /// Each sample's interval brackets the true time *at its own receipt
  /// instant*. When a cycle's queries complete seconds apart (typical
  /// on a just-woken radio, where the first responses ride a stalling
  /// link), intersecting the raw intervals under-counts overlap by
  /// exactly the receipt spread: two perfect ±50 ms samples received
  /// 3 s apart share no overlap at all and read as disagreeing
  /// sources. Normalizing to a common instant removes that artificial
  /// disagreement while leaving genuinely conflicting sources apart.
  ///
  /// The latest receipt is chosen (rather than the earliest) so the
  /// consensus midpoint stays as close as possible to the
  /// anchor-creation instant that [_createAnchor] pairs it with.
  /// Samples without a receipt timestamp (legacy fixtures, custom
  /// sources) pass through unshifted, preserving existing behaviour.
  ///
  /// Returns the normalized population together with the reference
  /// instant used (`0` when no sample carried a receipt timestamp, in
  /// which case the population is returned as-is). Callers that
  /// compare successive consensus intervals for stability must
  /// translate them by `-refMs` first: the reference advances as new
  /// samples arrive, so absolute intervals shift between resolves even
  /// when the underlying consensus is unchanged.
  (List<TimeSample>, int) _normalizedToLatestReceipt(List<TimeSample> samples) {
    int? refMs;
    for (final s in samples) {
      final r = s.receivedAtMs;
      if (r != null && (refMs == null || r > refMs)) refMs = r;
    }
    if (refMs == null) return (samples, 0);
    final ref = refMs;
    return (
      samples.map((s) => s.normalizedTo(ref)).toList(growable: false),
      ref,
    );
  }

  /// One structured `sample <id> ok|fail` line per source per query,
  /// symmetric across source kinds (NTP, NTS, additional) so
  /// "is NTP working?" is answerable from the log stream directly
  /// rather than by subtracting NTS burst counts from consensus totals.
  void _logSample(TimeSample sample) {
    if (!TrustedTimeLog.enabled) return;
    // Approximate server-vs-local offset at receipt; diagnostic only.
    final offsetMs =
        sample.utc.millisecondsSinceEpoch -
        DateTime.now().toUtc().millisecondsSinceEpoch;
    final sign = offsetMs < 0 ? '' : '+';
    final rtt = sample.delayMs == null ? 'n/a' : '${sample.delayMs}ms';
    TrustedTimeLog.log(
      TrustedTimeLogLevel.debug,
      '[TrustedTime] sample ${sample.sourceId} ok rtt=$rtt '
      'offset=$sign${offsetMs}ms u=${sample.uncertaintyMs}ms '
      'authLevel=${sample.authLevel.name}',
    );
  }

  /// Failure counterpart of [_logSample].
  void _logSampleFailure(String sourceId, Object reason) {
    if (!TrustedTimeLog.enabled) return;
    TrustedTimeLog.log(
      TrustedTimeLogLevel.info,
      '[TrustedTime] sample $sourceId fail reason=$reason',
    );
  }

  /// Fires this cycle's explorer probes without gating the cycle.
  ///
  /// Runs outside the cycle's stream entirely: a probe result reaches
  /// [_qualityTracker] and nothing else. Failures decay the durable
  /// success rate exactly as a blocking failure would, because a host
  /// that will not answer is a host the ranking should defer — but
  /// they take no part in the cooldown ladder here, since
  /// [_querySafe]'s blacklisting exists to keep a bad source out of
  /// consensus and an explorer was never in it.
  void _launchExplorerProbes(Set<String> explorerIds) {
    if (explorerIds.isEmpty) return;
    // First-seen wins for a colliding id, matching the blocking path's
    // healthyById dedup. Without it a shadowed inventory host would be
    // probed once per instance and its durable stats updated twice from
    // what the ranking treats as a single source.
    final byId = <String, TimeSource>{};
    for (final s in _sources) {
      if (explorerIds.contains(s.id)) byId.putIfAbsent(s.id, () => s);
    }
    for (final source in byId.values) {
      unawaited(() async {
        try {
          final sample = await source.getTime().timeout(explorerTimeout);
          _logSample(sample);
          _qualityTracker.recordProbe(
            sourceId: source.id,
            delayMs: sample.delayMs,
            jitterMs: sample.jitterMs,
          );
          final stratum = sample.stratum;
          if (stratum != null) _qualityTracker.setStratum(source.id, stratum);
        } catch (e) {
          _logSampleFailure(source.id, e);
          _qualityTracker.recordFailure(source.id);
        }
      }());
    }
  }

  /// Folds this cycle's anycast round trips into the vantage baseline
  /// and, on an epoch change, restarts exploration from the new
  /// vantage.
  ///
  /// Fed from [samples] — the blocking population, which is where the
  /// anycast quorum lands — rather than from the explorer probes, whose
  /// hosts are unicast and so measure the server's position rather than
  /// the caller's. A sample without a measured round trip is skipped
  /// rather than approximated from the interval half-width: the
  /// half-width carries server-side dispersion too, so mixing the two
  /// would let a source's uncertainty estimate read as a move.
  ///
  /// The caller passes the cycle's accumulated queries rather than the
  /// consensus population, which is a wider set by two kinds of sample:
  /// one that returned after the anchor was banked, and one the
  /// listener dropped as an outlier or as invalid. Neither says
  /// anything about the anchor, and both are round trips the device
  /// actually measured — which hosts agreed is the wrong question here,
  /// since the measurement is of the network, not of the agreement.
  ///
  /// It is not the full response set. The cycle ends when the completer
  /// resolves, and under [TrustedTimeConfig.earlyExit] that is before
  /// the slow half has answered, so a query still in flight at that
  /// instant is missing here as well. The residual bias is toward the
  /// fast tail, and where fewer than three anycast hosts have answered
  /// by then the cycle is simply unobservable and [VantageBaseline]
  /// leaves the baseline untouched — the detector runs late rather than
  /// wrong. Waiting for the stragglers would put the baseline behind
  /// the slowest source in the inventory, which is the latency early
  /// exit exists to avoid paying, and this detector is not worth it.
  ///
  /// One round trip per host, first answer winning, on the same
  /// first-seen rule the blocking path's `healthyById` and
  /// [_launchExplorerProbes] already dedup a colliding id by. A cycle
  /// can query one id twice — two sources sharing it are collapsed
  /// while both are healthy, but the starvation rescue re-admits from
  /// [_sources] directly, so a blacklisted id backed by two instances
  /// is queried once per instance. The floor is what makes that worth
  /// guarding rather than the median: [VantageBaseline] counts
  /// responders to decide whether a cycle is observable at all, and a
  /// duplicate would let two hosts clear a bar set at three.
  ///
  /// The response keys off the epoch, not off any individual reading:
  /// the baseline debounces internally, so by the time the epoch
  /// advances the shift has already been sustained.
  void _observeVantage(Iterable<TimeSample> samples) {
    final byHost = <String, int>{};
    for (final s in samples) {
      final rtt = s.delayMs;
      if (rtt == null || !_anycastIds.contains(s.sourceId)) continue;
      byHost.putIfAbsent(s.sourceId, () => rtt);
    }
    final rtts = byHost.values;
    if (rtts.isEmpty) return;

    final previous = _vantageBaseline;
    _vantageBaseline = previous.observe(rtts);
    if (_vantageBaseline.epoch == previous.epoch) return;

    if (TrustedTimeLog.enabled) {
      TrustedTimeLog.log(
        TrustedTimeLogLevel.info,
        '[TrustedTime] vantage change detected: anycast baseline moved '
        '${previous.ewmaRttMs?.round()}ms -> '
        '${_vantageBaseline.ewmaRttMs?.round()}ms '
        '(epoch ${_vantageBaseline.epoch}). Re-exploring the inventory.',
      );
    }
    // Both halves of the recovery. The marking returns every source to
    // the unprobed end of the walk; the boost widens the walk, so the
    // sweep it just queued completes in a handful of cycles rather than
    // the dozen-plus a narrow platform budget would take.
    _qualityTracker.markVantageStale();
    armExplorerBoost(explorerBoostCycles);
  }

  /// Wraps a source query with timeout and health-tracking logic.
  ///
  /// [rescueState] is the invoking cycle's rescue bookkeeping holder;
  /// NTP samples and cert-validity failure signatures observed here
  /// are recorded into it, never into engine-scoped state.
  Future<TimeSample?> _querySafe(
    TimeSource source,
    _CycleRescueState rescueState,
  ) async {
    try {
      final sample = await source.getTime().timeout(_config.maxLatency);
      _sourceHealth[source.id] = 0; // Reset failure count on success
      _sourceTransientStreak.remove(source.id);
      _blacklistUntil.remove(source.id);
      // Latch here rather than leaving it to the end-of-cycle
      // bookkeeping in _completeSync, which only sees the samples that
      // arrived in time to be folded in. A cycle can exit early on
      // quorum, and this sample may be discarded; that the host
      // answered is true either way, and NTS promotion turns on it.
      // Latch-only, so the EWMAs are still applied exactly once, by
      // whichever of record/recordProbe owns this source's path.
      _qualityTracker.markSucceeded(source.id);
      // Retain NTP samples for the pre-sync rescue: if this cycle ends
      // up failing on an NTS cert-validity deadlock, the rescue reuses
      // these as its coarse estimate without a second round trip.
      if (source.id.startsWith(TimeSource.prefixNtp)) {
        rescueState.ntpSamples.add(sample);
      }
      _logSample(sample);
      return sample;
    } on TransientSourceError catch (e) {
      // Source classified the failure as transient (e.g. NtsSource saw
      // NtsError.timeout(TimeoutPhase.dnsSaturation): the DNS resolver
      // pool was momentarily full). Notify the observer and skip the
      // exponential cooldown — the next sync cycle is expected to
      // succeed once contention clears.
      //
      // A genuinely transient condition resolves within a cycle or
      // two; a "transient" condition that persists across many cycles
      // is indistinguishable from a sustained outage and should be
      // treated like one. Once the consecutive-streak counter reaches
      // [TrustedTimeConfig.transientStreakThreshold], promote the
      // failure to the regular cooldown ladder so the host gets
      // exponential backoff and surfaces as unhealthy through the
      // standard `_blacklistUntil` path.
      _logSampleFailure(source.id, e);
      _observer?.onSourceFailed(source.id, e);
      // The source was actually queried this cycle (it just failed
      // transiently), so refresh its last-queried cycle for starvation
      // accounting. Without this, a source later escalated to cooldown via
      // the streak path would carry no recorded query, so isStarved() would
      // treat it as never-queried and the starvation rescue would re-admit
      // it on the very next cycle, defeating the cooldown it just entered.
      _qualityTracker.recordFailure(source.id);
      final threshold = _config.transientStreakThreshold;
      // threshold <= 0 disables escalation entirely; skip the streak
      // bookkeeping so the map cannot accumulate unbounded entries
      // for a source that the caller has explicitly opted out of
      // ever escalating.
      if (threshold > 0) {
        final streak = (_sourceTransientStreak[source.id] ?? 0) + 1;
        _sourceTransientStreak[source.id] = streak;
        if (streak >= threshold) {
          _armCooldown(source.id);
        }
      }
      return null;
    } catch (e) {
      _logSampleFailure(source.id, e);
      _observer?.onSourceFailed(source.id, e);
      // Cert-validity signature detection for the pre-sync rescue:
      // only meaningful on NTS sources (the deadlock is an NTS-KE TLS
      // condition), and only consulted when the whole cycle fails on
      // a cold start.
      if (source.id.startsWith(TimeSource.prefixNts) &&
          isCertValidityFailure(e)) {
        rescueState.certValidityFailedIds.add(source.id);
      }
      // Record the failure against the quality score *before*
      // arming the cooldown so the tracker sees the failed
      // observation even if subsequent cycles never query this
      // source again (cooldown could keep it out for a while).
      // _armCooldown is our centralised helper (added in our
      // wy3 / cooldown work) that the transient-streak path
      // also reuses; upstream inlined the cooldown bookkeeping
      // here, but the centralised form is the load-bearing
      // shape on this fork.
      _qualityTracker.recordFailure(source.id);
      _armCooldown(source.id);
      return null;
    }
  }

  /// Increments [sourceId]'s failure score and arms the exponential
  /// `2^min(score, 6)`-minute cooldown via `_blacklistUntil`. Drops any
  /// accumulated transient-streak entry because the source is now on
  /// the regular cooldown ladder; the streak is only meaningful for
  /// sources currently outside cooldown.
  ///
  /// The score is incremented (not reset) so a source that already
  /// accrued unrecovered failure score before this call — for example,
  /// a regular failure that armed a short cooldown which has since
  /// expired, followed by a transient streak that escalated here — is
  /// treated as exhibiting cumulative unhealthiness and progresses
  /// further along the cooldown ladder rather than silently restarting
  /// at the bottom rung (`2^1 = 2` minutes) every time.
  void _armCooldown(String sourceId) {
    _sourceTransientStreak.remove(sourceId);
    final score = (_sourceHealth[sourceId] ?? 0) + 1;
    _sourceHealth[sourceId] = score;
    final cooldownMin = pow(2, min(score, 6)).toInt();
    _blacklistUntil[sourceId] = DateTime.now().add(
      Duration(minutes: cooldownMin),
    );
  }

  /// Records a failed sync cycle: notifies the observer and bumps the
  /// exponential-backoff attempt counter. Centralised so the early-bail
  /// empty-pool path and the main try/catch path stay in lockstep — any
  /// future addition (e.g. metrics, structured logging) only needs to
  /// land here.
  void _markSyncFailed(Object error) {
    _observer?.onSyncFailed(error);
    _syncAttempts++;
  }

  /// Calculates the next retry delay for the entire engine.
  Duration getNextRetryDelay() {
    if (_syncAttempts == 0) return Duration.zero;
    final exponent = min(_syncAttempts, 8);
    final seconds = pow(2, exponent).toInt();
    return Duration(seconds: seconds);
  }

  /// Releases network and platform resources.
  ///
  /// Currently a no-op: none of the built-in sources (NTP, NTS) hold
  /// engine-owned resources that outlive a query. Retained so the
  /// owning [TrustedTime] implementation has a stable teardown hook.
  void dispose() {}
}

/// Per-cycle synchronous re-entry guard for [SyncEngine._completeSync].
///
/// Allocated fresh at the top of each [SyncEngine.sync] call and
/// captured by the sample-stream listener closure, so the guard's
/// lifetime is exactly one sync cycle. Both `_completeSync` call
/// sites in the listener (the early-exit path and the
/// finalize-via-`_finalizeSync` path) receive the same instance, so
/// the second invocation observes [inFlight] set by the first and
/// bails before any observable work — exactly like an engine-instance
/// `bool` flag would, but without the cross-cycle reset hazard:
/// overlapping `sync()` invocations on the same engine instance each
/// own a distinct guard and cannot reset each other's state.
///
/// Also carries [cycleHostCount], for the same reason: the telemetry
/// denominators are computed deep in the completion path, and an
/// engine-scoped field would let one cycle's host set be divided into
/// another's sample counts.
class _CompletionGuard {
  bool inFlight = false;

  /// How many sources this cycle was allowed to query.
  ///
  /// Set once, immediately after the cycle's host set is selected, and
  /// read by `_completeSync` as the coverage-ratio denominator. Null
  /// only before selection has run.
  int? cycleHostCount;
}

/// Per-cycle bookkeeping for the pre-sync rescue.
///
/// Allocated fresh at the top of each [SyncEngine.sync] call and
/// threaded through `_runSyncCycle` into `_querySafe`, following the
/// same cycle-scoped pattern as [_CompletionGuard]: overlapping
/// `sync()` invocations each own a distinct holder, so one cycle
/// cannot clear or pollute another's rescue evidence. (Engine-scoped
/// collections with a top-of-`sync()` reset would race exactly that
/// way — one cycle clearing while another populates — skipping or
/// mis-arming the rescue and consuming the one-shot latch
/// unpredictably.)
class _CycleRescueState {
  /// NTS source ids whose failure this cycle carried a certificate
  /// validity-window signature. Populated by `_querySafe`; consulted
  /// by [SyncEngine.sync] only after the cycle fails.
  final certValidityFailedIds = <String>{};

  /// NTP samples collected during this cycle, retained so a rescue
  /// triggered by the cycle's failure can reuse them as its coarse
  /// estimate without a second network round trip.
  ///
  /// Also the vantage baseline's population, for the property that
  /// motivated the list in the first place: it accumulates on the query
  /// returning rather than on the consensus being built from it, so it
  /// retains the late and the rejected alike. It is not a record of the
  /// whole cycle — [SyncEngine._observeVantage] reads it the moment the
  /// anchor is banked, and under early exit that is before every query
  /// has landed.
  final ntpSamples = <TimeSample>[];
}
