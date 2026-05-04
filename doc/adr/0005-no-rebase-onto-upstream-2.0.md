# ADR 0005: Decision not to rebase onto upstream `trusted_time` 2.0.0

- Status: **Accepted**
- Date: 2026-05-04
- Tracking issue: `trusted_time-k5p`
- Supersedes: portions of ADR 0001 §"Alternatives considered" that rejected a sibling `trusted_time_nts` package on the assumption upstream would adopt the conditional-import-stub integration in core. After upstream shipped 2.0.0 along a different path (see Context and the postscript appended to ADR 0001), the sibling-package shape is the operational reality this ADR records — not a freshly-chosen distribution strategy.
- Related: ADR 0001 (NTS integration strategy — historical context for the original RFC 5705 finding and the rejected alternatives), ADR 0003 (removing clear-text NTP)
- Upstream outreach: [`Sahad2701/trusted_time#11`](https://github.com/Sahad2701/trusted_time/issues/11)

## Context

`trusted_time_nts` was forked from `Sahad2701/trusted_time` at 1.0.5 (pre-NTS) to add Rust-backed RFC 8915 NTS and remove unauthenticated NTP from the default consensus pool. On 2026-04-29 upstream shipped `trusted_time` 2.0.0 (now at 2.0.2), which independently introduced NTS support, `ConfidenceLevel` with exponential decay, adaptive consensus thresholds (3× median uncertainty), exponential source cooldown, a stability guard, Marzullo correctness fixes, Linux `timerfd` integrity monitoring, and Windows `WM_TIMECHANGE` subclassing.

A side-by-side audit of the two implementations was performed on 2026-05-04. Convergent additions are extensive; the two projects diverge on exactly the two security decisions that motivate this fork's existence.

## Divergence

| Dimension | Upstream `trusted_time` 2.0.2 | Fork `trusted_time_nts` 1.0.0 |
|---|---|---|
| NTS-KE + AEAD-NTPv4 | Pure-Dart over `package:cryptography` | Rust-backed via `package:nts` (rustls + RFC 5705 exporter) |
| Self-described status | "Cryptographic Preview" (CHANGELOG 2.0.0) | Production, gated on `package:nts` |
| Clear-text NTP in default pool | Retained (`ntp: ^2.0.0`) | Removed (ADR 0003) |
| Dart SDK floor | `^3.0.0` | `^3.10.0` (Native Assets requirement) |
| Flutter floor | `>=3.29.0` | `>=3.38.0` |
| HTTPS-Date default fan-out | 2 operators | 4 operators (ADR 0003) |
| Confidence scoring, `requireSecure`, `TimeInterval`/`TimeSample` split, `timerfd`, `WM_TIMECHANGE` | Present | Independently present |
| Adaptive thresholds, exponential cooldown, stability guard | Present | Cherry-pick candidates (`trusted_time-381`, `trusted_time-33l`, `trusted_time-ads`) |

Upstream's "Cryptographic Preview" label is the load-bearing signal. RFC 8915 §4.3 requires that C2S/S2C AEAD keys be derived from the NTS-KE TLS session via the RFC 5705 keying-material exporter. `dart:io.SecureSocket` does not expose that exporter, and `package:cryptography` operates above the TLS layer, so a pure-Dart NTS-KE client running on the standard `dart:io` TLS stack cannot derive RFC-compliant keying material. ADR 0001 §"Alternatives considered" rejected this exact path for that reason.

## Decision

**Continue independent development.** Track upstream as a peer project for targeted cherry-picks; do not rebase the fork onto 2.0.0 and do not pursue re-merging the fork into upstream.

## Consequences

### Positive

- The fork retains the two security properties advertised by its name (`trusted_time_nts`) and ADR 0003: authenticated time via an audited TLS 1.3 stack with a real RFC 5705 exporter, and a default consensus pool that does not include unauthenticated NTP.
- Cherry-picks of upstream's additive consensus work (adaptive thresholds, exponential cooldown, stability guard, Marzullo correctness fixes) remain available without inheriting the pure-Dart NTS implementation or the retained `package:ntp` dependency.
- The strategic decision is recorded before any consumer adopts the fork, giving downstream readers a clear account of why two pub.dev-shaped packages with similar names exist.

### Negative

- The fork carries ongoing diff-management cost against upstream: each new upstream release must be audited for cherry-pickable improvements (and for incompatible additions — for example, further pure-Dart NTS work that would be wrong to port).
- The two packages will continue to diverge on naming, defaults, and SDK floor. Consumers comparing them need a clear narrative; this ADR is part of that narrative, alongside the upstream outreach on `Sahad2701/trusted_time#11`.
- Convergent independent implementations (confidence scoring, `requireSecure`, domain split, platform integrity monitoring) require periodic audit against upstream's parameters to confirm the fork is not subtly weaker on any axis. Tracked in `trusted_time-gbt`, `trusted_time-ejv`, `trusted_time-q7s`.

## Alternatives considered

- **Re-merge fork enhancements upstream and deprecate `trusted_time_nts`.** Rejected. Re-merging requires either (a) abandoning the Rust-backed NTS path, which contradicts ADR 0001's RFC 5705 finding, or (b) raising upstream's SDK floor from `^3.0.0` to `^3.10.0`, which would silently break every upstream consumer below Dart 3.10 / Flutter 3.38 — a change upstream is unlikely to accept and which the fork has no standing to impose. Landing the clear-text NTP removal upstream is similarly out of scope; upstream shipped 2.0.0 with `package:ntp` retained.
- **Rebase fork onto upstream 2.0.0.** Rejected. Most of the upstream 2.0.0 diff is unwanted in the fork: pure-Dart NTS-KE code we would delete, `package:ntp` we would re-remove, `cryptography: ^2.7.0` we don't use. The rebase would carry a persistent patch over those subsystems indefinitely; a cherry-pick model for the additive consensus improvements has the same eventual surface area with a much smaller permanent diff against upstream.
- **Offer upstream an opt-in switch between `cryptography` and `package:nts` backends.** Rejected. Doubles upstream's maintenance surface and keeps the default that ADR 0003 identifies as a security defect. The upstream outreach on `Sahad2701/trusted_time#11` communicates the RFC 5705 constraint and the FFI/Native-Assets trade-off without proposing this compatibility layer.

## Tracking

- Cherry-pick work: `trusted_time-skj` (Marzullo audit), `trusted_time-381` (adaptive thresholds), `trusted_time-33l` (exponential cooldown), `trusted_time-ads` (stability guard), `trusted_time-vlm` (Windows `WM_TIMECHANGE`).
- Convergent-feature audit: `trusted_time-gbt` (`ConfidenceLevel` decay), `trusted_time-ejv` (`requireSecure` semantics), `trusted_time-q7s` (`TimeInterval`/`TimeSample` boundaries).
- ADR 0001 patch: `trusted_time-wyb`.
- Upstream response monitoring: `trusted_time-1qx`.
