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
- An unauthenticated sample whose value is correct still cannot be admitted to the truth box. Per ADR 0007's tier-aware admission, it may be admitted to the *wider* consensus only if its interval intersects the authenticated truth box, but it cannot itself anchor that box.

The library's authentication contract is the precondition for the accuracy contract. Without authenticated samples, there is no truth box; without a truth box, no accuracy guarantee can be made. This is the architectural intent of ADR 0007.

## Consumer-facing API enforcement

The library's public API surfaces this contract through several mechanisms.

### `TrustedTime.getTime(requireSecure: true)`

Consumer indicates that the returned time must be cryptographically authenticated. The library is required to:

- Return a time value only if the underlying consensus was reached from samples that include at least one `verified` sample (more strictly, the consensus's truth box is defined by `verified` samples per ADR 0007).
- Throw `TrustedTimeSecurityException` if no `verified` sample is available.
- Never silently substitute a `none` sample's value when `requireSecure: true`.

This is the strict-mode path and is the recommended path for consumers whose use case depends on the authenticity property — audit logging, replay-attack protection, license enforcement, anti-rollback checks, certificate expiry validation, or any other purpose where a wrong-but-plausible timestamp would be a security defect.

### `TrustedTime.getTime(requireSecure: false)` (default)

Consumer accepts best-effort time. The library may return a time value derived from any combination of `verified` and `none` samples, subject to the consensus rules. The returned value should be treated as approximate and not relied on for authenticity-sensitive purposes.

This is the relaxed-mode path and is appropriate for consumers whose use case is purely operational — display, scheduling, non-security-sensitive event ordering, log timestamps, and similar.

### `TrustedTime.authLevel`

Consumer can inspect the authentication level of the current anchor without committing to a fetch. The value reflects the highest authentication level present in the consensus that produced the current anchor:

- `NtsAuthLevel.verified` if the anchor's consensus included at least one `verified` sample (and ADR 0007's truth-box-defined-by-NTS admission held).
- `NtsAuthLevel.none` if it did not.

### `TrustedTime.isSecure`

Consumer can inspect whether the current anchor is cryptographically authenticated. Equivalent to `authLevel == NtsAuthLevel.verified`.

### Integrity-event stream

The library may emit an `IntegrityEvent` of reason `degradedTier` (per ADR 0007's `degradedTier` event) when a sync cycle's NTS quorum cannot form. This signals to the consumer that, for the current cycle, the truth box could not be defined by authenticated samples and the consensus fell back to best-effort sources. Consumers reading this stream can adapt — for example, a security-sensitive client may pause anchor updates until a verified quorum returns.

Emission of `degradedTier` is informational. It does not, by itself, invalidate the contract: a consumer using `requireSecure: true` will still see `TrustedTimeSecurityException` rather than receiving a degraded value. The event exists for consumers who want operational visibility into authentication state without polling.

## Implementation requirements

To uphold this contract, the implementation must:

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

