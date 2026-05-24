# Trust Model Evolution

Status: Research (informational; supersedes the implicit trust-mode assumptions of pre-2.1.0 design)
Date: 2026-05-24
Related: [`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md), [`doc/adr/0001-nts-integration-strategy.md`](../adr/0001-nts-integration-strategy.md), [`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md)

## Summary

This document records the reasoning behind a structural shift in this fork's trust model for cryptographic time. The library's contract is to provide *cryptographically authenticated time* — time samples whose authenticity the receiving client can verify end-to-end. Pre-existing design assumed the platform certificate-authority store was the appropriate trust anchor for the NTS-KE TLS handshake. Examination of the corporate-TLS-inspection threat shape revealed that this assumption silently invalidates the library's stated authenticity property in any environment running TLS inspection — a substantial fraction of the library's target deployment surface.

The shift: cryptographic authentication of time samples is bound to a curated, library-bundled set of certificate authority roots, not to the platform store. Samples whose trust chain validates only via platform roots cannot be labelled as cryptographically verified, regardless of whether the underlying time value is correct.

This research-grade document covers the technical reasoning. The normative implications — what the library promises and how the API enforces it — live in [`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md).

## The original trust model

Pre-shift, the package relied on `rustls-platform-verifier` (via `package:nts`) for NTS-KE certificate validation. Rationale at the time:

- Platform vendors (Apple, Google, Microsoft, the Linux distribution maintainer) operate cert-store maintenance professionally: revocations land via OS updates, expired roots get retired, breached CAs get distrusted reliably.
- Coverage is wide enough to include regional CAs that bundled curated stores often exclude.
- Bundled trust stores stale on release; platform stores stay current.

Under a threat model that does not include corporate TLS inspection, all three points hold and the choice is correct. Under a threat model that does include it, all three are irrelevant — because the attacker's vector is precisely the trust the platform store extends.

## The structural problem: corporate TLS inspection

Most enterprise networks operate TLS-inspecting middleboxes (Palo Alto SSL Decrypt, Zscaler, Symantec ProxySG, Cisco Umbrella, and similar products). These appliances:

1. Are issued an internal root certificate authority by the corporate IT department.
2. Have that root installed in the platform trust store of every managed endpoint (typically via MDM / group policy).
3. Terminate outbound TLS connections at the egress, present a freshly-minted certificate for the destination signed by the internal root, decrypt the traffic for inspection / DLP / policy enforcement, and re-encrypt to the actual destination over a separate TLS session.

From the perspective of a TLS client on a managed endpoint, the certificate it receives validates cleanly — it chains to the corporate root, which the platform store trusts. There is no protocol-layer signal that the connection has been intercepted; the TLS handshake completes successfully and indistinguishably from a non-intercepted handshake.

The library has no way to tell that its TLS peer is the corporate firewall rather than (e.g.) Cloudflare. Validation against the platform store, by construction, cannot distinguish them.

This is not a malicious-actor framing. Most corporate TLS inspection is operationally benign — DLP, anti-malware, regulatory inspection. The point is not that IT departments are adversaries. The point is that the library's authenticity contract requires the receiving client to verify the trust chain end-to-end, and a chain whose root is a CA the corporate IT department installed cannot satisfy that requirement *regardless of intent*. The contract is broken by the *presence* of an intermediate trust anchor, not by any party's misuse of it.

## Why NTS specifically does not survive TLS inspection

NTS (RFC 8915) authenticates NTP messages via Authenticated Encryption with Associated Data (AEAD). The AEAD's keys are derived as follows:

1. Client and server complete a TLS 1.3 NTS-KE handshake.
2. Both sides run the RFC 5705 keying-material exporter on the resulting TLS session, producing two AEAD keys — `C2S` (client-to-server) and `S2C` (server-to-client).
3. The server packages encrypted cookies containing these keys (encrypted under the server's master cookie-encryption key) and returns them to the client.
4. Subsequent NTP queries between client and server use AEAD with C2S / S2C to authenticate the message payload, including the timestamp fields in the NTP header. The timestamp itself is *associated data* — authenticated but not encrypted.

The AEAD keys are deterministic functions of the TLS session keys. They are not derived from any long-term server key independent of the session.

In a TLS-MITM scenario, the firewall holds the TLS session master secret on both sides of its interception position. It can compute the RFC 5705 exporter output for both sessions and obtain valid AEAD keys for both. This means it can:

- Decrypt and re-encrypt NTS-protected NTP messages in flight.
- Substitute the timestamp field (which is associated data, authenticated but not encrypted by the AEAD).
- Recompute a valid AEAD tag under the appropriate session's key.
- Forward the modified message.

From either endpoint's perspective the AEAD validates and the message appears authentic. No protocol-level signal indicates that modification has occurred. The library's `verified` label, under the original trust model, was being applied to chains whose authenticity has been undermined by the firewall — a contract violation that occurs silently in TLS-inspecting environments.

This is not a limitation of NTS implementation quality. It is a structural property of NTS's design: the protocol binds its authentication keys to the TLS session whose root of trust is the platform CA store, and any party who can substitute a cert in that store can derive equivalent keys.

## HTTPS-Date does not survive either, for different reasons

HTTPS `Date:` header is a weaker proposition than NTS even before the MITM consideration:

- No application-layer signature over the timestamp value. The `Date:` header is a plaintext field with no integrity binding to a long-term server key.
- No freshness guarantee. Servers may serve cached responses without regenerating the `Date:` header for each request.
- One-second resolution per RFC 7231.
- No multi-timestamp exchange — no protocol-level way to estimate uncertainty from round-trip behaviour.

Under TLS inspection, the firewall trivially substitutes the `Date:` header. Under a non-inspecting threat model, HTTPS-Date still cannot be cryptographically authenticated; only the transport is authenticated, and the timestamp field is a side-channel courtesy value rather than a protocol payload.

The library cannot label HTTPS-Date samples as cryptographically verified under any threat model that distinguishes between transport-layer integrity and application-layer authenticity. `HttpsSource` produces `NtsAuthLevel.none` samples unconditionally; this is not a defect, it is the protocol's authenticity ceiling.

## Survey of MITM-resistant alternatives

The transports below derive their authentication property from a long-term signing key whose public half is known to the client out-of-band (e.g., bundled in the client binary or pinned at a known location). The key is not derived from the TLS session and cannot be obtained by a party who terminates the outer TLS. This is the structural property that makes them survive corporate TLS inspection.

### Roughtime (IETF draft `draft-ietf-ntp-roughtime`)

Server signs `{nonce, midpoint, radius}` with a long-term Ed25519 key. Client validates the signature against the server's public key, pinned in the client. The nonce is client-chosen and included in the signed payload, so the server cannot precompute or replay — a fresh response is required for each request.

- **MITM property**: structurally resistant. The firewall has no path to obtain the Ed25519 private key.
- **Deployment**: Cloudflare operates a public Roughtime server (`roughtime.cloudflare.com`). A historic Google deployment is no longer publicly available. UDP-only as deployed today.
- **Transport limitation**: UDP/123 (or similar) is blocked in most corporate networks. The protocol is transport-agnostic in principle; an HTTPS-tunnelled Roughtime relay is implementable but not publicly operated.

### RFC 3161 Time-Stamp Protocol (TSP)

Designed for legal-grade document timestamping. Client sends `Sign_TSA(hash(nonce))` request over HTTP or HTTPS. TSA returns a CMS `SignedData` token over `{hash, time, serial}` with the TSA's certified private key. Client validates the signature against the TSA's certificate (or the issuing CA, depending on pinning strictness).

- **MITM property**: structurally resistant. The TSA's private key is not derived from TLS and is not accessible to any party intercepting the transport.
- **Deployment**: multiple commercial and free public TSAs (DigiCert, Sectigo, FreeTSA, several country PKIs). Run on port 80 or 443.
- **Resolution**: one second is typical. TSAs are operationally tuned for legal-grade attestation, not for low-latency time queries.
- **Latency**: higher than NTS — full TSP handshake plus signature verification.
- **Suitability**: as a high-integrity fallback when NTS is unavailable. Not a primary source.

### Self-operated signed-payload relay

Client connects via HTTPS to a relay operated by the package maintainers. Relay queries upstream NTS / Roughtime servers from infrastructure where outbound UDP is open, validates the upstream responses, and re-signs `{client_nonce, timestamp}` with a long-term Ed25519 key whose public half is bundled in the package. Client validates against the bundled key, ignoring the outer TLS layer's authentication.

- **MITM property**: structurally resistant. The Ed25519 key is held only on relay infrastructure controlled by the package maintainers.
- **Deployment**: requires the maintainers to operate the relay indefinitely, manage key rotation, and accept long-term service commitments.
- **Resolution and latency**: controllable; can be made comparable to NTS.
- **Trust shift**: the user now trusts the package maintainers as an operational time authority. This is an additional concentration of trust beyond what NTS or Roughtime require, where the trust anchor is external (Cloudflare, NIST, etc.).

### Certificate Transparency log signed-tree-heads (cross-check only)

CT logs publish STHs signed by long-term log keys (known to browser vendors and embedded in CT-aware clients). The STH carries a timestamp field reflecting "when the log signed this tree."

- **MITM property**: structurally resistant. Log keys are not derivable from TLS.
- **Resolution**: hours to a day, bounded by the log's Maximum Merge Delay (typically 24h).
- **Suitability**: not a primary time source. Useful as a coarse sanity anchor to reject grossly-wrong primary samples in degraded conditions.

## Architecture A vs Architecture B: "NTS over HTTPS"

The fork's working hypothesis at the time of writing is to wrap NTS inside an HTTPS connection to traverse port-443-only corporate firewalls. There are two architectural shapes hidden under that phrase, with very different security properties.

### Architecture A — NTS-KE as HTTPS replacement

The NTS-KE TLS handshake is *replaced* with an HTTPS request body. NTS-KE messages travel as the body of an HTTPS POST; the "TLS session" that NTS uses for its RFC 5705 keying-material exporter *is* the outer HTTPS connection.

This does not change MITM exposure. The outer HTTPS session is the one the firewall terminates, and the firewall holds the keys derived from it. NTS-KE has been moved from port 4460 to port 443 and gained zero authentication property in the process.

### Architecture B — NTS tunnelled inside HTTPS

HTTPS is transport plumbing only. Inside the decrypted HTTPS stream, the client runs a *separate, nested* TLS handshake to the NTS-KE endpoint, terminating end-to-end with the real NTS server. The RFC 5705 exporter runs on the inner TLS session, not the outer one.

The determining property for Architecture B is the trust store used for *inner* TLS validation:

- **Inner TLS validated against the platform store**: equivalent to Architecture A. The corporate CA is in the platform store; the firewall can MITM the inner handshake just as it does the outer.
- **Inner TLS validated against a separate bundled trust store** that does not include the corporate CA: the firewall cannot present a cert that the inner client will accept. Its corporate-signed cert fails validation. The inner handshake either fails (detected) or the firewall forwards opaque bytes (in which case the client gets a genuine end-to-end TLS session, and the exporter output is unknown to the firewall).

Architecture B with a bundled inner-trust store is the only shape under which "NTS over HTTPS" provides meaningful MITM resistance. Architecture A is misleading; it provides the firewall-traversal property but not the authentication property.

### Server-side requirements for Architecture B

Architecture B requires a server that *speaks NTS-KE inside a tunnelled TLS session reached over HTTPS*. Cloudflare's public NTS-KE endpoint is not currently configured this way — they serve NTS-KE on port 4460 with no HTTPS wrapper. Architecture B in practice therefore means either:

- Persuading Cloudflare or another public NTS operator to add a tunnelled NTS-KE endpoint over port 443 (unlikely without significant push).
- Running an NTS-KE endpoint that accepts the tunnelled protocol on infrastructure operated by this fork's maintainers.

The second option collapses into the self-operated-relay model described above, with an NTS protocol shape rather than a Roughtime-shape signed-payload shape. MITM-resistance properties are equivalent in both shapes: bundled trust store + end-to-end-authenticated payload survives the corporate firewall, by construction, in either form. The choice between them is engineering ergonomics.

## Bundled vs platform trust stores

The reframing above puts the trust-store choice on the critical path. Considerations:

### Bundled trust store advantages (under the library's threat model)

- **Structural MITM resistance**: an attacker on the network path cannot inject a root that the bundled store would accept. The bundled store is compiled into the package binary and not reachable via runtime configuration on the user's machine.
- **Predictability**: validation behaviour is deterministic across deployment environments. Two clients running the same package version trust the same set of roots.
- **Auditability**: the bundled set is a fixed list, version-pinned, and can be reviewed at build time.

### Bundled trust store disadvantages

- **Staleness**: roots compiled into a release are frozen until the next package release. If a root is revoked, expires, or a CA is breached, the package continues to trust it until the maintainer ships an update.
- **Recovery latency**: fixing a bundled-root issue requires shipping a package release. Affected downstream applications must then upgrade and redeploy.
- **Coverage**: curated stores (e.g., `webpki-roots` sourced from Mozilla CCADB) intentionally exclude some regional or legacy CAs that platform stores include.
- **Trust concentration**: the package maintainer becomes a meaningful link in the trust chain. A malicious or compromised maintainer release can inject hostile roots into every downstream client.

### Platform trust store advantages

- Operational maintenance is delegated to the platform vendor, who has dedicated security teams and rapid revocation pipelines.
- Coverage is wide and includes regional / legacy CAs.
- Recovery is fast: OS-level security updates can drop a compromised root within hours of disclosure.

### Platform trust store disadvantages (under the library's threat model)

- Compromised by design in corporate-managed-endpoint environments. The corporate CA installed by IT is exactly the vector that defeats the library's authentication property.
- The library has no protocol-layer signal to distinguish "legitimate platform-trusted CA" from "corporate-injected CA."
- "Compromised" here means structurally — not "the corporate IT is malicious," but "the library cannot verify authenticity end-to-end from the data the library sees."

### The choice this fork makes

This fork accepts the bundled-store disadvantages — staleness, recovery latency, narrower coverage, maintainer trust concentration — in exchange for the structural authentication property the platform store cannot provide. The choice is deliberate, documented, and codified in the secure-time contract.

The reasoning generalises: when a library's contract is *cryptographic authentication of a payload*, the trust anchor should be one the *library* controls, not one the *operating system* controls. The operating system's authority over its trust store is rightful and useful for general web browsing; it is precisely the wrong shape for a library whose entire purpose is to authenticate a value the operating system has no opinion about.

## Open architectural decisions

This research surfaces several decisions that are not yet finalised. They will be addressed in follow-up ADRs once the specification in [`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md) is settled and field experience accumulates:

1. Whether this fork operates its own signed-payload relay service, or relies entirely on existing public infrastructure (NTS via bundled-CA validation; Roughtime via UDP where firewall policy permits; RFC 3161 TSP via HTTPS as fallback).
2. Whether to implement Architecture B (nested-TLS NTS-over-HTTPS) on the fork side, including the question of which public NTS-KE operators (if any) would accept the tunnelled protocol shape.
3. Bundled-root update cadence and the operational discipline this requires of maintainers (e.g., monthly `webpki-roots` refresh, CVE-driven hot-fix releases).
4. Whether the platform-store path is removed from the package entirely, or retained as an explicitly opt-in "best-effort time" tier that produces samples with `authLevel: none` and is clearly documented as not satisfying the secure-time contract.
5. Whether `package:nts`'s default trust-mode argument is flipped on the trusted_time fork's side, or whether a fork in `package:nts` itself is required to make the bundled-only mode the structural default.

## References

- RFC 8915 — Network Time Security for the Network Time Protocol
- RFC 5705 — Keying Material Exporters for Transport Layer Security
- RFC 3161 — Internet X.509 Public Key Infrastructure Time-Stamp Protocol
- `draft-ietf-ntp-roughtime` — Roughtime protocol
- [`doc/adr/0001-nts-integration-strategy.md`](../adr/0001-nts-integration-strategy.md) — original NTS integration design
- [`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md) — tier-aware Marzullo admission with NTS truth box
- ADR 0007 postscript (2026-05-23) — `NtsAuthLevel.advisory` removal
- [`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md) — normative contract this research informs
- Mozilla CCADB — source of the `webpki-roots` bundled CA set

