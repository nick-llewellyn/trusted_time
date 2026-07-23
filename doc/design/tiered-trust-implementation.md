# Tiered trust model — implementation design

**Status:** Implemented (PRs #46–#49), except the cold-start clock-skew rescue (Section 4.6); retained as the design record.
**Companions:** [`doc/research/trust-model-evolution.md`](../research/trust-model-evolution.md) (research), [`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md) (normative contract), [`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md) (Marzullo tier-aware admission).
**Scope:** End-to-end implementation plan for enforcing the Secure Time Contract's `verified`-vs-`none` boundary at every layer (Rust backend, FFI, Dart config, NTS source mapping, Marzullo admission, public API).

This document is the implementation bridge between the abstract contract in `secure-time-contract.md` and the per-component changes that uphold it. Each section below names the file(s) it touches, the data-shape change, the behavioural change, and the test obligation. Filing tickets directly from this document means each ticket already has the file list, the type signatures, and the acceptance criteria pre-baked.

## Implementation status (2026-07 update)

This design predates the `nts 5.1.0` bump (PR #42) and the upstream 2.1.0 sync. Two of its original assumptions are now stale and are corrected inline below:

- **`package:nts` shipped the trust primitives as an additive minor (5.1.0), not a breaking 6.0.0.** `TrustMode.bundledOnly`, `TrustMode.custom`, the `custom` `TrustBackend`, and the `NtsClient` `customRoots` parameter were introduced in `nts 5.1.0` and remain available under the current `^5.2.0` pin (PR #44). Section 1's "Target" listings are therefore **already shipped**; what remains is *consuming* them from `trusted_time`. `package:nts` kept its own historic default (`platformWithFallback`); the move to bundled-only is a `trusted_time`-side decision applied through the effective-mode resolver (Section 2.3), not an `nts` default flip.
- **`NtsAuthLevel.advisory` is already removed** (upstream 2.1.0). Section 3.1's "Current state" listing is historic; the enum is binary `{none, verified}` on trunk today.

Everything else here is now **shipped**: the `TrustedTimeConfig` field additions (Section 2, `trusted_time-rjt` / PR #46), the `TrustBackend → NtsAuthLevel` mapping (Section 3.2, PR #47), the tier-aware Marzullo admission and `degradedTier` event (Section 4, PR #48), and the public-API tightening (Section 5, PR #49). The weakest-link reduction is retired; `NtsSource` maps each handshake's trust backend per Section 3.2.

The sole remaining item — the cold-start NTS-KE clock-skew rescue (Section 4.6) — is still pending under `trusted_time-m8t`. It depends on a per-handshake verification-time override (the optional `verificationTimeMs` parameter), which is present in the pinned `package:nts`; the remaining work is the `trusted_time-m8t` engine orchestration alone, sibling to the trust-mode work in Section 1.

## Layering invariant

The Secure Time Contract collapses to a single sentence: **`NtsAuthLevel.verified` is reachable iff the chain that authenticated the NTS-KE TLS session was anchored in a trust store the library controls** (bundled `webpki-roots`, or caller-supplied custom roots). Every layer below enforces a slice of that invariant:

| Layer | File | Slice it enforces | Status |
|---|---|---|---|
| Rust backend | `nts/rust/src/nts/ke.rs`, `trust_state.rs` | Configurable `KeTrustMode` (BundledOnly / PlatformOnly / Custom); per-handshake `KeTrustBackend` reported truthfully. | Shipped in `nts 5.1.0` |
| FFI / package:nts public API | `nts/lib/src/api/models.dart` | `TrustMode` Dart enum gains `bundledOnly` + `custom`; `TrustBackend` gains `custom` variant; `NtsClient` ctor takes `customRoots`. | Shipped in `nts 5.1.0` |
| trusted_time config | `lib/src/models.dart` (`TrustedTimeConfig`) | Effective default resolves to `bundledOnly`; `usePlatformTrust` / `customRootCerts` fields added; single `ntsTrustMode` passthrough removed. | **Done — `trusted_time-rjt`** |
| NTS source mapping | `lib/src/sources/nts_source.dart`, `nts_auth_level.dart` | `TrustBackend → NtsAuthLevel` mapping table; `verified` reserved for bundled/custom; platform-mediated samples emit `none` with `trustBackend` retained. | `.advisory` removal **done** (2.1.0); mapping **done — PR #47** |
| Sync engine admission | `lib/src/sync_engine.dart`, `domain/marzullo_engine.dart` | Tier 1 (`verified`) samples define the truth box; Tier 2 (platform NTS) admitted only when intersecting it; truth-box-empty marks the cycle `degradedTier` (log warning + degraded assessments). | **Done — PR #48**; event stream since reshaped into assessment state |
| Public API | `lib/trusted_time.dart` (`getAssessment`) | `TimeAssessment.isSecure` reads `true` strictly on `NtsAuthLevel.verified`; degraded anchors report `TrustStatusReason.degraded`. | Fail-closed **live**; truth-box semantics **done — PR #48**; surface unified into `getAssessment()` (supersedes the PR #49 `getTime` shape) |

The invariant is *additive* — a layer further down cannot rescue a layer above that mis-classifies a sample. Every layer fails closed: misconfigured input collapses to `NtsAuthLevel.none`, never silently to `verified`.

## 1. Rust backend & FFI integration (`package:nts`)

**Cross-repo work (shipped):** This section's work lives in the `package:nts` repository. It shipped as an **additive `package:nts` 5.1.0 minor** — not the breaking `6.0.0` originally planned — and is consumed by this fork via the pubspec pin landed in PR #42. The "Target" listings below are present in `nts 5.1.0` today; they are retained as the design record. `package:nts` kept its historic default trust mode; the bundled-only posture is enforced on the `trusted_time` side (Section 2.3).

### 1.1 `KeTrustMode` enum expansion

Current state (`nts/rust/src/nts/ke.rs`):

```rust
pub enum KeTrustMode {
    PlatformWithFallback,
    PlatformOnly,
}
```

Target:

```rust
pub enum KeTrustMode {
    /// Validate against the compiled-in `webpki-roots` bundle only.
    /// No platform store consultation. The MITM-resistant default.
    BundledOnly,

    /// Validate against the OS / platform trust store via
    /// `rustls-platform-verifier`. No `webpki-roots` fallback at
    /// build time or per chain.
    PlatformOnly,

    /// Validate against caller-supplied PEM/DER roots, parsed at
    /// `NtsClient` construction and held in an isolated `RootCertStore`.
    /// No platform store consultation, no `webpki-roots` consultation.
    Custom(Vec<u8>),

    /// Pre-3.0.0 default: platform first, `webpki-roots` on
    /// `build_with_native_verifier` failure. Retained for backward
    /// compatibility; emits `KeTrustBackend::Platform` or
    /// `KeTrustBackend::WebpkiRoots` depending on which arm succeeded.
    PlatformWithFallback,
}
```


**Default choice:** `BundledOnly` *as resolved by `trusted_time`*. `package:nts` 5.1.0 added this variant without changing its own constructor default (which stayed `PlatformWithFallback` for additive compatibility); `trusted_time` never relies on the `nts` default and always passes an explicit mode resolved by `_effectiveTrustMode` (Section 2.3). Rationale is in the Secure Time Contract's "Implementation requirements" section: the library's authentication property is structurally undermined by `PlatformOnly` and `PlatformWithFallback` in TLS-inspection environments, and the historic default silently exposed every consumer to that risk.

### 1.2 `KeTrustBackend` enum expansion

Current state:

```rust
pub enum KeTrustBackend {
    Platform,
    PlatformWithHybridFallback, // Android-only
    WebpkiRoots,
}
```

Target:

```rust
pub enum KeTrustBackend {
    Platform,
    PlatformWithHybridFallback, // Android-only
    WebpkiRoots,
    /// Chain authenticated against caller-supplied custom roots
    /// (KeTrustMode::Custom). Distinct from WebpkiRoots so the
    /// Dart-side mapping can preserve telemetry granularity.
    Custom,
}
```

The Custom variant is **not** a fallback target; a `KeTrustMode::Custom` client produces `KeTrustBackend::Custom` on success and a hard failure otherwise. There is no `PlatformWithCustomFallback`, no `BundledWithCustomFallback`, and no other composite. Each `KeTrustMode` variant has exactly one success backend set:

| `KeTrustMode` | Success backend(s) |
|---|---|
| `BundledOnly` | `WebpkiRoots` |
| `PlatformOnly` | `Platform`, `PlatformWithHybridFallback` (Android-only) |
| `Custom(_)` | `Custom` |
| `PlatformWithFallback` | `Platform`, `PlatformWithHybridFallback`, `WebpkiRoots` |

Build-time failure under `BundledOnly` / `PlatformOnly` / `Custom` surfaces as `KeError::TrustBackendUnavailable`, matching the existing `PlatformOnly` semantics. There is no silent fallback path under any of the three new-or-tightened modes.

### 1.3 Trust-state diagnostic counters

`nts/rust/src/nts/trust_state.rs` tracks four per-backend counters (`platform`, `platform_with_hybrid_fallback`, `webpki_roots`, `custom`) on `InternalTrustBackend`; the `custom` counter shipped in `nts 5.1.0` alongside the `Custom` trust-backend variant above. The Dart-facing `NtsTrustStatus` snapshot exposes seven atomic-Relaxed observables: the `defaultClientBackend` overwrite-on-store event marker, the four `defaultBackend*Count` per-backend cumulative counters (`defaultBackendPlatformCount` / `defaultBackendHybridCount` / `defaultBackendWebpkiCount` / `defaultBackendCustomCount`), and the two Android observables (`androidPlatformInitSucceeded`, `androidHybridFallbackCount`). No migration of existing fields, no shape change.

### 1.4 FFI surface — `NtsClient` constructor

Current `package:nts` public surface:

```dart
NtsClient({TrustMode trustMode = TrustMode.platformWithFallback});
```

Target:

```dart
NtsClient({
  TrustMode trustMode = TrustMode.bundledOnly,
  List<int>? customRoots, // raw PEM or DER bytes
});
```

> **[Shipped in 5.1.0, with one deviation]** The `customRoots` parameter and the `bundledOnly` / `custom` enum values are present in `nts 5.1.0`. The constructor's *default* stayed `TrustMode.platformWithFallback` in `nts`; `trusted_time` does not depend on the `nts` default and always passes an explicit mode resolved by `_effectiveTrustMode` (Section 2.3).

Validation:

- `customRoots != null` *requires* `trustMode == TrustMode.custom`; mismatched combinations throw `ArgumentError` synchronously at construction. The Rust side never sees an ambiguous request.
- `trustMode == TrustMode.custom` *requires* non-empty `customRoots`; the same `ArgumentError` covers it.
- PEM / DER detection is left to the Rust side; the FFI passes `Vec<u8>` and Rust dispatches on the leading bytes. Parse failure surfaces as `NtsError.trustBackendUnavailable` on first handshake (not at construction; matching the existing build-time-failure path).

### 1.5 FFI surface — per-handshake result

`NtsTimeSample.trustBackend` already carries the per-handshake `TrustBackend`. Extend the Dart enum:

```dart
enum TrustBackend {
  platform,
  platformWithHybridFallback,
  webpkiRoots,
  custom, // NEW
}
```

No structural change to `NtsTimeSample` or `NtsWarmCookiesOutcome` — the existing field just gains a new admissible value.

### 1.6 Backwards-compatibility posture

This shipped as an **additive `package:nts` 5.1.0 minor**, not the breaking major originally planned: the new modes and `customRoots` were added without removing the historic default, so existing callers keep compiling unchanged. The bundled-only posture is therefore enforced on the `trusted_time` side (Section 2.3), and the `package:nts` CHANGELOG records the additive surface:

1. New `TrustMode.bundledOnly` and `TrustMode.custom` variants, plus the `NtsClient` `customRoots` parameter.
2. The historic default (`platformWithFallback`) is retained for additive compatibility; callers who want end-to-end bundled trust opt in via `NtsClient(trustMode: TrustMode.bundledOnly)`.
3. Under `bundledOnly`, a `TrustBackend.webpkiRoots` result means "validation succeeded as intended" rather than the historic "fallback was used".

trusted_time consumes this via `pubspec.yaml`'s `nts:` constraint; the pin to `nts 5.1.0` landed as PR #42 on the fork's `integration/bleeding-edge`, and was later bumped to the current `^5.2.0` (PR #44).


## 2. trusted_time configuration (`lib/src/models.dart`)

The class is named `TrustedTimeConfig`, not `SyncConfig`; the task description uses both names interchangeably. This document uses the existing class name.

### 2.1 Field additions

`TrustedTimeConfig` exposes two trust fields. The earlier single `ntsTrustMode` passthrough (typed `nts.TrustMode`, default `platformWithFallback`) was **removed** in `trusted_time-rjt` rather than deprecated: it was fork-local (introduced in PR #28, never present on `upstream/main`), so there were no external consumers a deprecation window would protect. The two fields:

```dart
/// If true, the engine constructs every NTS client in
/// `nts.TrustMode.platformOnly`. The library's
/// `NtsAuthLevel.verified` boundary then collapses to "no NTS sample
/// is verified" — platform-mediated NTS contributes only to Tier 2
/// admission (see Section 4). Default: `false`.
///
/// Setting this to `true` is the explicit "I want platform trust
/// because I have a pinned corporate CA or MDM-installed root, and
/// I accept that authenticity in my deployment is platform-mediated
/// rather than end-to-end" opt-in. The Secure Time Contract is
/// satisfied by emitting `none` rather than misrepresenting these
/// samples as `verified`.
final bool usePlatformTrust;

/// PEM- or DER-encoded root certificates supplied by the consumer.
/// When non-empty, the engine constructs every NTS client in
/// `nts.TrustMode.custom` with these bytes; the platform store and
/// the bundled `webpki-roots` are both ignored.
///
/// Empty (the default) means "use the [usePlatformTrust] / bundled
/// path"; the engine never silently augments custom roots with
/// bundled or platform anchors.
///
/// Concrete shape: PEM is detected by the leading `-----BEGIN
/// CERTIFICATE-----` marker; anything else is treated as DER.
/// Parse failure surfaces as a per-source
/// `NtsError.trustBackendUnavailable` on first handshake.
final List<int> customRootCerts;
```

The mutually-exclusive combination `usePlatformTrust == true && customRootCerts.isNotEmpty` is rejected with `ArgumentError` — pick one trust source. Enforcement lives in the `effectiveTrustMode` resolver (Section 2.3), **not** in the `const` constructor: a `const` constructor cannot evaluate `customRootCerts.isNotEmpty` (list emptiness is not a const-evaluable expression) and cannot `throw`. Because `SyncEngine` reads `effectiveTrustMode` while building its per-source `NtsSource` list (each `NtsSource` constructs its `nts.NtsClient` lazily), an invalid config fails closed before any source is built, so the combination cannot reach a live engine.

The single `ntsTrustMode` passthrough is **removed**, not deprecated (`trusted_time-rjt`). It was fork-local with no external consumers, so a deprecation window bought nothing; `usePlatformTrust` + `customRootCerts` fully replace it.

### 2.2 Default security posture

`usePlatformTrust = false`, `customRootCerts = const []`. The engine resolves this to `nts.TrustMode.bundledOnly` using the primitive already present in `nts 5.1.0`. This flips the *effective* default away from `platformWithFallback` on the `trusted_time` side (the `nts` constructor default is unchanged), closing the "consumer who never thought about trust" exposure path the research document describes. **Implemented in `trusted_time-rjt`.**

The flip is announced in the trusted_time CHANGELOG and surfaced in the package's README migration table. Consumers on managed-device deployments (corporate MDM, pinned roots) must explicitly opt into `usePlatformTrust: true`; the change is visible and intentional.

### 2.3 Effective-mode resolution

The resolver is a getter `nts.TrustMode get effectiveTrustMode` on `TrustedTimeConfig` (`lib/src/models.dart`), consumed by `SyncEngine` when constructing per-source `NtsSource` instances. A getter (rather than the private free function originally sketched here) keeps the logic with the data and makes it directly testable through the package's public export:

```dart
nts.TrustMode get effectiveTrustMode {
  if (usePlatformTrust && customRootCerts.isNotEmpty) {
    throw ArgumentError(
      'usePlatformTrust and customRootCerts are mutually exclusive: '
      'set exactly one trust source.',
    );
  }
  if (customRootCerts.isNotEmpty) return nts.TrustMode.custom;
  if (usePlatformTrust) return nts.TrustMode.platformOnly;
  return nts.TrustMode.bundledOnly;
}
```

There is no legacy field to consult — `ntsTrustMode` was removed in the same change.

### 2.4 `copyWith`, `==`, `hashCode`, `toString`

All four boilerplate methods on `TrustedTimeConfig` gain the new fields. `Object.hashAll(customRootCerts)` for the list-typed field, matching the existing pattern for `ntpServers` / `httpsSources` / `ntsServers`.

The mutability contract documented on the existing list fields applies verbatim to `customRootCerts`: pass a `const` list literal or a list the caller does not subsequently mutate.

## 3. NtsAuthLevel mapping (`lib/src/sources/nts_source.dart`, `nts_auth_level.dart`)

### 3.1 `NtsAuthLevel` enum — already binary

**[Done — upstream 2.1.0]** This cleanup has already landed. The pre-2.1.0 three-variant shape:

```dart
// historic (pre-2.1.0) — no longer on trunk
enum NtsAuthLevel { none, advisory, verified }
```

is gone; trunk carries the binary enum:

```dart
enum NtsAuthLevel { none, verified }
```

`test/nts_auth_level_migration_test.dart` covers the binary `{verified, none}` shape and the persisted-anchor ordinal migration: anchors stored under the three-variant scheme stay readable because `TrustAnchor.fromJson`'s `RangeError`-safe path maps out-of-range ordinals (the old `advisory == 1`) to `NtsAuthLevel.none`. No further enum work is owed by `trusted_time-m8t`; this section is retained as the migration record.


### 3.2 `TrustBackend → NtsAuthLevel` mapping table

**[Done — PR #47]** `NtsSource.getTime` previously hard-coded `authLevel: NtsAuthLevel.verified` for every successful NTS query, regardless of which backend authenticated the TLS chain — the root mis-classification the Secure Time Contract names. The fix is a mapping table consulted at sample-construction time:

| `result.trustBackend` | `NtsAuthLevel` | Rationale |
|---|---|---|
| `webpkiRoots` | `verified` | End-to-end against bundled `webpki-roots`. The library-controlled trust store; corporate-injected CAs cannot reach this path. |
| `custom` | `verified` | End-to-end against caller-supplied roots. The library-controlled trust store; corporate-injected CAs cannot reach this path either. |
| `platform` | `none` | Platform store may contain corporate-injected or MDM-installed CAs. Authenticity is platform-mediated, not end-to-end verifiable from the library. |
| `platformWithHybridFallback` | `none` | Android-only; the platform verifier ran first. Even though the bundle was the authoritative anchor for this chain, the *path* runs through platform machinery; the sample is not safely classifiable as `verified`. |
| `null` (no NTS handshake; should not occur on `NtsSource`) | `none` | Defensive fallback. |

The mapping is a top-level function `NtsAuthLevel authLevelForTrustBackend(nts.TrustBackend?)` on `nts_source.dart`. It is annotated `@visibleForTesting` rather than made library-private: `NtsSource` constructs its FFI-backed `nts.NtsClient` internally with no injection seam, so `getTime` cannot be driven from a unit test, and the five-row mapping coverage asserts the pure function directly. `TimeSample.trustBackend` is retained as-is on every sample, including `none` samples — this is the mechanism that lets the engine distinguish platform-mediated NTS from plain NTP/HTTPS (which has `trustBackend == null`).

### 3.3 `NtsSource.getTime` integration

The single `authLevel: NtsAuthLevel.verified` line at `nts_source.dart` became:

```dart
return TimeSample(
  interval: TimeInterval(
    startMs: timestampMs - uncertaintyMs,
    endMs: timestampMs + uncertaintyMs,
  ),
  sourceId: id,
  groupId: groupId,
  authLevel: authLevelForTrustBackend(result.trustBackend),
  trustBackend: result.trustBackend,
);
```

No change to `NtsSource.isSecure` — it still reports "this source is structurally capable of producing authenticated samples", which is independent of the trust backend the particular handshake landed on. The per-sample classification is the load-bearing one for the Secure Time Contract.

### 3.4 Tier-2 distinguishability invariant

A consumer (or the engine) that wants to distinguish platform-mediated NTS from plain NTP/HTTPS uses the joint shape `(authLevel == none) && (trustBackend != null)`. This is the structural signal: only `NtsSource` ever sets `trustBackend`. `NtpSource` and `HttpsSource` always leave it `null`. The engine's Tier 2 admission (Section 4) keys off this shape rather than introducing a new field.

## 4. Engine admission & consensus (`lib/src/sync_engine.dart`, `domain/marzullo_engine.dart`)

This section is the implementation arm of [ADR 0007](../adr/0007-hybrid-trust-model.md)'s tier-aware Marzullo admission. ADR 0007's design predates the binary-`NtsAuthLevel` migration and the bundled-vs-platform distinction; this design completes it.

### 4.1 Sample classification

Every cycle's collected `samples: List<TimeSample>` partitions into three tiers based on the joint `(authLevel, trustBackend)` shape:

```dart
enum _Tier {
  /// `NtsAuthLevel.verified`: bundled-roots or custom-roots NTS.
  /// Defines the truth box.
  verified,

  /// `NtsAuthLevel.none` && `trustBackend != null`: platform-mediated
  /// NTS. Admitted only if the sample's interval intersects the
  /// verified truth box. Never anchors the truth box.
  platformNts,

  /// `NtsAuthLevel.none` && `trustBackend == null`: plain NTP / HTTPS
  /// / additionalSources. Admitted under the same intersection rule
  /// as platformNts. Indistinguishable from platformNts at admission
  /// time; the split exists only for telemetry.
  best,
}
```

The classifier is a pure function `_Tier _tierOf(TimeSample)` on `marzullo_engine.dart`; no new fields on `TimeSample`.

### 4.2 Truth box construction

1. **Filter for Tier 1.** If the verified subset does not itself reach a Marzullo quorum (the engine's `minQuorumRatio` floor over the verified samples), **no truth box exists for this cycle.** `resolve` falls back to the legacy single-tier Marzullo over all `samples`, pins the result's `authLevel` to `none`, and sets `ConsensusResult.degradedTier = true`. `SyncEngine` reads that flag at its single completion chokepoint and emits an explicit degradation warning through `TrustedTimeLog`. (This chokepoint originally emitted a `degradedTier` `IntegrityEvent`; the assessment-API redesign removed the event stream, and the same signal now reaches consumers as `TrustStatusReason.degraded` on every assessment minted from the degraded anchor.) The degraded anchor is still published for best-effort consumers; strict consumers gating on `TimeAssessment.isSecure` fail closed (see Section 5).
2. **Run Marzullo on Tier 1 only** to produce the verified consensus interval. This interval *is* the truth box: `[startMs, endMs]` over which the verified samples agree.
3. **Re-admit Tier 2 + Tier 3.** Every Tier 2 / Tier 3 sample whose interval intersects the truth box is folded into the merged sample set for the final consensus reduction. Samples whose intervals do not intersect are collected onto `ConsensusResult.droppedOutsideTruthBox`; `SyncEngine` surfaces each one exactly once via `SyncObserver.onSourceFailed` with reason `tier2: outside truth box`.
4. **Final Marzullo** over the merged set refines the published `ConsensusResult`, **subject to a truth-box-authoritative guard**: the refined reduction is accepted only when its midpoint still falls inside the truth box. If a coordinated lower-tier cluster shifts the merged midpoint outside the box, or the widened quorum floor rejects the merged reduction, the verified truth box is published unchanged. Either way the result's `authLevel` is `verified` whenever the truth box was non-empty, regardless of how many Tier 2/3 samples participated — and the per-cycle `SyncMetrics.confidenceBreakdown` carries a `tier1Quorum` key (the verified-participant fraction of the configured pool; `0.0` when no verified sample landed in the published winning set, which is not guaranteed on a degraded cycle — see the ADR 0007 postscript on the dropped confidence cap).

### 4.3 Why Tier 2 cannot anchor

A Tier 2 sample's `groupId` is the NTS server's host; its `sourceId` is `nts:<host>`. In aggregate, several Tier 2 samples from coordinated corporate-MITM responses could form a self-consistent "consensus interval" that disagrees with reality. Letting that interval *define* the truth box would defeat the contract — the engine would publish a consensus that *looks* anchored by NTS but is structurally indistinguishable from a managed-network forgery.

Restricting truth-box definition to Tier 1 alone means: an attacker who terminates the NTS-KE TLS handshake (the threat the contract is designed against) cannot produce a `verified` sample, so cannot influence the truth box's location. The attacker can suppress Tier 1 entirely (forcing the degraded fallback), but they cannot move the truth box without also compromising the bundled trust store — a different and much harder threat model.

### 4.4 Marzullo signature & `ConsensusResult` shape

`MarzulloEngine.resolve(List<TimeSample> samples)` keeps its flat-list signature; tier classification happens inside `resolve`, which delegates each single-tier reduction to a private `_resolveCore`. Callers (`SyncEngine`) continue to pass the full sample list.

`ConsensusResult` gains two fields that carry the tier decision out of the engine:

- `degradedTier` (`bool`, default `false`) — the plumbed signal of Section 4.2 step 1. `SyncEngine` keys its degradation warning off this flag rather than re-deriving it, so the engine that *made* the truth-box decision is the one that reports it. (This supersedes the earlier note here that `authLevel` alone would suffice: `authLevel == none` is ambiguous between "degraded" and a healthy NTP-only cycle only at the *type* level; the explicit flag removes the ambiguity at the call site and keeps the emission single-fire.)
- `droppedOutsideTruthBox` (`Set<TimeSample>`, default `const {}`) — the Section 4.2 step 3 rejects, carried so `SyncEngine` reports them once at completion instead of spamming `onSourceFailed` on every per-arrival `resolve`.

`participants` lists every sample that contained the published midpoint, including any admitted Tier 2/3. `authLevel` is set by the wrapper from truth-box presence (`verified` when a box formed, `none` when degraded), replacing the legacy weakest-link aggregation that `_resolveCore` still computes internally.


### 4.5 Composition with upstream's `SourceQualityTracker`

The tier-aware admission composes orthogonally with upstream 2.1.0's `SourceQualityTracker` (see ADR 0007 postscript): the quality tracker ranks healthy sources for inclusion in the cycle's `activeSources` *before* this design's classification runs. Tier is a property of the *sample produced* by a source, not a property of the source itself, so quality ranking and tier classification do not interact. A source whose handshakes consistently land on `webpkiRoots` will be ranked alongside one whose handshakes land on `platform`; this design then admits or rejects the resulting samples by tier.

The latent bugs filed as `trusted_time-4em` (unreachable starvation guard) and `trusted_time-a4d` (participation rate stuck at 1.0) are independent of the tier design — they live in the quality-tracking layer the tier layer sits on top of. See the audit section below for the cross-reference.

### 4.6 Cold-start bootstrapping & the NTS-KE clock-skew rescue

The Secure Time Contract's [Cold-start bootstrapping](../specification/secure-time-contract.md#cold-start-bootstrapping-and-the-nts-circular-dependency) section specifies the *what*; this section is the *where* and *how*.

**The paradox in code terms.** NTS-KE is a TLS 1.3 handshake; rustls validates the server certificate's `notBefore` / `notAfter` against the host clock. `_bootstrap()` (`lib/src/trusted_time_impl.dart`) calls `_syncEngine.warmAllSources()`, which fans out `NtsSource.warm()` → `NtsClient.warmCookies()`. On a skewed-clock cold start every NTS-KE handshake fails in its TLS phase; `warmAllSources()` swallows the failures (best-effort by design, `sync_engine.dart`), and `NtsSource`'s own warm / getTime catch swallows them again. The system reaches its first `sync()` with zero Tier 1 samples — the `degradedTier` fallback (Section 4.2) — and assessments fail closed (`isSecure == false`). Correct, but the device can never reach `verified` until the OS clock is externally corrected.

**Why the library does not yet self-rescue on trunk.** The naive fix is unavailable and the real fix is unimplemented:

1. **No privilege to set the clock.** `NtpSource.getTime` (`lib/src/sources/ntp_source_io.dart`) computes an offset and applies it to `DateTime.now()` to *report* a corrected sample; it does not — and an unprivileged process cannot — write the OS clock. A correct NTP sample therefore does not move the clock rustls reads.
2. **The engine does not yet thread a verification-time override.** The pinned `package:nts` exposes the optional `verificationTimeMs` parameter on `NtsClient.query` / `NtsClient.warmCookies` (and the top-level `ntsQuery` / `ntsWarmCookies` wrappers) — a coarse-corrected "validate the cert as of *this* instant" hint handed to the rustls verifier in place of the system clock. The primitive is available; what remains is the engine orchestration that supplies it on the cold-start retry.

**Target rescue flow (`trusted_time-m8t`).** The engine gains a cold-start Pre-Sync step that runs *before* the NTS warm fan-out when (a) there is no persisted anchor and (b) a first warm attempt failed in `TimeoutPhase.tls`:

```text
cold start, no persisted anchor
  → warmAllSources()  ── all NTS-KE fail in TimeoutPhase.tls ──┐
                                                               │  (skew signature)
  → preSync(): query unauthenticated NTP / HTTPS              │
       → coarse offset Δ  (Tier 3, NtsAuthLevel.none)          │
  → warmAllSources(verificationTime: now + Δ)  ←───────────────┘
       → NTS-KE cert window checked against (now + Δ)
       → handshake succeeds → genuine verified sample
```

The `nts`-side primitive is a per-handshake verification-time override — the optional `verificationTimeMs` on `warmCookies` / `query` (and the top-level `ntsWarmCookies` / `ntsQuery` wrappers) that, when set, is handed to the rustls `ServerCertVerifier` in place of the system clock. It is present in the pinned `package:nts`, sibling to the trust-mode work in Section 1. The Layering invariant gains a row:

| Layer | File | Slice it enforces | Status |
|---|---|---|---|
| NTS-KE clock-skew rescue | `nts/rust/src/nts/ke.rs` (verifier time), `lib/src/sync_engine.dart` (Pre-Sync orchestration) | Cold-start handshake validates against a coarse unauthenticated offset; the offset never becomes `verified`. | **Pending `trusted_time-m8t`** — `nts` primitive present on the pinned dep; needs engine orchestration |

**Invariant preservation in the engine.** The Pre-Sync offset is carried as a transient bootstrap value, never as a `TimeSample` admitted to consensus. It does not enter Marzullo, does not define or intersect the truth box, and does not set `authLevel`. The only state it touches is the verification-time argument passed to the *next* warm attempt. A `verified` anchor is produced only if a real Tier 1 NTS-KE handshake then succeeds and its sample lands in the truth box per Section 4.2 — exactly as on a healthy device.

**Why skew detection keys on `TimeoutPhase.tls`.** A network outage and a clock-skew failure both prevent a `verified` sample, but only the latter is rescuable by a verification-time hint. Keying the Pre-Sync trigger on the TLS phase specifically (rather than "any warm failure") avoids burning an unauthenticated NTP round-trip on cold starts that failed for unrelated reasons (DNS, connect, KE record I/O), where the rescue cannot help.

## 5. Contract enforcement (`lib/trusted_time.dart`)

> **[Superseded by the assessment API]** Sections 5.1–5.3 originally specified enforcement through `getTime(requireSecure:)`, the `authLevel`/`isSecure` getters, and the `degradedTier` integrity event. That surface was unified into `TrustedTime.getAssessment()` after PR #49 landed; the text below records the current shape while preserving the original enforcement rationale.

### 5.1 Secure-boundary strictness

`TimeAssessment.isSecure` is `authLevel == NtsAuthLevel.verified`, and `authLevel` is derived from the active anchor's `ConsensusResult.authLevel`. The Section 4 admission rules ensure `ConsensusResult.authLevel == verified` implies the truth box was Tier-1-defined, which implies the contract held for this anchor. No further filtering at the assessment call site is needed — the fail-closed property propagates upward by construction: a degraded anchor can never mint an assessment with `isSecure == true`, and an unanchored engine mints assessments with `time == null`.

Strictness moved from a library throw (`TrustedTimeSecurityException` on `requireSecure: true`) to a caller-side gate on the snapshot. The guarantee enforced is identical; what changed is that the caller now receives the *reason* (`TrustStatusReason.degraded` plus the retained `authLevel`) instead of an exception message describing it.

### 5.2 `TimeAssessment.authLevel`

The assessment carries the active anchor's level in the binary `{verified, none}` shape. `isSecure` continues to delegate (`authLevel == verified`).

### 5.3 Degradation surfacing

Whenever Section 4's truth-box construction step 1 fails — Tier 1 quorum cannot form — the minted anchor carries `authLevel == none`, every assessment reports `TrustStatusReason.degraded`, and `SyncEngine` emits an explicit log warning at the degradation boundary. Consumers observe the posture at retrieval time and can react (pause anchor updates, alert, etc.). Degradation does not invalidate the anchor by itself: best-effort consumers still receive the degraded consensus via `TimeAssessment.time`, and strict consumers gating on `isSecure` reject it.

## 6. Trust Tiering documentation update

This design is accompanied by a "Trust Tiering" section appended to `doc/specification/secure-time-contract.md` (see the parallel commit). That section defines two consumer personas:

1. **Security-Conscious.** Gates on `TimeAssessment.isSecure`, defaults to bundled trust, accepts that managed-network deployments may fail closed.
2. **Operational-First.** Uses `TimeAssessment.time` whenever non-null, may opt into `usePlatformTrust: true` for managed-device deployments where the platform CA is the load-bearing trust anchor. Accepts that `verified` may never appear on `authLevel`; uses `confidence` for quality grading instead.

The design here is symmetric: both personas can coexist on the same release, distinguishing themselves at construction (`TrustedTimeConfig`) and at retrieval (how they read the assessment). The library does not pick a side; it surfaces the boundary explicitly and fails closed under explicit opt-in.

## Test obligations

Each implementation ticket lands with the tests it requires; the audit below names them at the ticket level. The cross-cutting tests this design *requires to exist before the implementation merges*:

1. **Mapping table coverage** (`test/nts_source_test.dart` or equivalent): every `TrustBackend` variant produces the correct `NtsAuthLevel`. Five cases.
2. **Tier 1 quorum forms truth box** (`test/sync_engine_tier_test.dart`, new file): given two Tier 1 samples that agree, the published consensus has `authLevel == verified` and Tier 2/3 samples outside the truth box are dropped.
3. **Tier 1 quorum fails to form** (same file): given zero Tier 1 samples, the published consensus is flagged `degradedTier` with `authLevel == none` (originally asserted via the since-removed `IntegrityEvent.degradedTier` emission).
4. **Secure boundary fails closed** (`test/security_policy_test.dart`, extension): with a `degradedTier` anchor, assessments report `isSecure == false` and `reason == degraded` (originally: `getTime(requireSecure: true)` threw `TrustedTimeSecurityException`).
5. **Custom roots round-trip** (`test/custom_roots_test.dart`, new file): a `customRootCerts`-configured engine talks to a test NTS server backed by a self-signed CA and produces `authLevel == verified` samples. Platform store is verified-uninvolved by asserting the active backend is `TrustBackend.custom`.
6. **Persistence migration** (`test/nts_auth_level_migration_test.dart`, extension): a persisted anchor stored under the three-variant ordinal scheme deserialises correctly with the deprecated `advisory` removed (ordinal `1` maps to `none`).
7. **Cold-start clock-skew rescue** (`test/cold_start_presync_test.dart`, new file; Section 4.6): a fake NTS source that throws `TimeoutPhase.tls` on the first warm and succeeds only when a verification-time hint is supplied yields a `verified` anchor solely after Pre-Sync — without the hint it stays `degradedTier`. The companion invariant case asserts the Pre-Sync NTP sample never appears in `ConsensusResult.participants` and never, on its own, raises `authLevel` to `verified`. The `nts` verification-time primitive it depends on is present in the pinned `package:nts` (see Section 4.6); the remaining work is the engine orchestration.

## Audit of existing tickets

The implementation surfaces interactions with three existing `bd` tickets:

- **`trusted_time-4em`** (SourceQualityTracker starvation guard unreachable). **Unaffected.** The bug is in `SyncEngine`'s consumption of `ranked()`, several layers below tier admission. The fix shape (tighten `ranked()` to return a subset, or drop the unreachable comprehension) is unchanged by this design.
- **`trusted_time-a4d`** (quality-tracker participation rate stuck at 1.0). **Mildly affected.** The fix already requires plumbing the full `samples` list into `_completeSync`. Once tier-aware admission lands, `participants` may include Tier 2/3 samples that intersected the truth box but were not part of the Tier-1-only first pass. The participation-rate calculation should treat *truth-box-intersection* as the success metric, not "made it into the final reduction". The ticket should be updated to call out the distinction so the fix lands consistent with the tier model.
- **`trusted_time-8os`** (release.yml tag glob). **Present, but a judgment call.** The ticket was closed on the premise that the fork "no longer carries `release.yml`" — that is factually wrong: `.github/workflows/release.yml` is present on `integration/bleeding-edge` and still triggers on the broad `'v[0-9]*'` glob. However, the file is **byte-identical to `upstream/main`** (it arrived via the upstream 2.1.0 sync and the fork has never diverged it), and its publish step is still wired to upstream's pub.dev trusted-publishing identity. The fork does not release through it — fork releases route through manual pub.dev publishing (`trusted_time-xb0`). So the residual exposure is narrow: a `v[0-9]*` tag pushed to the fork would fire the validate matrix (CI minutes) but could not publish. Tightening the glob fork-side would deliberately diverge an otherwise-inherited upstream file, creating a merge-conflict surface on every future sync. The disposition is therefore a trade-off (tighten/remove fork-side vs. leave it inherited), not a clear-cut "still applies"; the ticket is left closed pending a maintainer call.

## Implementation ordering

The tickets filed alongside this design have the following dependency shape; implementations should land in this order:

1. ✅ **Done.** `package:nts` `bundledOnly` + `custom` trust primitives (Section 1) — shipped as the additive `nts 5.1.0` minor.
2. ✅ **Done.** trusted_time pubspec pin to `nts` — `5.1.0` for the trust primitives (PR #42), bumped to `5.2.0` for the cold-start `verificationTimeMs` primitive (PR #44).
3. ✅ **Done.** `TrustedTimeConfig` field additions (Section 2) — `usePlatformTrust` / `customRootCerts` added, `bundledOnly` effective default, `ntsTrustMode` removed. Landed as `trusted_time-rjt`.
4. ✅ **Done.** `NtsAuthLevel.advisory` removal (upstream 2.1.0) + mapping table (Section 3) — landed in PR #47.
5. ✅ **Done.** Tier-aware Marzullo admission (Section 4) — landed in PR #48; supersedes `trusted_time-c8y`.
6. ✅ **Done.** Public API tightening (Section 5) — exception message update + `authLevel` doc refresh, landed in PR #49.

Each step landed as a separate PR against `integration/bleeding-edge` per `CONTRIBUTING.md`. The remaining `trusted_time-m8t` scope is the Section 4.6 cold-start rescue alone.

## References

- [`doc/research/trust-model-evolution.md`](../research/trust-model-evolution.md) — research that motivates the design.
- [`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md) — normative contract this design implements, including the "Trust Tiering" section added in parallel with this document.
- [`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md) — tier-aware Marzullo admission ADR; Section 4 here is its implementation.
- `lib/src/models.dart` (`TrustedTimeConfig`) — config surface changes (Section 2).
- `lib/src/sources/nts_auth_level.dart` — enum cleanup (Section 3).
- `lib/src/sources/nts_source.dart` — mapping table integration (Section 3).
- `lib/src/sync_engine.dart`, `lib/src/domain/marzullo_engine.dart` — tier admission (Section 4).
- `lib/trusted_time.dart` — public API enforcement (Section 5).
- `package:nts` — `rust/src/nts/ke.rs`, `rust/src/nts/trust_state.rs` — Rust backend extensions (Section 1).
- `package:nts` — `lib/src/api/models.dart` — `TrustMode` / `TrustBackend` Dart-side enum extensions (Section 1).
