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
  verified sample made it into the consensus winning set (whether
  because Tier 1 collected nothing usable or because every verified
  sample was excluded from the reduction), and can be positive on a
  degraded cycle when verified samples participated in the fallback
  reduction without forming a truth box. It is a per-cycle health
  gauge for the verified tier's presence in the published consensus,
  to be read alongside the `degradedTier` event rather than as a
  degradation discriminant on its own.

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
