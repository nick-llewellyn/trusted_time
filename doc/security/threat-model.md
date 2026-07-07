# Threat Model

Status: Reference (descriptive)
Date: 2026-07-07
Related: [`SECURITY.md`](../../SECURITY.md),
[`doc/specification/secure-time-contract.md`](../specification/secure-time-contract.md),
[`doc/adr/0002-headless-background-sync.md`](../adr/0002-headless-background-sync.md),
[`doc/adr/0007-hybrid-trust-model.md`](../adr/0007-hybrid-trust-model.md)

## Purpose

This document describes the end-to-end trust chain by which a time value
travels from a network time source to a `TrustedTime.now()` call, the
defenses at each stage, and — just as importantly — the attacks the
library does **not** defend against and why. It complements the
[Secure Time Contract](../specification/secure-time-contract.md), which
specifies what `NtsAuthLevel.verified` means normatively; this document
covers the wider system, including anchor persistence, the background-sync
hand-off, and the runtime integrity monitor.

The intended readers are integrators deciding whether the library's
guarantees fit their threat environment, and contributors evaluating
proposed hardening work against the boundaries described here.

## The trust chain

Every trusted time value is the product of a five-stage pipeline. Each
stage has its own trust boundary and its own adversary:

```
 (1) Network        NTS/NTP/HTTPS queries over the open internet
      │              adversary: on-path attacker, malicious server
      ▼
 (2) Consensus      Marzullo reduction with tiered admission
      │              adversary: minority of compromised sources
      ▼
 (3) Anchor         TrustAnchor {networkUtcMs, uptimeMs, wallMs, …}
      │              adversary: other apps, offline storage access
      ▼
 (4) Persistence    AnchorStore → FlutterSecureStorage
      │              (Keychain / Android Keystore-backed prefs)
      ▼
 (5) Projection     now() = networkUtcMs + Δmonotonic since anchor
                     adversary: system-clock manipulation, kernel
```

The background-sync path (ADR 0002) shares stages 1–4 with the foreground
engine: a headless isolate constructs a `SyncEngine`, runs one sync
cycle, and persists the resulting anchor through the same `AnchorStore`.
The next foreground launch warm-restores from that anchor at stage 5.
There is no IPC channel between the background isolate and the foreground
app — the encrypted store *is* the hand-off — so the security of the
hand-off reduces to the security of stages 3–4 plus the warm-restore
validation described below.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| `TrustAnchor` | Process memory + encrypted storage | The single source of truth; forging it forges all subsequent `now()` output |
| Bundled trust roots | Compiled into `package:nts` | Root of the NTS authentication chain; independent of the platform store |
| Monotonic uptime | Kernel (`SystemClock.elapsedRealtime` / mach absolute time) | The projection input; lying about it shifts time without touching the anchor |
| Background callback handle | SharedPreferences / UserDefaults (plain) | Selects which Dart entrypoint the OS scheduler invokes |

## Adversary tiers

The defenses below are organised against escalating adversary capability:

- **T1 — Network attacker.** Controls the network path (Wi-Fi AP, ISP,
  corporate middlebox) and/or some fraction of the queried time servers.
- **T2 — Co-resident attacker.** Another app on the same device, without
  root; can attempt cross-app storage access and backup manipulation.
- **T3 — Offline/physical attacker.** Can read or write device storage
  with the OS not running (recovery mount, forensic extraction, crafted
  backup restore).
- **T4 — Root/OS attacker.** Arbitrary code execution as root: can run
  code inside the app's security context, patch process memory, and lie
  at the kernel interface.

The library's designed trust boundary sits **between T3 and T4**: it
defends fully against T1–T2, partially against T3, and explicitly does
not claim to defend against T4. The rationale is in
[Residual risks](#residual-risks).

## Defenses by stage

### Stage 1 — Network authentication

- **NTS (RFC 8915)** is the only source kind that carries end-to-end
  cryptographic authentication: TLS 1.3 key establishment, then per-query
  AEAD verification over the NTP message with per-query freshness
  (unique cookies/nonces), which defeats both spoofing and replay of
  time packets on the wire.
- **Library-controlled trust roots.** NTS chains validate against the
  bundled `webpki-roots` set (or caller-supplied `customRootCerts`) —
  never the platform certificate store. A T1 attacker who has installed
  an MDM/user root on the device (the corporate-middlebox position)
  cannot mint a certificate the library will accept. This is normative:
  see the [Secure Time Contract](../specification/secure-time-contract.md).
- **NTP and HTTPS carry no authentication** and are labelled
  `NtsAuthLevel.none` unconditionally. They are precision/availability
  contributors, not trust anchors (ADR 0007).

### Stage 2 — Consensus

Authentication proves a sample came from the server it claims; consensus
defends against the servers themselves (or a subset of paths) being
wrong or malicious:

- **Tiered truth box** (ADR 0007): only `verified` NTS samples define
  the authoritative interval. Unauthenticated NTP/HTTPS samples are
  admitted to the Marzullo reduction only if their intervals intersect
  the NTS-defined truth box; a T1 attacker who owns every NTP response
  still cannot move the consensus outside what the NTS quorum attests.
- **Quorum requirements** (`minQuorumRatio`, `minimumQuorum`): a single
  compromised source cannot carry a cycle.
- **Group diversity** (`minGroupCount`): quorum members must span
  operator groups, blunting median-poisoning from correlated sources
  (e.g. one ASN answering for many hostnames).
- **MAD outlier filtering** and a hard `maxAllowedUncertaintyMs` cap
  reject imprecise or interval-bloating samples before reduction.
- **Fail closed.** If the Tier 1 quorum cannot form, the cycle is marked
  degraded (`TamperReason.degradedTier`), the anchor's auth level is
  pinned to `none`, and `getTime(requireSecure: true)` throws rather
  than silently downgrading.

### Stage 3–4 — Anchor at rest and the background hand-off

The persisted payload is small and fully enumerable — the anchor JSON
(`networkUtcMs`, `uptimeMs`, `wallMs`, `uncertaintyMs`, `authLevel`,
`confidence`) plus two offline-estimation timestamps:

- **Hardware-backed encrypted storage.** `AnchorStore` writes through
  `FlutterSecureStorage`: iOS Keychain, Android Keystore-encrypted
  preferences, DPAPI on Windows, libsecret on Linux. A T2 attacker is
  excluded twice over — by app sandboxing on the storage file and by
  key isolation on the encryption key.
- **Strict deserialization.** `TrustAnchor.fromJson` bounds-checks every
  field; malformed or corrupted entries are deleted and treated as
  "no anchor" (fail-closed to a fresh network sync) rather than being
  partially honoured.
- **The background hand-off inherits these properties.** The headless
  isolate and the foreground app are the *same OS identity* — same
  sandbox, same Keychain/Keystore access group. There is no channel to
  intercept: the background isolate writes the anchor, exits, and the
  foreground reads it back through the identical code path it uses for
  its own anchors. An attacker positioned "between" the two is by
  definition already inside the app sandbox, i.e. at least T3/T4.

### Stage 5 — Projection and runtime integrity

- **Monotonic anchoring.** `now()` is pure arithmetic:
  `networkUtcMs + (uptime_now − anchor.uptimeMs)`. The system wall
  clock is not an input, so changing it (Settings, `adb`, NITZ spoof)
  does not move trusted time.
- **Reboot detection on warm restore.** Before a persisted anchor is
  honoured, `checkRebootOnWarmStart` verifies the current uptime is not
  lower than the anchor's recorded uptime. A reboot resets the
  monotonic counter, invalidating the projection basis — the anchor is
  discarded and a fresh network sync is required.
- **Adaptive drift monitor.** While running, the `IntegrityMonitor`
  compares Δuptime against Δwall-clock (baseline every 5 min,
  tightening to 30 s after an anomaly). Divergence beyond 5 s emits
  `TamperReason.systemClockJumped`, purges the anchor, and forces a
  resync. Native signals (`TIME_SET`, timezone change, boot) feed the
  same event stream.

## Residual risks

These are the attacks the current design does not stop, in roughly
ascending order of required capability. Each entry notes whether a
known mitigation exists and, where one was considered and not adopted,
why.

### R1 — Offline anchor substitution (T3)

The anchor JSON carries no cryptographic binding to this app or device
session. An attacker who can write to the storage layer with the OS not
enforcing sandboxing — recovery-mode mount of the data partition, or a
crafted backup restore — can substitute a well-formed anchor with a
fabricated `networkUtcMs`. Platform storage encryption raises the bar
(the attacker must defeat or sidestep the Keystore/Keychain encryption,
not just edit a file) but is a confidentiality mechanism, not an
authenticity one.

**Known mitigation, not yet adopted:** an HMAC over the anchor payload
keyed from a hardware-backed, non-extractable key. This would close R1
outright — the attacker can modify ciphertext but cannot produce a
valid tag. It is deliberately scoped as *at-rest tamper evidence only*;
see R2 and R4 for why it does not extend the trust boundary further.
Partial incidental cover exists today: a substituted anchor whose
`uptimeMs` exceeds the device's current uptime is rejected by the
reboot check, and one that produces a large uptime/wall divergence
trips the drift monitor.

### R2 — Same-boot anchor replay (T3)

Capturing a *genuinely produced* anchor and restoring it later, within
the same boot session, passes every current check: the JSON is valid,
the uptime is plausible, and — notably — it would pass an HMAC too,
since the tag was legitimately generated. A MAC proves authenticity,
not freshness. Blocking replay requires binding anchors to session
state: a boot-count or monotonic write counter in the signed payload,
or key rotation on reboot. The reboot check gives a weak version of
this for free (an anchor from a previous boot is discarded), and a
replay that regresses time far enough may trip the drift monitor
indirectly, but a targeted same-boot replay is not detected.

### R3 — Structural NTS coverage gaps (environmental)

NTS-KE deployment is concentrated in EU/NA (ADR 0007). A device in
APAC/Africa/ME may be structurally unable to form a Tier 1 quorum. The
library fails closed — degraded cycles are labelled, `requireSecure`
throws — but "fails closed" means *unavailability*, and an attacker who
can block TCP/4460 selectively can force any device into the degraded
tier (a downgrade-by-denial attack). Consumers must decide per use case
whether degraded-tier time is acceptable; the library will not silently
substitute it where `verified` was requested.

### R4 — Root / compromised OS (T4)

Root access dissolves every boundary the preceding defenses rely on,
through at least four independent routes:

1. **Key usage without key extraction.** Hardware-backed keys cannot be
   read out of the secure element, but they can be *used* by any code
   executing in the app's security context. A root attacker hooks the
   process (or repackages it) and asks the Keystore to sign a forged
   anchor; the secure element complies. This is why an HMAC (R1) does
   not defend against T4 — the exact adversary it superficially targets
   is the one who can operate the key legitimately.
2. **Monotonic clock lies.** The uptime input to the projection comes
   from the kernel via a platform channel. An attacker who controls the
   kernel or interposes the channel shifts `now()` arbitrarily without
   touching the anchor at all. The drift monitor compares two values
   the same attacker controls.
3. **Process-memory patching.** Once the anchor is loaded and the engine
   is trusted, live `SyncClock` state can be patched in memory. No
   at-rest protection is relevant.
4. **Network-stack interposition.** Root can redirect the NTS sockets
   themselves; the bundled roots still prevent *impersonation* of the
   servers, but denial (forcing R3's degraded tier) is trivial.

No app-level mechanism repairs this: the key usage, the clock, and the
process memory all sit on the OS side of the trust boundary. Extending
trust beyond "the OS is intact" requires **remote attestation** (Play
Integrity / App Attest), which changes the architecture — a *server*
verifies device integrity and refuses time claims from compromised
devices — rather than hardening this one. That is out of scope for the
library and belongs to the consuming application's backend design.

### Summary matrix

| Attack | Tier | Defended today | With anchor HMAC |
|---|---|---|---|
| On-path spoofing / replay of time packets | T1 | ✅ NTS AEAD + freshness | ✅ |
| MDM/user-installed root CA (middlebox) | T1 | ✅ bundled roots only | ✅ |
| Minority of malicious/wrong servers | T1 | ✅ truth box + quorum + diversity | ✅ |
| Majority NTP poisoning | T1 | ✅ NTP cannot move the truth box | ✅ |
| NTS denial → degraded tier | T1 | ⚠️ fails closed, labelled (R3) | ⚠️ |
| Co-resident app reads/writes anchor | T2 | ✅ sandbox + Keystore/Keychain | ✅ |
| System wall-clock manipulation | T2 | ✅ monotonic anchoring + drift monitor | ✅ |
| Offline storage edit / backup forgery | T3 | ⚠️ encryption only (R1) | ✅ |
| Same-boot anchor replay | T3 | ❌ (R2) | ❌ needs freshness counter |
| Cross-boot anchor replay | T3 | ✅ reboot check | ✅ |
| Root: code exec in app context | T4 | ❌ (R4.1, R4.3) | ❌ |
| Root: kernel clock lies | T4 | ❌ (R4.2) | ❌ |

## Guidance for integrators

- **Treat `verified` + `high` confidence as "trustworthy against T1–T2,
  tamper-evident against most of T3".** That covers the dominant threat
  environment for unmanaged consumer devices: hostile networks and
  co-resident apps.
- **If your threat model includes T4 (rooted/jailbroken devices),**
  device-local time cannot be your enforcement point. Pair the library
  with remote attestation and perform security-critical time checks
  server-side; use the library's output for UX and offline behaviour.
- **Use `requireSecure: true`** for any decision where accepting
  unauthenticated time is worse than receiving an error, and handle
  `TrustedTimeSecurityException` explicitly.
- **Subscribe to `onIntegrityLost`** and treat `degradedTier`,
  `systemClockJumped`, and `deviceRebooted` as signals to pause
  time-sensitive operations until a fresh `verified` anchor lands.
- **Do not exempt the anchor from backup exclusion decisions.** Until
  R1/R2 mitigations land, excluding the app's secure-storage data from
  cloud/device backups removes the backup-forgery surface entirely.

## Relationship to other documents

- [`SECURITY.md`](../../SECURITY.md) — the consumer-facing summary and
  vulnerability-reporting policy; links here for depth.
- [Secure Time Contract](../specification/secure-time-contract.md) —
  normative definition of `verified` and the fail-closed API policy
  (stages 1–2 of the chain, specified precisely).
- [ADR 0002](../adr/0002-headless-background-sync.md) — the headless
  background-sync design whose hand-off is analysed in stages 3–4.
- [ADR 0007](../adr/0007-hybrid-trust-model.md) — the tiered trust
  model behind the stage 2 consensus defenses.
