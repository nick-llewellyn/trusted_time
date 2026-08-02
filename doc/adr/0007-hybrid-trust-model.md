# ADR 0007: NTS-anchored hybrid trust model with admission-gated NTP and HTTPS tiers

- Status: **Accepted**
- Date: 2026-05-13
- Tracking issue: `trusted_time-26p`
- Supersedes: portions of ADR 0003 §"Decision" that removed
  `NtpSource`, `TrustedTimeConfig.ntpServers`, `TimeSourceKind.ntp`,
  and the `package:ntp` dependency. The 2026-05-09 stress run
  produced new evidence (structural APAC/Africa/ME gap in NTS-KE
  deployment) that the original ADR did not have. NTP is reinstated
  as a precision contributor, constrained by admission gating against
  an NTS-defined truth box rather than freely admitted to consensus.
- Depends on: ADR 0001 (NTS as the integrity-anchored source kind),
  ADR 0006 (establish/validate cadence — the truth box's recompute
  schedule)
- Composition: `trusted_time-cuq` (unified DNS/TLS budget — caps tier
  sizes), `trusted_time-wy3` (burst sampling — tightens NTS interval,
  indirectly tightens the truth box)

## Context

The 2026-05-09 stress run (~80 NTS hosts, Pixel Tablet, ~62 min)
confirmed what the public NTS landscape already implied: NTS-KE
deployment is concentrated in EU/NA, with effectively zero coverage
in APAC, Africa, and the Middle East. Direct probing of plausible
candidates (PublicNTP fleet, VNIIFTRI, MSK-IX, MSL NZ, NICT,
ae.pool.ntp.org) confirmed none currently serve NTS-KE on TCP/4460.
The geographic gap is structural and will not close on a quarterly
cadence.

This invalidates the underlying assumption of ADR 0003 (that removing
clear-text NTP would not materially harm coverage because the NTS
quorum could carry the package globally). A pure-NTS architecture
cannot deliver high-integrity time globally; a pure-NTP architecture
delivers no integrity at all; a pure-HTTPS architecture is CA-anchored
sanity at second resolution only.

The current `MarzulloEngine.resolve()`
(`lib/src/domain/marzullo_engine.dart:133`) treats all `TimeSample`
inputs uniformly — there is no concept of a tier or an admission gate.
`TimeSample` already carries an `authLevel` field
(`lib/src/domain/time_sample.dart:28`) that is `NtsAuthLevel.none`
for non-NTS samples, so the discrimination signal exists; what is
missing is the structural gate that uses it.

## Decision

Adopt a tiered hybrid trust model where a small NTS quorum defines a
**truth box** and high-precision NTP / high-availability HTTPS samples
are admitted to Marzullo consensus only if they intersect that box.

| Tier | Default size | Role | Admission rule |
|---|---|---|---|
| **NTS** | 3–5 hosts | Cryptographic quorum; defines the truth box | Always admitted to its own quorum |
| **NTP** | 6–10 hosts (incl. NTP Pool) | Precision contributors with global geographic reach | Sample admitted iff its `TimeInterval` intersects the NTS truth box |
| **HTTPS** | 3–5 hosts | CA-anchored backstop, globally available | Same admission rule as NTP |

The truth box is the Marzullo intersection of the NTS quorum samples
(itself a `TimeInterval`). No additional slack is added — the box's
width tracks the NTS quorum's natural tightness, which `wy3`
burst-sampling will further reduce.

### Answers to the 26p open questions

1. **Truth-box width — the NTS quorum's Marzullo intersection itself,
   no added slack.** Slack is a magic number that has to be defended
   on each calibration; the NTS Marzullo intersection is already the
   smallest interval that the NTS quorum agrees on, so any sample
   intersecting it is consistent with at least one NTS witness within
   that witness's own RTT-bounded uncertainty. As `wy3` tightens
   per-sample NTS uncertainty, the truth box tightens proportionally
   without further policy change.

2. **Quorum failure mode — fall back to NTP-only Marzullo, but cap
   `confidence` at `ConfidenceLevel.low` and emit an
   `IntegrityEvent` of a new `degradedTier` reason.** Refusing to
   publish an anchor when fewer than 2 NTS sources respond would
   leave APAC/Africa/ME callers without a usable anchor at all —
   precisely the failure mode this ADR exists to address. Capping
   confidence preserves the integrity story: callers who require
   high-confidence anchors for security-critical paths see the
   degradation immediately and can react. The new `degradedTier`
   reason is observable through the existing
   `TrustedTime.onIntegrityLost` stream
   (`lib/src/trusted_time_impl.dart:147`).

3. **Admission scoring — binary in/out, not weighted.** A poisoned
   NTP sample either intersects the NTS truth box (in which case it
   is constrained to the box's bounds and contributes precision
   within those bounds) or it is rejected entirely. Weighted scoring
   gives a non-zero influence to out-of-box samples, which weakens
   the security argument for admission gating without a measured
   benefit. A weighted variant remains a possible later refinement
   if `wy3` data shows binary rejection discards meaningful precision
   from legitimate but jittery sources.

4. **Group diversity for NTP/HTTPS tiers — yes, enforce the same
   `minGroupCount` constraint already applied to the NTS tier
   (`lib/src/models.dart:68`, default 2).** For HTTPS, the existing
   per-source `groupId` derivation (apex domain) is sufficient. For
   NTP, the current host-based heuristic
   (`lib/src/sources/ntp_source_io.dart:17-25` — second-level domain,
   with `pool.ntp.org` special-cased to the literal string
   `ntp-pool`) is too coarse for the precision tier: every
   `*.pool.ntp.org` entry collapses to a single `ntp-pool` group
   regardless of the geographically dispersed ASNs the pool actually
   resolves to, so `minGroupCount = 2` cannot be satisfied by NTP
   Pool alone. The implementation must derive the NTP tier `groupId`
   from the resolved IP's ASN at sample time (best-effort; falls
   back to the existing host-based heuristic when ASN lookup is
   unavailable).

5. **Per-cycle vs per-anchor — per-Establish (i.e., the truth box is
   recomputed during the Establish cycle defined by ADR 0006 and
   persists through the Validate window).** Recomputing the truth
   box every cycle would burn NTS handshakes at the Validate cadence
   (1h on `tieredMobile`), defeating the cost reduction ADR 0006
   accepted. Persisting through the Validate window composes
   directly with ADR 0006's establish/validate split: Establish
   recomputes the box, Validate confirms a single fresh sample is
   still in-box, integrity-monitor events trigger an out-of-cycle
   recompute.

## Consequences

### Positive

- Closes the geographic gap by giving APAC/Africa/ME callers
  globally-available NTP precision while keeping the integrity
  guarantee anchored to the NTS quorum where one exists.
- Composes directly with ADR 0006: the establish/validate scheduling
  boundary is also the truth-box recompute boundary.
- Reuses `TimeSample.authLevel` as the tier discriminant — no new
  field on `TimeSample`; the only new state is the truth box itself
  on the `SyncEngine`.
- The fallback-with-degraded-confidence mode preserves the
  high-integrity story (callers can still distinguish authenticated
  vs degraded anchors via `confidenceScore`) without leaving
  low-coverage regions unserved.

### Negative

- Reverses ADR 0003's removal of `package:ntp` and friends. The fork
  carries a clear-text NTP dependency through 2.x. The mitigating
  difference from ADR 0003's pre-context: NTP samples are now
  admission-gated by the NTS truth box rather than freely admitted.
- `MarzulloEngine` gains a tier-aware admission step before the
  existing endpoint-sweep. Test surface grows: every existing
  consensus test must be exercised in both "NTS quorum present" and
  "NTS fallback (degradedTier)" modes.
- Best-effort ASN-based `groupId` for NTP introduces a network
  dependency on a separate IP-to-ASN lookup. Implementation must
  cache aggressively (per-cycle is sufficient) and tolerate lookup
  failure gracefully (fall back to the existing host-based heuristic
  at `lib/src/sources/ntp_source_io.dart:17-25` —
  second-level domain with `pool.ntp.org` special-cased to
  `ntp-pool`).

### Open follow-ups (filed at PR landing)

- Implementation ticket for the tier-aware Marzullo admission step,
  the `degradedTier` `IntegrityEvent` reason, and the ASN-based
  `groupId` derivation for NTP samples. The README "Implementation
  status caveat" is already updated as part of this PR (ADR 0003 and
  ADR 0005's inherited divergence row reframed as superseded by ADR
  0007); a further README update will be needed at implementation-PR
  landing to remove ADR 0007 from the divergence list.

## Alternatives considered

- **Keep ADR 0003's pure-NTS-and-HTTPS architecture and accept the
  geographic gap.** Rejected: the 2026-05-09 stress run showed the
  gap is structural across three continents, not a temporary
  deployment lag. Accepting it means the package is documentably
  unfit for a meaningful fraction of its addressable audience.
- **Allow free NTP admission (no truth box).** Rejected: gives a
  network-path attacker direct influence over consensus in regions
  with NTS coverage, undoing the integrity guarantee that motivated
  ADR 0001 in the first place.
- **Refuse to publish any anchor on NTS quorum failure.** Rejected:
  see open question 2 — leaves low-coverage regions unserved entirely,
  contradicting the ADR's reason for existing.
- **Weighted admission scoring.** Deferred, not rejected outright —
  see open question 3. Returns as a possible later refinement once
  `wy3` data lands.

## Postscript: upstream 2.1.0 composition — quality tracker + `NtsAuthLevel.advisory` removal (2026-05-23)

Upstream 2.1.0 (release commit `12ad768`, merged into this fork via
`chore/sync-upstream-2.1.0`) lands two changes that touch the
surface area this ADR depends on. Both are additive; this ADR's
decision stands unchanged.

### `SourceQualityTracker` composition with tier-aware admission

Upstream's new `lib/src/source_quality_tracker.dart` scores sources
on RTT, consensus participation, and stratum. `SyncEngine` uses it
to re-order which sources are queried within each cycle. This is
**orthogonal to the trust-tier admission step proposed here**:

- The quality tracker operates on *operational* signal (was this
  source recently fast, recently agreeing, recently low-stratum)
  and decides query order.
- The admission filter proposed in this ADR operates on
  *cryptographic* signal (`authLevel != NtsAuthLevel.none` for the
  truth-box quorum) and decides whether a sample's interval is
  allowed into the Marzullo sweep at all.

A source can be high-quality but cryptographically unauthenticated
(an HTTPS or NTP source with fast, agreeing history) — it is queried
early because of its quality score, then either admitted to or
filtered out of the consensus sweep based on whether its interval
intersects the NTS truth box. The two filters compose without
ordering hazards because the quality tracker runs before sample
collection and the admission filter runs during consensus.

The `degradedTier` integrity event still fires solely on the
condition this ADR specifies (fewer than 2 NTS samples or empty NTS
intersection); the quality tracker has no input into that decision
because it cannot distinguish "all NTS samples were
network-attackable" from "all NTS samples happened to be slow".

### `NtsAuthLevel.advisory` removal

Upstream 2.1.0 removes the `NtsAuthLevel.advisory` enum value
(previously a third state between `verified` and `none`, surfaced
for sources that completed the NTS handshake but failed a soft
policy check). The `NtsAuthLevel` enum is now binary:
`{verified, none}`.

This ADR's admission filter was specified against
`authLevel != NtsAuthLevel.none` for truth-box participation, which
remains correct under the binary enum — only `verified` participates
in the truth box, exactly as intended. No re-specification is owed.
The implementation ticket (`trusted_time-c8y`) is unchanged in
scope; the upstream migration test
(`test/nts_auth_level_migration_test.dart`) already covers the
behavioural shift for downstream callers and is shipped with the
sync merge.

## Postscript: ASN `groupId` shipped as an offline bundle, not a network lookup (2026-06-27)

Decision point 4 above, and the second "Negative" consequence,
specify the NTP-tier ASN `groupId` as a *best-effort network*
IP-to-ASN lookup that "introduces a network dependency on a separate
IP-to-ASN lookup" and must "cache aggressively (per-cycle is
sufficient)". The implementation that landed (`trusted_time-c8y`)
keeps the **decision** — derive the NTP `groupId` from the resolved
IP's ASN, best-effort — but **changes the mechanism**: the ASN table
is a bundled offline snapshot, not a runtime network service. A later
refinement also replaced the original host-based heuristic fallback
with a shared `asn-unknown` sentinel (see "Miss handling" below).

### What shipped

- A compact, sorted binary of `[range_start, range_end] -> asn`
  derived from the **iptoasn.com** dataset, which is released into
  the public domain under the PDDL (freely redistributable, no
  attribution or account required). Two gzipped assets ship in the
  package: `assets/asn/ip2asn-v4.bin.gz` (~2.8 MB) and
  `assets/asn/ip2asn-v6.bin.gz` (~0.74 MB), ~3.6 MB total bundled,
  ~8.1 MB decompressed in memory.
- A dependency-free reader (`lib/src/data/asn_resolver.dart`) that
  gunzips each family's table on first use, holds it in memory once
  per isolate (shared across all `NtpSource` instances), and binary-
  searches it. Every failure mode — missing asset, decode error,
  unknown IP — resolves to `null`.
- `NtpSource.getTime()` resolves the host to a single deterministic
  address (prefer IPv4, then the lowest address literal) and derives
  the ASN `groupId` **after** the timed NTP round-trip. The first ASN
  lookup synchronously gunzips and parses the bundled table on this
  isolate, so keeping it off the timing path prevents it from blocking
  the event loop and skewing the measured delay/offset; `groupId`
  feeds only confidence grading, so this costs nothing for time
  correctness. On any DNS/ASN miss or failure the group resolves to
  the shared `asn-unknown` sentinel (see "Miss handling" below).
- The generator (`tool/generate_asn_db.dart`, dev-only, not shipped
  at runtime) downloads and converts the snapshot reproducibly.

### Why the mechanism changed

The original network framing was the obvious shape at authoring time,
but a runtime IP-to-ASN service ties the package's grouping accuracy
to a third party that can rate-limit, change terms, or go offline,
and — for DNS- or HTTP-based lookups — leaks the time-server IPs the
device queries off-device. A bundled snapshot removes the runtime
dependency entirely (the service "cannot go down"), keeps every
lookup on-device (zero network exposure), and adds no third-party
package dependency. ADR 0008's §"composes with ADR 0007" already
contemplated this branch ("if it chooses a bundled offline ASN
database … those lookups do not count against the DNS/TLS budget"):
under the offline bundle there is no per-lookup network call to
govern, so the unified budget interaction in ADR 0008 simplifies to
the local DNS resolution `NtpSource` already performs.

### Consequence deltas (this postscript supersedes the originals)

- The "network dependency on a separate IP-to-ASN lookup" Negative
  no longer applies; the dependency is a bundled data asset.
- "Cache aggressively (per-cycle is sufficient)" is moot — the table
  is decompressed once and held for the isolate's lifetime; there is
  no per-cycle lookup cost to amortise beyond the host's own DNS
  resolution.
- A new, smaller cost is introduced: the snapshot is **stale-able**.
  IP-to-ASN mappings drift as networks are reassigned, so the asset
  is a point-in-time snapshot refreshed by re-running the generator.
  Staleness only degrades grouping precision (a mis-grouped or
  ungrouped NTP source), never correctness of the time estimate, and
  the `asn-unknown` sentinel is the conservative floor.

### Miss handling: a shared `asn-unknown` sentinel, not a host heuristic

The original decision named the host-based heuristic as the fallback
when ASN derivation misses. The shipped implementation instead
collapses every miss path — no resolved IP, an ASN-table miss, or a
lookup failure — into a single shared `groupIdUnknown = 'asn-unknown'`
sentinel. `groupId` feeds only `MarzulloEngine`'s diversity/confidence
grading, never quorum, per-source votes, the truth box, or the
published time. A per-host heuristic would hand each un-attributable
sample a *distinct* group, letting a table miss masquerade as provider
diversity and inflate confidence. The shared sentinel makes confidence
honest-or-conservative on a miss — never inflated — while availability
is fully preserved: the sample still counts toward quorum and time.

The best-effort contract and the graceful fallback are retained
exactly as decided; only the lookup substrate moved from the network
to a bundled asset, and the fallback target moved from the host
heuristic to the shared sentinel.

## Postscript: the degraded-cycle confidence cap is dropped (2026-07-10)

Open question 2 above promised that a Tier 1 quorum failure would
fall back to lower-tier Marzullo **and cap `confidence` at
`ConfidenceLevel.low`**. The shipped implementation (PR #48)
delivered the fallback and the `degradedTier` event but not the cap:
the degraded branch of `MarzulloEngine.resolve()` pins
`authLevel: NtsAuthLevel.none` and sets
`ConsensusResult.degradedTier = true`,
then publishes whatever confidence the single-tier reduction graded
from depth and diversity. This postscript resolves the divergence in
favour of the implementation — the cap is deliberately dropped, not
owed.

### Why the cap is wrong under the secure-time contract

The cap predates the secure-time contract
(`doc/specification/secure-time-contract.md`), which establishes
`ConfidenceLevel` and `NtsAuthLevel` as **orthogonal axes**:
confidence measures consensus *quality* (population depth, provider
diversity, variance) and is explicitly not a trust statement; the
auth level measures the trust *path*. Under that doctrine a degraded
cycle with many agreeing, diverse NTP/HTTPS sources genuinely has
high statistical agreement, and the honest grade for it is whatever
depth and diversity earned. Capping would fold the trust axis into
the quality axis, making `low` ambiguous between "thin consensus"
and "healthy consensus, degraded trust" — destroying telemetry
information without adding protection.

### The integrity story the cap was defending is carried elsewhere

The cap's original purpose — "callers who require high-confidence
anchors for security-critical paths see the degradation
immediately" — is served by three signals that all shipped:

- `TrustAnchor.authLevel == NtsAuthLevel.none` on every degraded
  anchor, which makes `getTime(requireSecure: true)` **fail closed**
  regardless of confidence. `requireSecure` is the contract's
  security gate; `minConfidence` is a quality gate, and the contract
  directs security-sensitive callers to the former.
- The `degradedTier` `IntegrityEvent` on `onIntegrityLost`, emitted
  at the cycle that lost its truth box.
- `SyncMetrics.confidenceBreakdown['tier1Quorum']` — the fraction of
  the configured source pool that contributed a `verified`
  participant to the published consensus. It reads `0.0` when no
  verified sample landed in the consensus winning set — i.e. none
  contained the consensus window's midpoint, the engine's structural
  anchor, whether because Tier 1 collected nothing usable or because
  the verified samples' intervals missed it — and can be positive on
  a degraded cycle when verified samples did contain the fallback
  window's midpoint without having formed a truth box. It is a
  per-cycle health gauge for the verified tier's presence in the
  published consensus, to be read alongside the `degradedTier` event
  rather than as a degradation discriminant on its own.

An attacker who suppresses NTS (blocking TCP/4460, breaking the
NTS-KE handshake) can therefore still produce a high-confidence
degraded anchor — but cannot produce a `verified` one, which is the
axis the threat model defends. `requireSecure: true` is immune to
the suppression by construction.

### Consequence delta

The "Positive" consequence above claiming callers "distinguish
authenticated vs degraded anchors via `confidenceScore`" is
superseded: the discriminant is `TrustAnchor.authLevel` (and the
`degradedTier` event), never the confidence surface. Decision
tracked as `trusted_time-r9h`.

## Postscript: the NTS tier is partitioned per cycle (2026-08-02)

The tier table above sizes NTS at "3–5 hosts" and rules it "always
admitted to its own quorum". `trusted_time-7pb` replaced the two-host
NTS default with a curated 57-host inventory
(`lib/src/data/nts_inventory.dart`) without revisiting either. This
postscript records how the two are reconciled: the **tier size is a
per-cycle property, not an inventory property**, and the engine
narrows the 57-host inventory to that size every cycle the way it
already narrows the plain-NTP inventory. Decision tracked as
`trusted_time-ky3`.

### What the inventory migration broke

`SyncEngine._selectCycleHosts` partitions `ntpInventory` only. An NTS
source id is in neither the explorer set nor the NTP inventory id set,
so it falls to the `blocking` branch — every host in `ntsInventory` is
classified as a blocking host every cycle, and `warmAllSources()`
opens one concurrent NTS-KE handshake per host at bootstrap and again
at each cycle's warming barrier. On the default posture that getter
yields the curated 57, so 57 is the number this postscript quotes
throughout; `disableNts` empties it and `ntsInventoryForTesting`
substitutes for it, neither of which is the configuration the cost
argument is about. Each handshake is a TCP connect plus a TLS
handshake plus a key exchange, so this is not the NTP tier's cost
profile scaled up; it is a qualitatively heavier fan-out that the
shared `DnsBudget` (ADR 0008) throttles but does not bound.

Classification is a ceiling rather than a count. `sync()` narrows the
blocking set by `_blacklistUntil` before querying, so a host on
cooldown is blocking-by-role yet gates nothing that cycle. The
handshake fan-out does not get that relief: `warmAllSources()`
iterates every `Warmable` source, not the cycle's hosts, so the
NTS-KE cost is paid on the full inventory whatever the health filter
concludes. The argument below is about that ceiling — a partition
lowers it, whereas cooldown only masks it host-by-host, and only
after the failures that arm it have already been paid for.

The engine's own dartdoc justified the pass-through on three grounds:
there are few NTS hosts, they are the authenticated half of the
consensus, and rotating them would make an anchor's authentication
level depend on which cycle it landed in. Only the first was
invalidated by the migration. The decision below is what the other
two survive as.

### Decision

Apply `partitionInventory` (`lib/src/domain/inventory_partition.dart`)
to `ntsInventory` on the same tier rule the NTP tier uses, with the
quorum sized by two distinct numbers that the rest of this postscript
keeps apart:

- a **validity floor** of 3 — the number of *responding* verified
  hosts below which the cycle has no truth box and degrades; and
- a **query target** of 5 by default — the number of hosts *asked*,
  chosen so the floor is still met after failures.

Conflating the two is the trap here. A query target equal to the floor
means one timeout degrades the cycle.

- **Validity floor — 3 responding verified hosts.** Three is the first
  size at which the truth box survives a single bad host: at
  `minQuorumRatio = 0.6` a 3-sample population needs an overlap of 2,
  so one outlier can be shed and a box still forms. At 2 responders
  the required overlap is also 2, meaning both must agree — that
  detects a liar rather than outvoting one, which is not what the
  truth box exists for. Below 3 the cycle degrades to
  `NtsAuthLevel.none` on the existing path. This is a stricter floor
  than `MarzulloEngine._resolveCore`'s current `totalSources < 2`
  guard and than `TrustedTimeConfig.minimumQuorum`, both of which
  stay as they are: the 3-responder rule is specific to the truth-box
  pass over the verified subset.
- **Fixed members — the 3 `TimeServerTier.anycast` hosts, every
  cycle.** `time.cloudflare.com`, `nts.netnod.se`, and `any.time.nl`,
  which sit in three distinct registrable-domain groups, so the fixed
  members alone satisfy `minGroupCount = 2`. Anycast hosts need no
  per-install ranking to be near the caller, which is what makes
  pinning them viable on day one. They are members by identity, not
  by rank, and are never displaced by a better-ranked unicast host.
- **Promotion — the query target is filled above the fixed members
  from the top of the unicast ranking.** Promotion is by
  `SourceQualityTracker` rank and is what gives the exploration below
  a consumer: a discovered fast unicast host is one the truth box
  actually uses. It also supplies the failure headroom — with a
  target of 5 and 3 fixed members, two hosts can fail and the floor
  is still met. A host is promotable only on a *recorded success*, not
  on the mere existence of a tracker entry: a host known solely from a
  failed probe would otherwise fill a slot and make the target's
  headroom nominal — a target of 5 carrying two hosts expected to fail
  is three real responders wearing a five.
- **Cold-start fill — with no ranking, the target is filled from the
  walk order.** See the subsection below; this is the case where
  "promote by rank" has no rank to consult.
- **The query target is a config knob, clamped to the floor.**
  Defaulting to 5, which keeps the tier inside the table's stated 3–5
  band. Installs on a metered or battery-critical profile can lower
  it; installs that want more headroom can raise it. The setter
  rejects a value below the validity floor rather than silently
  clamping, since a target under the floor is a configuration that can
  never produce a truth box.
- **Exploration — the 54 unicast S1/S2 hosts are an explorer walk**,
  probed a few per cycle under the staleness-ordered, per-install
  shuffled traversal `partitionInventory` already implements. Explorer
  samples feed the ranking only: they reach neither the Marzullo
  population nor the cycle's completion, exactly as on the NTP side.
- **Separate budget from NTP.** `partitionInventory`'s dartdoc already
  anticipates this ("callers keep the protocols' budgets and staleness
  lookups separate, since an NTS probe costs a TLS handshake an NTP
  probe does not"). The NTS explorer budget is sized independently and
  is narrower.

Per-cycle NTS-KE handshakes go from 57 to `target + ntsExplorerBudget`
— single digits — and `warmAllSources()` is bounded by the same set,
since warming must cover the cycle's hosts rather than the inventory.

### "Always admitted" is unchanged; it was never a query rule

The tier table's admission column says NTS is "always admitted to its
own quorum". That governs **what happens to a sample that was
collected**: an NTS sample is never gated against the truth box,
because it is what defines the truth box. Partitioning governs **which
hosts are queried**. Every NTS sample a partitioned cycle collects is
still admitted unconditionally; there is simply no cycle in which all
57 are collected. The rule and the partition are orthogonal, and the
table needs no amendment.

The "authentication level depends on which cycle" objection is
answered by the fixed members rather than dismissed. The three anycast
hosts are queried every cycle, so an anchor's *access* to a verified
truth box does not turn on where the walk happens to be. What does
vary between cycles is the box's membership above them — the promoted
hosts — and its width with it. That is a precision property, not a
trust property: every member is `NtsAuthLevel.verified` whichever
cycle it landed in, and `TrustAnchor.authLevel` is unaffected by which
of them answered.

### Cold installs, and why NTS needs a step NTP does not

The partition above is the NTP shape applied to a second inventory,
but the two tiers are not the same size, and the whole cold-start
problem is that asymmetry:

| Inventory | anycast (fixed members) | unicast (explorer pool) |
|-----------|------------------------:|------------------------:|
| NTP       | 11                      | 41                      |
| NTS       | 3                       | 54                      |

NTP's fixed members outnumber its floor of 2 by nine, so the NTP
partition has never needed a promotion step: the quorum is whole on
the first cycle of a fresh install and stays whole through several
simultaneous failures. NTS pins 3 fixed members against a floor of 3.
Promotion is not a refinement borrowed from the NTP side — it is the
mechanism that supplies the headroom the NTS tier's population does
not, and on a cold install it is the only thing standing between the
floor and a single timeout.

Promotion draws on `SourceQualityTracker`, which is empty on a fresh
install. Explorer samples cannot fill the gap within the cycle: they
are excluded from the consensus population by construction, so a
cycle-1 explorer probe informs the *next* cycle's promotion and not
this one's box. Taken literally, a cold install would therefore query
exactly the 3 fixed members whatever the target is set to, and the
knob would be inert in precisely the window where headroom matters
most.

**Resolution: on an empty ranking, fill the target from the walk
order rather than skipping promotion.** `partitionInventory` already
sorts never-probed hosts first with `ExplorerShuffle` breaking the
ties, so on a cold install that ordering *is* a per-install random
draw over the 54 unicast hosts. Filling from it introduces no new
selection rule and no new randomness — it promotes the first entries
of the traversal the partition computes anyway. Concretely, at a
target of 5 the first two walk entries are marked `blocking` instead
of `explorers`.

The handshake cost is identical either way: those hosts are probed
this cycle regardless. What the fill changes is only whether the
cycle is *permitted to use* the result. Spending two NTS-KE
handshakes and then discarding the samples, in the one cycle where
the floor is otherwise unmet, is not defensible.

What it does cost is latency. A blocking host gates the cycle, where
an explorer is fire-and-forget under the 2 s `explorerTimeout`; a
cold-start-filled host is unmeasured by definition, so cycle 1 waits
on hosts nothing is known about. This is accepted: cycle 1 is also
the cycle with no cached anchor, so its latency is already the
install's worst, and `maxLatency` bounds it.

Three qualifications keep this honest:

- **The floor is a regression here, not merely a lack of headroom.**
  Two verified responders that agree form a truth box *today* —
  `_resolveCore` computes `requiredQuorum = ceil(2 × 0.6) = 2` and
  passes. Raising the truth-box floor to 3 removes that case. The
  cold window does not just lose tolerance; it loses a configuration
  that currently works.
- **The exposure is cycle 1, but cycle 1 is the expensive one.** One
  cycle of explorers populates the tracker, so promotion has rank to
  consult from cycle 2 onward. Narrow in count — but cycle 1 is the
  install's first launch and the first anchor a consumer ever sees,
  and at the 24 h establish cadence (ADR 0006) cycle 2 is a day away.
  A lost or corrupt tracker returns an install to this state.
- **The dominant cold failure is correlated, so headroom is worth
  less than the arithmetic suggests.** The floor's reasoning assumes
  independent host failures. The realistic cold-install NTS failure is
  the client network — port 4460 blocked, TLS interception, a captive
  portal — and that fails all three fixed members at once. The
  outcomes cluster at 3 responders or 0, and the 2-responder middle
  case the floor newly rejects is thin. This cuts both ways: it makes
  the regression above smaller in practice, and it means headroom of
  any size buys nothing against the failure that actually dominates.
  The fill is justified by the wasted-handshake argument, not by an
  expected-value claim about failure rates.

**Degradation is not loss of time.** When the verified pass fails,
`resolve()` falls back to a legacy single-tier reduction over every
sample, NTP included, so a cold install that loses a fixed member
still publishes an anchor — at `NtsAuthLevel.none` with
`degradedTier` set. The cost is trust level and a
`TrustStatusReason.degraded` assessment, not availability. A consumer
gating on `verified` fails closed on day one; one reading wall time
does not.

### Accepted costs

- **The authenticated population per cycle drops from 57 to the
  target.** The truth box is correspondingly less able to outvote a
  compromised member: at 5 hosts across at least three operators the
  Marzullo intersection still tolerates a minority liar, but the
  margin is thinner than a 57-host box would give. This is the
  deliberate trade — a 57-host box was never affordable to collect, so
  the comparison is against a box the engine could not build, not one
  it was building.
- **The failure headroom is `target − floor`, and it is a knob the
  caller can set to zero.** At the default target of 5 two hosts can
  fail and the cycle still holds. Lowered to 3 there is no headroom at
  all: one timeout degrades the cycle. The clamp rejects targets
  *below* the floor, not targets *at* it, so this configuration is
  reachable and must be documented on the knob rather than prevented.
- **Truth-box width becomes install-dependent.** Two devices at the
  same instant can have different promoted members and so differently
  tight boxes. Consistent with open question 1 above (the box's width
  already "tracks the NTS quorum's natural tightness"); the tightness
  is now also a function of how far this install's ranking has
  converged.
- **Cold-start installs fill the target with unmeasured hosts.** The
  fill above restores the count but not the quality: cycle 1's
  promoted members are drawn from the walk, so they may be slow, far,
  or down, and the cycle blocks on them under `maxLatency`. The
  headroom is real — a fixed member can fail and the floor still holds
  — but it is headroom against *host* failure specifically, and it
  arrives at the cost of the install's slowest cycle. This is also
  when `minGroupCount` is doing the most work, hence the requirement
  that the three anycast hosts span three groups on their own rather
  than relying on the fill for diversity. `wy3` burst-sampling and the
  front-loaded explorer budget shorten the window in which any of this
  applies.
- **Sweep latency.** 54 candidates at a narrow NTS budget is many
  cycles at the 24h establish cadence (ADR 0006). A host that
  regressed between probes stays in the ranking on stale evidence for
  correspondingly longer. The fixed members are unaffected, so the
  failure mode is a suboptimal promotion, not a lost truth box.

### Alternatives considered

- **Cold installs run the fixed members alone, with no fill.** The
  literal reading of "promote by rank" when there is no rank.
  Rejected: the hosts that would have filled the target are probed as
  explorers in that same cycle anyway, so the cycle pays the NTS-KE
  handshakes and then discards the samples at precisely the moment the
  floor is unmet. It also makes the query-target knob inert on day
  one, which is the window it was added for.
- **Cold-start fill from explorer samples that already arrived**
  (admit verified explorers when the blocking set lands below the
  floor). Uses work already paid for, and gives the walk a second
  consumer. Rejected as the primary shape: it makes the truth box's
  membership depend on where the walk happens to be, in exactly the
  failure case — reopening the cycle-invariance question the fixed
  members close. Deciding membership *before* the probes are launched
  keeps the invariant intact for the same handshake cost. Worth
  revisiting only if blocking on unmeasured hosts proves too slow in
  practice.
- **A relaxed floor of 2 during a cold window only.** Would preserve
  the case the floor removes without a fill step. Rejected: a fresh
  install on an unknown network is the worst moment to lower the
  tolerance, and a floor that varies with install age is a trust
  property that varies with install age.
- **A validity floor of 2 rather than 3.** Matches
  `TrustedTimeConfig.minimumQuorum` and `_resolveCore`'s existing
  guard, so it would need no new constraint. Rejected: at 2 responders
  the required overlap is also 2, so the box forms only if both hosts
  agree and any single disagreement collapses it. That is liar
  detection, not liar tolerance, and it makes an ordinary transient
  failure indistinguishable from an attack. Three is the smallest
  population that can shed an outlier.
- **No promotion — a quorum of exactly the 3 fixed members.** The
  simplest reading of the partition, and the tightest cycle-invariance
  guarantee. Rejected: it puts the tier at the bottom of its own
  stated band with zero failure headroom, and it leaves the explorer
  walk with no consumer — 54 hosts measured every install, none of
  which could ever contribute time. Measurement with no consumer is
  cost with no benefit.
- **Rank-only membership, with no host pinned by identity.** Would let
  a consistently faster unicast host displace an anycast one and give
  a tighter box. Rejected: membership would then be entirely
  install-dependent, and the cycle-invariance argument above — which
  is what lets partitioning coexist with the tier's trust role — rests
  on some fixed, ranking-independent set being present in every cycle.
- **Promotion only on anycast failure (backfill).** Preserves an
  exactly-fixed membership in the steady state and widens only when an
  anycast host degrades. Rejected as the primary shape for the same
  no-consumer reason — the walk would pay for itself only in the
  degraded case — but it is the natural fallback if promotion is later
  found to destabilise box width, and the implementation should keep
  the failure path able to reach outside the fixed members regardless.
- **Bound only the bootstrap warm fan-out, leave per-cycle
  unpartitioned.** Addresses the loudest symptom and none of the
  cause: every cycle would still open 57 handshakes at its warming
  barrier. Rejected.
- **Partition NTS on the NTP explorer budget.** Rejected: an NTS probe
  is TCP + TLS + KE where an NTP probe is one UDP round trip, so the
  budget that fits an iOS `BGAppRefreshTask` for one protocol does not
  for the other.

### Follow-up

Implementation is a separate ticket, `trusted_time-1ww` — this
postscript is `trusted_time-ky3`, which closes on the decision, while
the code divergence the ADR index lists clears only when `1ww` lands.
It applies `partitionInventory` to `ntsInventory` in
`_selectCycleHosts`, adds the promotion step with its
recorded-success requirement and its cold-start fill from the walk
order, the query-target knob with its floor clamp, and the NTS
explorer budget constants; enforces the 3-responder validity floor on
the truth-box pass; scopes `warmAllSources()` to the cycle's hosts;
and rewrites the `sync_engine.dart` dartdoc that still rests on the
"there are few of them" premise.

The cold-start fill is a promotion-source change, not a second
mechanism: `partitionInventory` already returns the walk in staleness
order with never-probed hosts first, so the fill takes its prefix and
reclassifies those ids from `explorers` to `blocking`. The
`explorerBudget` passed to the partition has to account for the ones
promoted out, or the cycle widens by the fill rather than
reallocating within it.

The validity floor is the one piece that is not a `SyncEngine` change.
`MarzulloEngine.resolve` reaches its degraded fallback when
`_resolveCore` over the verified subset returns `null`, and that guard
floors at 2. Raising it to 3 for the verified subset only — leaving
the merged-set reduction and `minimumQuorum` untouched — is what makes
"below 3 responders, no truth box" true in code rather than only in
this document.
