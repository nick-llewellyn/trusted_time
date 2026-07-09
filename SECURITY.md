# Security Policy

## Supported Versions

The following versions of **TrustedTime** currently receive security updates:

| Version | Supported |
| ------- | --------- |
| 2.0.x   | ✅ Yes (Current) |
| 1.2.x   | ✅ Yes     |
| 1.1.x   | ⚠️ Critical fixes only |
| < 1.1   | ❌ No      |

---

## Threat Model & Guarantees

TrustedTime is designed to provide high-integrity time synchronization in adversarial environments. Our security model addresses the following threats:

> **In-depth:** the full threat model — the end-to-end trust chain (network → consensus → anchor persistence → monotonic projection), the background-sync hand-off, adversary tiers, residual risks (offline tampering, anchor replay, rooted devices), and integrator guidance — is documented in [`doc/security/threat-model.md`](doc/security/threat-model.md).

### 1. Local Tampering (System Clock Manipulation)
*   **Defense**: The engine anchors network-verified time to the device's hardware monotonic clock. Once an anchor is established, the output of `TrustedTime.now()` is immune to changes in the system wall clock.
*   **Integrity Safety**: An adaptive monitor detects Monotonic-to-Wall drift and triggers an immediate state purge and resync upon anomaly detection.

### 2. Network-Level Spoofing (MITM)
*   **Defense**: 
    *   **Consensus**: Multi-source quorum resolution ensures that a single compromised source cannot shift the time.
    *   **NTS (RFC 8915)**: Cryptographically authenticated NTP synchronization (TLS 1.3 handshake + AEAD verification) prevents spoofing of the time packets themselves.
    *   **Group Diversity**: The engine enforces group-aware quorum to prevent median-poisoning attacks from correlated sources (e.g., a single ASN).

### 3. Outlier Injection (Noisy Sources)
*   **Defense**: Adaptive MAD (Median Absolute Deviation) filtering rejects samples whose uncertainty exceeds 3x the median of the current set, preventing imprecise sources from bloating the consensus interval.

### Out of Scope: Rooted / Jailbroken Devices

TrustedTime's guarantees assume an intact operating system. On a rooted or jailbroken device, an attacker can execute code inside the app's own security context — using hardware-backed keys legitimately, patching process memory, or lying at the kernel interface that supplies the monotonic clock. No app-level time library can defend against this, and TrustedTime does not claim to.

**For high-security applications** (financial transactions, licensing enforcement, compliance timestamping), pair TrustedTime with:

*   **Root / jailbreak detection** on-device, so the app can refuse to operate — or degrade to a restricted mode — when the OS integrity it depends on is absent.
*   **Remote attestation** (Google Play Integrity, Apple App Attest), so your *backend* can reject time-sensitive claims from devices whose integrity cannot be verified. Security-critical time checks should be enforced server-side; treat the device-local trusted time as a UX and offline-behaviour aid, not the enforcement point.

See [Residual risks — R4](doc/security/threat-model.md#r4--root--compromised-os-t4) in the full threat model for the detailed analysis.

---

## Reporting a Vulnerability

If you discover a security issue that could affect the integrity, reliability, or trust guarantees of TrustedTime:

1. **Do not open a public issue.**
2. Open a **private security advisory** using GitHub's built-in security reporting feature.
3. Include:
   * A clear description of the issue
   * Steps to reproduce
   * Proof-of-concept (if available)
   * Affected versions

We aim to acknowledge valid reports within **48 hours** and will coordinate a fix before public disclosure.
