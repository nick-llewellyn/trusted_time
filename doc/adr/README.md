# Architecture Decision Records

This directory holds the fork-only Architecture Decision Records for
`trusted_time_nts`. ADRs are append-only, immutable records of
load-bearing architecture decisions and the reasoning behind them at
the time the decision was made — they are not living docs and are not
edited to track downstream events. Subsequent decisions that
re-evaluate or supersede earlier ones land as new ADRs that link back
to the originals.

## Scope

Fork-only. The upstream `Sahad2701/trusted_time` repository does not
carry these ADRs and is not expected to. They document decisions
specific to `trusted_time_nts`'s fork-mode existence — Rust-backed NTS
via `package:nts`, removal of clear-text NTP, the strategic decision
not to rebase onto upstream 2.0.0, and so on.

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
| [0002](0002-headless-background-sync.md) | Real headless background anchor refresh | Accepted | 2026-04-28 |
| [0003](0003-removing-clear-text-ntp.md) | Remove clear-text NTP from the package | Accepted | 2026-04-28 |
| 0004 | _(intentionally absent — number reserved during early ADR drafting and never assigned)_ | — | — |
| [0005](0005-no-rebase-onto-upstream-2.0.md) | Decision not to rebase onto upstream `trusted_time` 2.0.0 | Accepted | 2026-05-04 |

## Implementation status caveat

ADR status reflects the **decision** ("Accepted" = the decision stands
and is the position of record), not necessarily the operational state
of the implementation. ADR 0002, in particular, is "Accepted" but its
referenced work is still tracked in `trusted_time-e0v` as in-progress
— the ADR records the decision to do real headless background refresh,
not a claim that the implementation is complete.

## Authoring conventions

- Filename: `NNNN-kebab-case-slug.md`, sequential. Reserve a number by
  opening the file with status `Proposed`; promote to `Accepted` once
  decided.
- Header: status, date, tracking `bd` issue, and `Depends`/`Supersedes`/`Related` cross-references where applicable.
- Standard sections: Context, Decision, Consequences (Positive/Negative), and where useful Alternatives considered, Implementation notes, Versioning.
- Once Accepted, content is immutable except for explicit timestamped
  postscripts (see ADR 0001 for the pattern). Substantive
  reconsideration lands as a new superseding ADR.
