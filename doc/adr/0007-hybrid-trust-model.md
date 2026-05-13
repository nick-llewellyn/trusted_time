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
