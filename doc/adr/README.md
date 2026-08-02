# Architecture Decision Records

This directory holds this fork's Architecture Decision Records. ADRs
are append-only, immutable records of load-bearing architecture
decisions and the reasoning behind them at the time the decision was
made — they are not living docs and are not edited to track downstream
events. Subsequent decisions that re-evaluate or supersede earlier ones
land as new ADRs that link back to the originals.

## Naming note

The `pubspec.yaml` `name` field on this fork is `trusted_time` — same
as upstream `Sahad2701/trusted_time`, because this fork is published
as a drop-in alternate for the same package surface. Several ADRs
(notably ADR 0005) refer to the fork by the narrative identifier
`trusted_time_nts` to distinguish it from upstream when both are
discussed in the same paragraph. The two names refer to the same
artifact: this repository, this `pubspec.yaml`, this `lib/` tree.

## Scope

Fork-only. The upstream `Sahad2701/trusted_time` repository does not
carry these ADRs and is not expected to. They document decisions
specific to this fork's existence — Rust-backed NTS via `package:nts`,
the strategic decision not to rebase onto upstream 2.0.0, and so on.

## Re-introduction note

These ADRs originated on the fork's pre-pivot `main` branch (now
preserved at `archive/legacy-fork-main`). When the fork moved to
contribution mode and `main` was reset to mirror `upstream/main`, the
`doc/adr/` tree was dropped along with the rest of the fork's
divergent history. This PR restores the four surviving ADRs to
`integration/bleeding-edge` so that future fork-only architecture
decisions (starting with ADR 0006 on tiered sync cadence) have a
canonical home that is visible to the working codebase rather than
stranded on archive or on isolated `docs/*` branches.

The ADR contents are reproduced verbatim from their latest pre-pivot
state, including:

- ADR 0001's "Postscript: upstream 2.0.0 outcome (2026-05-04)" section
  (originally captured on the now-deleted
  `docs/adr-0001-upstream-2.0-outcome` branch);
- ADR 0005's four post-merge tweaks (originally captured on the
  retained `docs/adr-0005-no-rebase-upstream-2.0` branch).

References to other ADRs and to `bd` issue IDs inside the ADR text are
preserved as written. Some referenced `bd` issues have closed since
the ADR was authored (for example `trusted_time-skj`, `-33l`, `-381`,
`-ads` all closed in May 2026 once their work landed); the ADRs are
not retroactively edited to reflect that — the closure is visible in
`bd` itself, and the historical "open candidate" wording in the ADR
is the correct snapshot of what was decided at the time.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [0001](0001-nts-integration-strategy.md) | NTS (Network Time Security) integration strategy | Accepted | 2026-04-28 (postscript 2026-05-04) |
| [0002](0002-headless-background-sync.md) | Real headless background anchor refresh | Accepted | 2026-04-29 |
| [0003](0003-removing-clear-text-ntp.md) | Remove clear-text NTP from the package | Accepted | 2026-05-01 |
| 0004 | _(intentionally absent — number reserved during early ADR drafting and never assigned)_ | — | — |
| [0005](0005-no-rebase-onto-upstream-2.0.md) | Decision not to rebase onto upstream `trusted_time` 2.0.0 | Accepted | 2026-05-04 |
| [0006](0006-tiered-sync-cadence.md) | Mobile-optimized sync cadence: tiered establish/validate refresh | Accepted | 2026-05-13 |
| [0007](0007-hybrid-trust-model.md) | NTS-anchored hybrid trust model with admission-gated NTP and HTTPS tiers | Accepted | 2026-05-13 |
| [0008](0008-unified-dns-tls-budget.md) | Unified DNS concurrency cap across NTS, NTP, and HTTPS sources | Accepted | 2026-05-13 |

## Implementation status caveat

ADR status reflects the **decision** ("Accepted" = the decision stands
and is the position of record), not necessarily the operational state
of the implementation on the current `integration/bleeding-edge` tree.
The contribution-mode pivot (which reset `main` to mirror
`upstream/main`) reverted any fork-side reductions of the upstream
surface that had not yet been re-introduced as feat/* PRs. As of this
PR, three Accepted ADRs are known to diverge from current code:

- **ADR 0001** describes `TrustedTimeConfig.ntsServers` as "opt-in,
  empty by default". Current code enables NTS by default and the host
  list is no longer a config field at all: it is a fixed curated
  inventory of 57 live-verified hosts in
  `lib/src/data/nts_inventory.dart`, exposed read-only alongside
  `ntsInventory` (see `trusted_time-cln`, `trusted_time-2tx`,
  `trusted_time-7pb`). `disableNts` turns the feature off wholesale.
  The `Decision` text is the original position; the implementation has
  deliberately moved on. The 57-host inventory is not a 57-host tier:
  ADR 0007's 2026-08-02 postscript decides that the engine narrows it
  per cycle to a query target of 5 (configurable) — the 3 anycast
  hosts pinned as fixed members plus promotion from the unicast
  ranking, or from the walk order while that ranking is empty —
  against a validity floor of 3 responders, with the
  remaining unicast hosts on a rotating explorer walk. Decided in
  `trusted_time-ky3`; the divergence clears with the implementation,
  `trusted_time-1ww` — see the ADR 0007 row below.
- **ADR 0002** decides on real headless background anchor refresh.
  Implementation is still in-progress (`trusted_time-e0v`) — the
  current native code performs only an HTTPS HEAD connectivity check.
- **ADR 0007**'s 2026-08-02 postscript (NTS tier partitioned per
  cycle) is decided but not implemented. `_selectCycleHosts` still
  partitions the NTP inventory alone, so with NTS enabled every host
  in `ntsInventory` blocks every cycle and `warmAllSources()` fans out
  across all of them, and `MarzulloEngine._resolveCore` still floors
  the truth-box pass at 2 responders rather than the 3 the postscript
  requires. Tracked as `trusted_time-1ww` (decision:
  `trusted_time-ky3`); the ADR's three earlier implementation pieces
  have all landed (see the note below).

Notes on previously-listed divergences:

- **ADR 0003** ("Remove clear-text NTP from the package") is no
  longer listed as a code divergence. ADR 0007 supersedes ADR 0003's
  NTP-removal decision in the light of new 2026-05-09 stress-run
  evidence about structural NTS-KE deployment gaps. NTP is reinstated
  as a tiered, admission-gated precision contributor; the
  `package:ntp` dependency is intentionally retained per ADR 0007.
  `ntpServers` is no longer a config field — the host list is now a
  fixed curated inventory in `lib/src/data/ntp_inventory.dart`,
  exposed read-only — but NTP itself remains a contributor, which is
  what ADR 0007 decided.
- **ADR 0005**'s "Divergence" table row that inherited ADR 0003's
  NTP-removal claim is no longer a divergence for the same reason
  (the underlying decision has been superseded). The row's text is
  left verbatim per the append-only policy.
- **ADR 0006**'s validate tier (and the `CadenceMode` /
  `validateFreshness()` surface that carried it) was removed in favour
  of a 48h anchor-age policy; the establish-cadence decisions stand.
  Recorded in ADR 0006's 2026-07-25 postscript rather than by editing
  the Accepted text. ADR 0007's references to the "Validate window"
  should be read against that postscript: the truth box is still
  recomputed per-establish; there is simply no validate cycle between
  establishes any more.
- **ADR 0007**'s original decision is no longer listed as a code
  divergence (its 2026-08-02 postscript is, above). Its three
  implementation pieces have landed: tier-aware Marzullo admission
  and the `degradedTier` `IntegrityEvent` reason via `trusted_time-q1n`
  (PR #48), and the ASN-based NTP `groupId` derivation via
  `trusted_time-c8y`. The latter shipped as a bundled offline
  iptoasn.com (PDDL) snapshot rather than the network IP-to-ASN
  lookup the ADR originally framed; that mechanism change is recorded
  in ADR 0007's 2026-06-27 postscript (the decision itself is
  unchanged) rather than by editing the original Accepted text.
- **ADR 0008** is no longer listed as a code divergence. The
  SyncEngine-level `maxConcurrentDnsLookups` semaphore, the shared
  `DnsBudget` (`lib/src/infra/dns_budget.dart`, cache-first with
  drop-on-saturation), the `ntsDnsConcurrencyCap` `@Deprecated`
  annotation + migration ladder, NTP in-process governance, and NTS
  cap-forwarding landed via `trusted_time-bnl`. The remaining HTTPS gap
  is closed by `trusted_time-2od`: `HttpsSource`
  (`lib/src/sources/time_sources.dart`) now pre-resolves its host
  through the shared `DnsBudget` cache-first — with the same
  drop-on-saturation and admission-window-clamp behaviour as NTP — to
  warm the platform DNS cache before `package:http` performs its own
  internal resolution, so HTTPS cold-start lookups draw on the unified
  budget alongside NTP and NTS. Two best-effort tradeoffs are intentional
  and documented at the call site: a double-resolve (the warming lookup
  plus `package:http`'s internal one) and reliance on the platform DNS
  cache TTL outliving the gap between them — consistent with the ADR's
  own "best-effort across the source-kind boundary" caveat. HTTPS DNS is
  not literally counted at the `HttpClient` layer (which still exposes no
  in-process seam); the pre-resolve is the seam.

Each divergence will be reconciled by either a follow-up implementing
PR (closing the gap) or a timestamped postscript on the affected ADR
(acknowledging the gap as the new operational reality). Both paths are
preferable to in-place edits that would erase the original Accepted
decision text.

## Authoring conventions

- Filename: `NNNN-kebab-case-slug.md`, sequential. Reserve a number by
  opening the file with status `Proposed`; promote to `Accepted` once
  decided.
- Header: status, date, tracking `bd` issue (where available — ADR 0003 predates the convention and omits it), and `Depends`/`Supersedes`/`Related` cross-references where applicable.
- Standard sections: Context, Decision, Consequences (Positive/Negative), and where useful Alternatives considered, Implementation notes, Versioning.
- Once Accepted, content is immutable except for explicit timestamped
  postscripts (see ADR 0001 for the pattern). Substantive
  reconsideration lands as a new superseding ADR.
