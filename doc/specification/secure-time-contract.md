# Secure Time Contract

Status: Specification (normative)
Date: 2026-05-24
Informed by: [`doc/research/trust-model-evolution.md`](../research/trust-model-evolution.md)
Related: [`doc/adr/0001-nts-integration-strategy.md`](../adr/0001-nts-integration-strategy.md), [`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md)

## Purpose

This document specifies the cryptographic-trust contract this library offers its consumers. It is the source of truth for:

- What `NtsAuthLevel.verified` means.
- When the library will or will not return time samples to consumers requesting cryptographic authentication.
- How the public API enforces these guarantees.

Implementation that does not uphold this contract is a defect. This specification supersedes any informal interpretation of `NtsAuthLevel` that predates the trust-model shift documented in [`doc/research/trust-model-evolution.md`](../research/trust-model-evolution.md).

## Implementation status

This contract is written in the present tense to describe the **target end state** under [ADR 0007](../adr/0007-hybrid-trust-model.md). Some guarantees are live on the current trunk; others are the acceptance criteria for the tiered-trust work tracked as `trusted_time-m8t`. Where the two diverge, the divergence is flagged inline with a **[Target — `trusted_time-m8t`]** marker.

**Live on trunk today:**

- `NtsAuthLevel` is the binary `{verified, none}` shape; the pre-2.1.0 `advisory` value is removed.
- `requireSecure: true` fails closed: `getTime` throws `TrustedTimeSecurityException` when the current anchor is not `verified`.
- `package:nts` is pinned at `^5.2.0` (PR #44). The trust primitives the target consumes — `TrustMode.bundledOnly`, `TrustMode.custom`, and an `NtsClient` `customRoots` parameter — were introduced in `nts 5.1.0` (PR #42) and are wired into `TrustedTimeConfig` as of `trusted_time-rjt`: `usePlatformTrust` and `customRootCerts` resolve through `effectiveTrustMode` to `bundledOnly` (the effective default), `platformOnly`, or `custom`.

**Target — `trusted_time-m8t` (not yet on trunk):**

- Per-sample `TrustBackend → NtsAuthLevel` mapping. Today `NtsSource` labels **every** successful NTS sample `verified`, regardless of which trust store authenticated the chain.
- Tier-aware truth-box admission in `MarzulloEngine`. Today the engine uses a **weakest-link** reduction: a single `none` participant collapses the consensus `authLevel` to `none`. The truth-box model — NTS defines the box, NTP/HTTPS are admitted only when they intersect it — is the target, not current behaviour.
- The `degradedTier` `IntegrityEvent` reason. Not yet a member of `TamperReason`.

## Definitions

**Time sample**: a `TimeSample` instance produced by a `TimeSource` implementation, carrying a `TimeInterval`, a source identifier, an authentication level, and optional trust-backend metadata.

**Verifiable end-to-end**: a property of the chain by which the receiving client establishes the authenticity of a time sample. The chain is verifiable end-to-end if, and only if, the client can trace it back to a trust anchor that is independently known to the client, without any intermediate party (network operator, TLS terminator, certificate authority not in the bundled set) being able to substitute for or impersonate the time source.

**Bundled trust anchor**: a certificate or public key compiled into the library at build time, not loaded at runtime from a platform-managed store, environment variable, configuration file, or other modifiable source.

**Cryptographically authenticated time**: a time sample whose authenticity has been established via a chain verifiable end-to-end against bundled trust anchors.

**Best-effort time**: a time sample that may be useful for clock synchronisation purposes but for which the library cannot establish end-to-end cryptographic authentication.

## The `verified` contract

A time sample is labelled `NtsAuthLevel.verified` if, and only if, **all** of the following conditions hold:

1. The sample originates from a source kind that supports end-to-end cryptographic authentication (presently: NTS via `package:nts`).
2. The cryptographic chain establishing the sample's authenticity validates *exclusively* against bundled trust anchors. The chain does not depend on the platform certificate store, the system root store, environment-variable-supplied roots, or any other root source modifiable on the deployment host.
3. All freshness and replay-prevention checks specified by the source protocol pass.
4. The authentication is independent of any intermediate transport-layer interception position. Equivalently: a corporate TLS-inspecting middlebox could read the bytes of the exchange and still not be able to produce a sample that satisfies conditions 1–3.

A time sample that meets all conditions is labelled `NtsAuthLevel.verified`, and the library represents to the consumer that the sample carries cryptographic authentication of the timestamp value.

## Failure policy: fail closed

A time sample that does not satisfy the conditions above **must** be labelled `NtsAuthLevel.none`. This applies regardless of whether transport-layer security succeeded. Specifically:

- A sample from an NTS source whose chain validates only via the platform store, but not via the bundled trust anchors, is `NtsAuthLevel.none`. Even though the platform-level TLS handshake completed and the value may be correct, the library cannot represent the authentication to the consumer as cryptographic — and silently labelling it `verified` would be a contract violation.
- A sample from an HTTPS source (`HttpsSource`) is `NtsAuthLevel.none` unconditionally. HTTPS provides transport confidentiality but no application-layer signature over the timestamp; the library cannot authenticate the timestamp value end-to-end through HTTPS as the protocol exists today.
- A sample from an NTP source is `NtsAuthLevel.none` unconditionally. The protocol provides no authentication.

The library does not have an intermediate authentication level. The pre-2.1.0 `NtsAuthLevel.advisory` value, which served such an intermediate purpose, was removed in the v2.1.0 upstream sync (see ADR 0007 postscript 2026-05-23). Re-introduction is out of scope for this contract.

A consumer that requests cryptographically authenticated time and receives no `verified` sample receives, depending on the API path, either an error or a clearly-labelled `none` sample. The library does not silently downgrade. See [Consumer-facing API enforcement](#consumer-facing-api-enforcement) below.

## Separation of authentication and accuracy

The library treats two properties as distinct, even though both must hold for a consumer to safely use a time value:

### Authentication (per-sample, cryptographic, binary)

- **Definition**: did this sample come from the source it claims to come from, with no intermediate party able to substitute?
- **Mechanism**: cryptographic chain validation against bundled trust anchors. NTS AEAD verification over the NTP message. Per-query freshness via nonce or equivalent.
- **Library responsibility**: enforced strictly. A sample either has it (`verified`) or it does not (`none`).
- **Scope of guarantee**: this property holds for an individual sample independently. It does not require multiple sources or consensus.

### Accuracy (across multiple samples, statistical, graded)

- **Definition**: does the timestamp value reflect actual UTC within a known uncertainty bound?
- **Mechanism**: Marzullo-style consensus across multiple authenticated samples from independently-operated sources, as specified in ADR 0007. Outliers are filtered; the truth box is defined by the intersection of authenticated samples.
- **Library responsibility**: enforced statistically. A consensus result carries a confidence level that reflects the diversity and agreement of the contributing samples.
- **Scope of guarantee**: this property is a function of the sample population. A single authenticated sample provides no accuracy guarantee, only the authenticity property above.

### Composition

These properties are orthogonal and compose at the consensus layer:

- An authenticated sample whose clock is wrong appears as an outlier in the Marzullo sweep and is filtered out.
- Multiple authenticated samples that agree define a credible time interval.
- An unauthenticated sample whose value is correct still cannot be admitted to the truth box. Per ADR 0007's tier-aware admission, it may be admitted to the *wider* consensus only if its interval intersects the authenticated truth box, but it cannot itself anchor that box. **[Target — `trusted_time-m8t`]** On the current trunk the engine instead applies a weakest-link reduction: an unauthenticated participant downgrades the consensus `authLevel` to `none` rather than being intersection-gated. The intersection model described here is the ADR 0007 target.

The library's authentication contract is the precondition for the accuracy contract. Without authenticated samples, there is no truth box; without a truth box, no accuracy guarantee can be made. This is the architectural intent of ADR 0007.

## Cold-start bootstrapping and the NTS circular dependency

NTS-KE runs over TLS 1.3, and TLS certificate validation checks the server certificate's validity window (`notBefore` / `notAfter`) against the **host's current clock**. This creates a bootstrapping paradox at cold start: the library exists to obtain trustworthy time, but obtaining a `verified` sample requires a TLS handshake that itself presupposes an already-approximately-correct clock.

When a device cold-starts with a grossly incorrect system clock — a depleted CMOS battery resetting to the epoch, a manual user change, a factory-reset wearable — the NTS-KE certificate appears expired or not-yet-valid, the handshake fails in its TLS phase (`package:nts` surfaces this as `NtsError.timeout(TimeoutPhase.tls)` or a chain-validation error), and **no `verified` sample can be produced**. The very condition the library is meant to correct blocks the only mechanism that would correct it authentically.

### Trunk behaviour today: no rescue, fail closed

On the current trunk the library has no mechanism to break this cycle:

- It runs unprivileged and **cannot set the host clock**. Correcting the OS clock is the platform's responsibility (an OS NTP daemon, manual user action, carrier/NITZ time), not the library's.
- The engine does not yet orchestrate a verification-time rescue. The pinned `package:nts` exposes the `verificationTimeMs` override on `NtsClient.query` / `NtsClient.warmCookies` (and the top-level `ntsQuery` / `ntsWarmCookies` wrappers) — the primitive that would let the handshake check the certificate's validity window against a coarse-corrected estimate rather than the broken clock (see [Pre-Sync rescue](#pre-sync-rescue-target)) — but nothing on trunk supplies it: cold-start warm-up still hands every NTS-KE handshake the host clock.

The resulting behaviour is contract-correct, if degraded: NTS-KE fails, the warm / query catch path swallows the failure (it is indistinguishable from any other handshake failure), `authLevel` stays `none`, and `getTime(requireSecure: true)` **fails closed** with `TrustedTimeSecurityException`. Unauthenticated NTP / HTTPS samples may still serve `requireSecure: false` callers as best-effort time, but the `verified` path remains unavailable until some external agent brings the host clock back inside the certificate validity window.

### Pre-Sync rescue (target)

> **[Target — `trusted_time-m8t`]**

The target architecture breaks the cycle without ever weakening the authentication contract, via a bounded **Pre-Sync** phase:

1. **Detect the paradox.** A cold start with no persisted anchor whose NTS-KE handshakes fail specifically in the TLS phase is the signature of clock skew — as distinct from a network outage, which fails earlier in DNS / connect (`TimeoutPhase.dnsTimeout` / `TimeoutPhase.connect`).
2. **Obtain a *coarse* offset from an unauthenticated source** (NTP, or an HTTPS `Date` header). This offset is operational scaffolding only.
3. **Feed the coarse offset into the NTS-KE handshake as a verification-time hint**, so the TLS layer checks the certificate's validity window against the coarse-corrected estimate rather than the host clock. The handshake can then succeed and produce a genuinely `verified` sample, anchored end-to-end against the library-controlled trust store exactly as on a healthy device.

Step 3 requires a per-handshake verification-time override threaded down to the rustls certificate verifier. `package:nts` provides exactly this as an optional `verificationTimeMs` parameter on `NtsClient.query` / `NtsClient.warmCookies` (and the top-level `ntsQuery` / `ntsWarmCookies` wrappers): when set, it substitutes a caller-supplied timestamp for the TLS verifier's "current time" while checking certificate validity windows — and only that check; the returned NTP timestamp, AEAD keying, and cookie contents are unaffected. The primitive is present in the pinned `package:nts`, parallel to the trust-mode work documented in [`doc/design/tiered-trust-implementation.md`](../design/tiered-trust-implementation.md) §1; the only remaining gate is the `trusted_time-m8t` engine work. The library will not — and on an unprivileged process cannot — substitute "set the OS clock" for this primitive.

### Trust invariant preservation

The Pre-Sync rescue is **operational-only** and changes nothing about what the library is willing to call `verified`:

- The coarse NTP / HTTPS sample used to rescue the handshake is, and remains, `NtsAuthLevel.none` — Tier 3 under ADR 0007. It is never promoted, never admitted to the truth box, and never anchors consensus.
- A Pre-Sync that has run does **not** satisfy `requireSecure: true`. Strict-mode callers continue to receive `TrustedTimeSecurityException` until a *subsequent* NTS-KE handshake (Tier 1) succeeds and its sample lands inside the truth box. The rescue produces the *opportunity* for a `verified` sample; it does not produce the verified sample itself.
- The rescue widens *availability of the handshake*, not the set of conditions under which a sample is labelled `verified`. The fail-closed boundary specified in [Failure policy: fail closed](#failure-policy-fail-closed) is untouched: it governs which timestamps the library represents as authenticated, not whether the clock may be coarsely nudged to let a TLS handshake proceed.

In short: Pre-Sync may *enable* trust, but it can never *be* trust.

## Consumer-facing API enforcement

The library's public API surfaces this contract through several mechanisms.

### `TrustedTime.getTime(requireSecure: true)`

Consumer indicates that the returned time must be cryptographically authenticated. The library is required to:

- Return a time value only if the current anchor is `verified`. **On trunk today** this requires the anchor's `ConsensusResult.authLevel` to be `verified`, which under the engine's weakest-link reduction means *every* quorum participant was `verified` — a single `none` participant collapses the anchor to `none`. **[Target — `trusted_time-m8t`]** Under ADR 0007 this tightens to a truth box *defined by* `verified` samples, with Tier 2/3 samples admitted only when their intervals intersect it.
- Throw `TrustedTimeSecurityException` if no `verified` sample is available.
- Never silently substitute a `none` sample's value when `requireSecure: true`.

This is the strict-mode path and is the recommended path for consumers whose use case depends on the authenticity property — audit logging, replay-attack protection, license enforcement, anti-rollback checks, certificate expiry validation, or any other purpose where a wrong-but-plausible timestamp would be a security defect.

### `TrustedTime.getTime(requireSecure: false)` (default)

Consumer accepts best-effort time. The library may return a time value derived from any combination of `verified` and `none` samples, subject to the consensus rules. The returned value should be treated as approximate and not relied on for authenticity-sensitive purposes.

This is the relaxed-mode path and is appropriate for consumers whose use case is purely operational — display, scheduling, non-security-sensitive event ordering, log timestamps, and similar.

### `TrustedTime.authLevel`

Consumer can inspect the authentication level of the current anchor without committing to a fetch. The value is the active anchor's `ConsensusResult.authLevel`. **On trunk today** that is the *weakest-link* reduction across the quorum:

- `NtsAuthLevel.verified` only when **every** participating sample is `verified`.
- `NtsAuthLevel.none` otherwise — any single unauthenticated participant downgrades the anchor.

**[Target — `trusted_time-m8t`]** Under ADR 0007's truth-box admission the level instead reflects a Tier-1-defined box: `verified` when the box was anchored by NTS (`verified`) samples and held per the intersection rules above.

### `TrustedTime.isSecure`

Consumer can inspect whether the current anchor is cryptographically authenticated. Equivalent to `authLevel == NtsAuthLevel.verified`.

### Integrity-event stream

**[Target — `trusted_time-m8t`]** The library will emit an `IntegrityEvent` of reason `degradedTier` when a sync cycle's NTS quorum cannot form. This signals to the consumer that, for the current cycle, the truth box could not be defined by authenticated samples and the consensus fell back to best-effort sources. Consumers reading this stream can adapt — for example, a security-sensitive client may pause anchor updates until a verified quorum returns.

`degradedTier` is named in [ADR 0007](../adr/0007-hybrid-trust-model.md) §2 but is **not yet a member of `TamperReason`** on trunk. Until it lands, `onIntegrityLost` emits only the existing reasons (`systemClockJumped`, `timezoneChanged`, `deviceRebooted`, `forcedNtpSync`, `unknown`), and the quorum-degradation signal is unavailable.

Once landed, emission of `degradedTier` is informational. It does not, by itself, invalidate the contract: a consumer using `requireSecure: true` will still see `TrustedTimeSecurityException` rather than receiving a degraded value. The event exists for consumers who want operational visibility into authentication state without polling.

## Implementation requirements

To uphold this contract, the implementation must:

> **[Status]** Requirements 1 and 3 are the core of `trusted_time-m8t` and are *not yet met on trunk*: `NtsSource` currently labels every successful NTS sample `verified` without consulting the trust backend. Requirements 2, 4, 5, and 6 describe invariants the implementation must preserve as the per-sample mapping lands.

1. **Configure the underlying NTS client (`package:nts`) to validate exclusively against bundled trust anchors** on the path that produces `verified` samples. The platform-store-backed validation modes of `package:nts` are not permitted on this path. If a `package:nts` mode that mixes bundled and platform validation must be used (e.g., for compatibility with a specific deployment surface), the library wraps the result and labels it `NtsAuthLevel.none` regardless of `package:nts`'s success report.
2. **Pin the bundled trust anchor set** to a known, audited source (e.g., `webpki-roots` at a pinned version) and document the version, source, and update cadence in the package's release notes.
3. **Emit `verified` only from time-source code paths that have established the chain per this contract.** The default in `TimeSample` (`NtsAuthLevel.none`) is the correct fallback for any source that does not explicitly establish end-to-end verification.
4. **Surface trust-backend information** in `TimeSample.trustBackend` as informational metadata. The field does not, by itself, justify a `verified` label; the label is justified by the chain having been validated against bundled anchors, regardless of which backend performed the validation.
5. **Fail closed on `requireSecure: true`** when no `verified` sample is available in the current consensus. The default behaviour for `requireSecure: false` consumers may return best-effort time, but only with the authentication level accurately reflected in the returned anchor.
6. **Reject silent downgrades.** No code path in the library that produces `verified` samples may fall back to platform-trust validation on chain failure. The correct response to a bundled-trust validation failure is to discard the sample (treating it as if the source had timed out) — not to retry with a weaker trust store.

## What this contract does not promise

- **Accuracy of `verified` samples.** A `verified` sample's timestamp may be wrong. Accuracy is the consensus engine's responsibility. A single authenticated source whose clock is wrong will be admitted to consensus and filtered out by Marzullo only if other sources disagree with it.
- **Availability in corporate-managed-network environments.** In environments where NTS-KE traffic is intercepted, blocked, or restricted to platform-CA validation, the library's contract is satisfied by returning `none` samples and (under `requireSecure: true`) by failing rather than misrepresenting. Consumers in such environments who require time service must either (a) accept best-effort time via `requireSecure: false`, (b) deploy alongside a MITM-resistant transport (Roughtime, RFC 3161 TSP, or a signed-payload relay; see [`doc/research/trust-model-evolution.md`](../research/trust-model-evolution.md)), or (c) obtain IT allowlisting that bypasses TLS inspection for the library's traffic.
- **Resistance to compromise of the package distribution path.** If the published package itself contains hostile bundled trust anchors, the contract collapses. Mitigation is out of scope for the library; consumers must trust package distribution channels (pub.dev signatures, signed releases) independently.
- **Freshness of bundled trust anchors.** Maintenance of the bundled set is the package maintainer's responsibility; consumers who require fresh revocation handling should monitor package releases. Stale roots remain trusted until the next release.
- **Authentication of HTTPS or NTP samples.** These source kinds are useful for accuracy contribution under ADR 0007's tier-aware admission, but they are *never* `verified` and are never load-bearing for the authentication contract.

## Test obligations

Conformance to this specification is checked by:

- `test/security_policy_test.dart` — covers `requireSecure: true` enforcement at the `getTime` and `isSecure` boundary. Any new authentication-affecting API surface must add equivalent coverage.
- `test/nts_auth_level_migration_test.dart` — covers the binary `{verified, none}` enum shape and the persisted-anchor ordinal migration path. Any future enum change must update this test.
- Implementation-level tests that the bundled-trust-store validation path actually rejects platform-trusted-but-not-bundled chains. These tests are required when `package:nts` is updated, when the bundled root set is refreshed, or when the trust-mode configuration is changed in the library's construction of `NtsClient`.

A change that alters the conditions under which `NtsAuthLevel.verified` is emitted is a *contract-changing* change. Such a change requires:

- A test that exercises the new condition explicitly.
- An update to this specification document (this file) and to its referenced ADRs.
- A note in the CHANGELOG identifying the contract change.

## References

- [`doc/research/trust-model-evolution.md`](../research/trust-model-evolution.md) — the research that motivates this contract
- [`doc/adr/0001-nts-integration-strategy.md`](../adr/0001-nts-integration-strategy.md) — NTS integration strategy (original; partially superseded by this contract on the trust-store question)
- [`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md) — tier-aware Marzullo admission with NTS truth box
- ADR 0007 postscript (2026-05-23) — NtsAuthLevel binary migration
- RFC 8915 — Network Time Security
- RFC 5705 — TLS keying-material exporters
- `lib/src/sources/nts_auth_level.dart` — current implementation of the `NtsAuthLevel` enum
- `lib/src/trusted_time_impl.dart` — current `isSecure` and `authLevel` getters
- `lib/trusted_time.dart` — public API surface (`getTime`, `requireSecure`, `authLevel`, `isSecure`)
- `test/security_policy_test.dart` — current `requireSecure: true` enforcement tests
- `test/nts_auth_level_migration_test.dart` — current binary-enum migration tests


## Trust Tiering

This section adds the consumer-persona framing for the tiered trust model whose end-to-end implementation is documented in [`doc/design/tiered-trust-implementation.md`](../design/tiered-trust-implementation.md). The two personas are not separate code paths — the same library implements both — but they configure the engine differently and read its outputs with different expectations.

> **[Partially implemented — `trusted_time-rjt` / `trusted_time-m8t`]** The persona *config surface* below (`usePlatformTrust`, `customRootCerts`) is **live on trunk** as of `trusted_time-rjt`, which also flipped the effective default to `bundledOnly` and removed the earlier single `ntsTrustMode` field. The *engine behaviour* these personas reference — tier classification, truth-box admission, and the `degradedTier` event — is **not yet wired** (tracked by `trusted_time-m8t` and downstream tickets), so those points remain marked **[Target — `trusted_time-m8t`]** inline.

### Persona: Security-Conscious (Bundled / Custom)

**Configuration shape:**

```dart
const TrustedTimeConfig(
  // usePlatformTrust: false (the default)
  // customRootCerts: const [] (the default)
  ntsServers: ['time.cloudflare.com'],
)
```

The bundled `webpki-roots` set is the default anchor; no trust field needs to be set. For deployments with caller-controlled roots (private NTS-KE infrastructure, regulated environments that require pinned anchors), supply them via `customRootCerts`:

```dart
const TrustedTimeConfig(
  customRootCerts: <int>[...myRootsPem],
  ntsServers: ['time.internal.example.com'],
)
```

**Library behaviour for this persona:**

- Every NTS handshake runs against a library-controlled trust store: bundled `webpki-roots` (default) or `customRootCerts`. The platform store is not consulted.
- Successful NTS samples carry `NtsAuthLevel.verified` and form the Tier 1 truth box.
- **[Target — `trusted_time-m8t`]** Marzullo's truth-box construction is anchored exclusively by Tier 1 samples. Tier 2/3 contribute to consensus only when their intervals intersect the truth box. On trunk today the reduction is weakest-link, not truth-box-gated.
- `requireSecure: true` is honoured strictly: if the cycle's Tier 1 quorum fails to form, `getTime(requireSecure: true)` throws `TrustedTimeSecurityException`.
- **[Target — `trusted_time-m8t`]** The `degradedTier` `IntegrityEvent` fires when Tier 1 quorum fails; consumers can read it from `onIntegrityLost` and pause anchor consumption. `TamperReason.degradedTier` is not yet a member of the enum on trunk.
- **[Target — `trusted_time-m8t`]** **Cold-start clock skew is rescued, not refused.** If the device boots with a grossly wrong clock and NTS-KE fails in its TLS phase, the engine runs a bounded unauthenticated Pre-Sync to coax the handshake into the certificate's validity window (see [Cold-start bootstrapping and the NTS circular dependency](#cold-start-bootstrapping-and-the-nts-circular-dependency)). This persona **allows** the rescue: it is operational-only and never relaxes the `verified` boundary. Strict fail-closed is preserved — `requireSecure: true` still throws until a *real* Tier 1 sample lands in the truth box. Refusing the rescue would permanently deny `verified` time to skewed-clock devices for no security gain, since the Pre-Sync sample is itself never `verified`.
- In TLS-inspecting / managed-network deployments where a corporate CA is required, this persona's NTS sources will fail — the bundled trust store does not include corporate CAs by design. The contract is satisfied by failing closed, not by misrepresenting platform-validated samples as `verified`.

**Use this persona when:** authenticity is load-bearing for the consumer's logic (cryptographic signing, attestation, audit timestamps, certificate validity windows, replay protection, rate-limit windows whose integrity matters under adversarial conditions). The deployment must tolerate fail-closed behaviour on corporate networks; if it cannot, see the Operational-First persona.

### Persona: Operational-First (Platform)

**Configuration shape:**

```dart
const TrustedTimeConfig(
  usePlatformTrust: true,
  ntsServers: ['time.cloudflare.com'],
)
```

**Library behaviour for this persona:**

- Every NTS handshake runs against the platform / OS trust store via `rustls-platform-verifier`. Bundled roots are not consulted.
- Successful NTS samples carry `NtsAuthLevel.none` regardless of whether the handshake succeeded. `TimeSample.trustBackend` is populated with `TrustBackend.platform` (or `platformWithHybridFallback` on Android) so telemetry consumers can distinguish platform-mediated NTS from plain NTP / HTTPS.
- Tier 1 (`verified`) samples will not be produced under this configuration. The truth box is never formed; Marzullo falls back to single-tier reduction over all available samples — the legacy pre-tier behaviour.
- `requireSecure: true` will always fail under this configuration. Consumers using this persona must call `getTime(requireSecure: false)` (or `TrustedTime.now()`) and accept best-effort time.
- `authLevel` will be `NtsAuthLevel.none`; `isSecure` will be `false`. Quality grading still works: `ConfidenceLevel` reflects source diversity and population depth, independent of authentication.
- Managed-network deployments (corporate MDM, pinned roots) work: the platform store includes the deployment's CAs, NTS handshakes succeed, the engine produces samples, consensus forms.
- **[Target — `trusted_time-m8t`]** Cold-start clock skew never affects this persona's *authentication* posture — it produces no `verified` samples regardless — but the same unauthenticated Pre-Sync still benefits operational accuracy: a coarse offset lets platform-mediated NTS-KE handshakes complete on a skewed-clock cold start, so their samples (still `none`) can contribute to consensus precision instead of failing in the TLS phase.

**Use this persona when:** the deployment's network policy *requires* platform-trust traversal (corporate MITM appliance, MDM-installed root, regulated environment that mandates platform-store conformance), and the consumer is comfortable with operational best-effort time rather than cryptographic authenticity. The persona honours the contract by emitting `none` rather than misrepresenting the trust path.

### Persona selection at construction time

The two personas are mutually exclusive at construction:

| `usePlatformTrust` | `customRootCerts` | Resulting persona | Effective `nts.TrustMode` |
|---|---|---|---|
| `false` (default) | `[]` (default) | Security-Conscious (bundled) | `bundledOnly` |
| `false` | non-empty | Security-Conscious (custom) | `custom` |
| `true` | `[]` | Operational-First | `platformOnly` |
| `true` | non-empty | — | rejected on resolve |

`usePlatformTrust: true` + non-empty `customRootCerts` is structurally ambiguous (two trust sources, no defined precedence) and is rejected with `ArgumentError`. The `const` constructor cannot reject it — list emptiness is not a const-evaluable expression — so the combination is caught when `effectiveTrustMode` is resolved (during `SyncEngine` construction, before any source is built). It therefore cannot occur on a live engine.

> **[Implemented — `trusted_time-rjt`]** This table is live on trunk via the `TrustedTimeConfig.effectiveTrustMode` resolver. The conflicting row (`usePlatformTrust: true` + non-empty `customRootCerts`) throws `ArgumentError` from `effectiveTrustMode`; because `SyncEngine` reads the resolver while building its per-source `NtsSource` list (each `NtsSource` constructs its `nts.NtsClient` lazily), an invalid config fails closed before any source is built. The `const` constructor cannot reject it directly — list emptiness is not a const-evaluable expression — so the resolver is the single enforcement point.

### What this section is *not*

- **A runtime switch.** The persona is fixed at `TrustedTime.initialize()`. A consumer that needs both shapes in the same process must instantiate two engines (the public API supports a single global instance, so this would require a custom integration; out of scope for the spec).
- **A confidence statement.** `ConfidenceLevel` and `NtsAuthLevel` are orthogonal. A Security-Conscious deployment can have low confidence (few sources, narrow geographic diversity); an Operational-First deployment can have high confidence (many sources, broad diversity). The personas describe the *trust path*, not the consensus quality.
- **A network-environment classifier.** Neither persona detects whether the device is on a TLS-inspecting network. Detection happens implicitly: the Security-Conscious persona's NTS handshakes succeed iff the environment permits end-to-end TLS to the configured NTS-KE endpoint. A `degradedTier` event followed by sustained Tier-1 quorum failure is the operational signal for "the network is hostile to my trust configuration"; reacting to that signal is the consumer's responsibility.

