# ADR 0003: Remove clear-text NTP from the package

- Status: **Accepted**
- Date: 2026-05-01
- Supersedes: portions of ADR 0001 §"Negative consequences" that accepted clear-text NTP in the default consensus pool

## Context

ADR 0001 left clear-text `NtpSource` in place alongside the new authenticated `NtsSource`, accepting that "default-configured NTP and HTTPS sources are not end-to-end authenticated" and relying on Marzullo consensus across multiple operators to bound on-path attacker influence.

That trade-off does not hold up against the package's stated threat model:

1. **Marzullo across forged NTP samples produces forged consensus.** Clear-text NTP runs over UDP/123 to arbitrary unicast IPs with no integrity protection. A motivated on-path attacker (compromised network, hostile Wi-Fi, ISP interception) can simultaneously rewrite responses from every clear-text NTP server in the pool. Marzullo's intersection guarantees a correct answer only when *fewer than half* of the samples are byzantine; on a single attacker-controlled link, that bound is trivially violated.
2. **The package contract is tamper-resistance.** Shipping a default that fails on the primary threat the package exists to defeat is dishonest framing, regardless of how the README hedges it.
3. **Better-authenticated alternatives are already in the engine.** `HttpsSource` is bound to a TLS handshake — a network attacker cannot forge the `Date` header without a valid certificate. `NtsSource` (RFC 8915) provides per-sample cryptographic authentication. Together they cover both broad-compatibility and high-precision use cases without the integrity gap.
4. **The package name (`trusted_time_nts`) advertises authenticated time.** Retaining a clear-text NTP default would contradict the rename rationale documented in ADR 0001 and the 1.0.0 CHANGELOG.

This ADR is being adopted before the first publish to pub.dev, so there is no prior published version that depended on the clear-text NTP path. The deletion ships as part of the initial 1.0.0 release rather than as a 2.x breaking change.

## Decision

Remove the built-in `NtpSource` implementation, the `TrustedTimeConfig.ntpServers` configuration field, the `TimeSourceKind.ntp` enum value, and the `package:ntp` dependency. The default consensus pool becomes:

- `ntsServers` — opt-in (empty by default).
- `httpsSources` — defaults to four independent operators (`google.com`, `cloudflare.com`, `apple.com`, `microsoft.com`) so a single endpoint failure still satisfies the default `minimumQuorum` of 2.
- `additionalSources` — host-supplied custom `TrustedTimeSource` implementations.

A consumer that genuinely needs clear-text NTP (closed network, legacy hardware) can implement `TrustedTimeSource` themselves over UDP/123 and inject it via `additionalSources`, accepting the integrity trade-off explicitly.

## Consequences

### Positive

- Default configuration no longer claims tamper-resistance it cannot deliver against the on-path threat model.
- Removes a transitive dependency (`package:ntp`) and ~60 lines of dead code that contradicted the package contract.
- Aligns the implementation with the package name and the rationale in ADR 0001.
- `httpsSources` default fan-out is widened from 2 to 4 operators, restoring single-failure tolerance against the `minimumQuorum: 2` default.

### Negative

- HTTPS-Date alone has 1-second resolution. Sub-second precision now requires opting into `ntsServers`. Documented in the README and the `httpsSources` doc-comment.
- `TimeSourceKind.ntp` is removed entirely; consumers writing their own NTP source must pick a different `kind` (e.g. `TimeSourceKind.custom`) when emitting samples. There is no public API user of this enum value outside this package's own (now-deleted) `NtpSource`, so the blast radius is limited.
- The `nts_live_test.dart` integration test continues to require the Rust-backed `package:nts` toolchain to load in the host process — pre-existing limitation, unchanged by this decision.

## Alternatives considered

- **Soft deprecation across one minor cycle** (`@Deprecated('use ntsServers')` on the field, ignored at runtime, removed in 2.0.0). Rejected: the field is a security defect; running it as a no-op silently degrades to an `httpsSources`-only pool without the consumer realising the threat model has shifted under them. A compile-time break with a documented migration is more honest.
- **Keep NTP behind an explicit `unsafe: true` flag.** Rejected on principle: opt-in foot-guns belong outside the package's surface. Consumers with that requirement should write their own `TrustedTimeSource` and own the trade-off.
- **Retain `TimeSourceKind.ntp` for downstream tagging.** Rejected per the user-supplied override on this work item: the package should provide *no* internal references to unauthenticated NTP. Consumers tagging custom NTP samples can use `TimeSourceKind.custom`, which is semantically accurate ("application-supplied custom source").
- **Defer until after the bootstrap publish.** Rejected: shipping 1.0.0 with the defective default and then breaking it in 2.0.0 burns a major version for a security correction the project knows it needs to make before any consumer adopts it. Folding the removal into 1.0.0 is cleaner and avoids retroactively documenting a default that should never have been published.

## Migration notes for downstream consumers

This ADR is paired with `1.0.0`, the first published release. There is no prior published version, so no migration path is required for users of `trusted_time_nts`. Users migrating from the upstream `trusted_time` package have the following replacements:

| Was…                                                     | Replace with…                                                |
|----------------------------------------------------------|---------------------------------------------------------------|
| `ntpServers: ['time.cloudflare.com']`                    | `ntsServers: ['time.cloudflare.com']`                         |
| `ntpServers: ['pool.ntp.org']` (no NTS support)          | rely on the default `httpsSources`, or supply a custom        |
|                                                          | `TrustedTimeSource` via `additionalSources`                   |
| Default-configured (no `ntpServers` argument)            | no action — defaults now use four HTTPS-Date operators        |

## Tracking

- Implemented on branch `feat/remove-clear-text-ntp`.
- ADR 0001 remains immutable as historical context for the original NTS-alongside-NTP decision; this ADR records the subsequent correction.
