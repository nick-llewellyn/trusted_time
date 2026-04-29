# ADR 0001: NTS (Network Time Security) integration strategy

- Status: **Accepted**
- Date: 2026-04-28
- Tracking issue: `trusted_time-e19`
- Depends on: `trusted_time-e5n` (structured `TimeSample`, landed in commit `d80d367`)

## Context

The current `NtpSource` is unauthenticated. A network attacker on the path between the device and an NTP server can forge or shift time replies, defeating the package's anti-tamper guarantees end-to-end. RFC 8915 (NTS) addresses this by adding TLS-based key establishment plus authenticated NTPv4 extension fields, providing integrity (and origin authentication) for time samples.

Three constraints drive this decision:

1. **Web compatibility must not regress.** The package supports web via `HttpsSource` and a no-op NTP stub. NTS uses TLS-over-TCP for key establishment and UDP for transport — neither maps to browser primitives. NTS will never run on web.
2. **`dart:io.SecureSocket` does not expose the TLS keying-material exporter (RFC 5705).** NTS-KE *requires* the exporter to derive C2S/S2C AEAD keys. There is no Dart-only path; we must reach into platform crypto.
3. **No off-the-shelf Dart NTS client exists.** The Dart `ntp` package does not support NTPv4 extension fields (UID, NTS Cookie, NTS Authenticator + Encrypted Extensions), so the authenticated transport will be hand-rolled regardless of the chosen distribution shape.

## Decision

**Ship NTS in the core `trusted_time` package as a major release (2.0.0), behind a conditional import that yields a no-op stub on web — mirroring the existing `NtpSource` pattern.** (Originally drafted as 1.3.x; see "Versioning" below for why the major bump was unavoidable.)

- Native build (`dart.library.io`): real `NtsSource` exporting authenticated samples.
- Web build (default export): stub `NtsSource` whose `fetch()` throws `UnsupportedError`, swallowed by `SyncEngine._querySafe`.
- Web users continue to rely on `HttpsSource` as the primary authority. No web behavior changes.
- API surface adds: `TimeSourceKind.nts`, `TimeSourceMetadata.authenticated` (defaulting to `false` for `ntp`/`https`/`custom`), `TrustedTimeConfig.ntsServers` (opt-in, empty by default).

This is a hybrid of the two paths originally proposed in the issue's design note:
- It keeps a single distribution (Option A) — no separate `trusted_time_nts` package to publish, version, and document.
- It preserves web compatibility (Option B's main argument) — the conditional-import stub means web consumers see no native dependencies and no API surface area they cannot use.

The cost of bundling is small because the native code lives behind platform channels (see below), and the cookie/AEAD machinery is pure Dart only on the wire side.

## Versioning

- **Decision: 2.0.0** (major bump).
- The original ADR draft predicted **1.3.0** on the assumption that NTS could be added without disturbing the SDK floor. Implementation revealed that `package:nts` requires Dart `^3.10.0` / Flutter `>=3.38.0` (driven by its Native Assets / `flutter_rust_bridge` v2 toolchain). Raising the floor from `>=3.4.0` / `>=3.19.0` is a breaking change for downstream consumers regardless of how additive the Dart API surface is, so a major bump is the honest signal.
- The Dart-level API surface remains additive (new opt-in `ntsServers` config field, new `TimeSourceKind.nts`, new `TimeSourceMetadata.authenticated` defaulting to `false`). Consumers that don't configure NTS see no behavioral change beyond the SDK-floor requirement.

## Consequences

**Positive**
- One package to install, one version line.
- Web compatibility unchanged.
- `SyncEngine` consumes NTS samples through the same `TrustedTimeSource`/`TimeSample` contract introduced in `e5n`, with no engine-level branching.
- Authentication is exposed via `TimeSample.source.authenticated` so consumers can choose to require it (e.g., refuse anchors lacking ≥1 authenticated sample).

**Negative**
- The package now ships native code touching TLS and crypto on every supported platform. This expands the attack surface and the maintenance burden.
- Desktop platforms (Linux/Windows/macOS) lack a stable Flutter-native TLS-with-exporter API and will be addressed *after* the iOS/Android landing (see "Phased rollout" below). Until then, `NtsSource` will throw `UnsupportedError` on those platforms — caught by the engine the same as the web stub.
- Adding NTS to core makes the *next* hard architectural question (per-source weighting / require-authenticated mode) live within this package rather than a sibling.

**Resolution path for the TLS exporter constraint**

Rather than hand-roll a per-platform TLS-with-exporter shim through `MethodChannel`, we depend on [`package:nts`](https://pub.dev/packages/nts), which ships a Rust implementation of NTS-KE + AEAD-NTPv4 and bridges it to Dart via `flutter_rust_bridge` v2 (using the Native Assets pipeline introduced in Dart 3.10). The Rust side handles TLS 1.3 (with RFC 5705 keying-material exporter), the cookie pool, AEAD-SIV-CMAC-256 packet construction, and UDP transport; the Dart side just calls `ntsQuery(spec, timeoutMs)` and unwraps the result into a `TimeSample`.

| Concern | Owner | Notes |
|---|---|---|
| TLS 1.3 + exporter | `package:nts` (Rust, via `rustls`) | RFC 5705 exporter is first-class in `rustls`. |
| NTS-KE record protocol | `package:nts` | RFC 8915 §4. |
| Cookie pool & rotation | `package:nts` | Persisted in-memory per `NtsServerSpec`. |
| AEAD-NTPv4 framing | `package:nts` | AEAD-SIV-CMAC-256 (IANA AEAD ID 15). |
| Monotonic anchoring & quorum | `trusted_time` | `NtsSource` captures `MonotonicClock.uptimeMs()` immediately on response receipt; the `SyncEngine` treats NTS samples identically to NTP/HTTPS for Marzullo intersection. |

This trades a hand-rolled multi-platform crypto shim for a single Rust dependency. The cost is the Native Assets / FRB toolchain requirement (forcing the SDK floor bump documented under "Versioning" above); the benefit is that all supported native platforms (iOS, Android, macOS, Linux, Windows) share one battle-tested implementation, and we inherit `rustls`'s ongoing security maintenance instead of owning it.

**Phased rollout**

1. **Phase 1 (this issue, `e19`):** ADR + `NtsSource` wrapping `package:nts` + unit tests via injectable query function + skipped live integration tests against `time.cloudflare.com:4460` and `nts.netnod.se:4460`.
2. **Phase 2 (follow-up issue):** Per-platform release-build verification (especially desktop), CI matrix coverage for the Native Assets pipeline.
3. **Phase 3 (follow-up issue):** "Require authenticated quorum" config knob — `SyncEngine` rejects anchors that don't include ≥N authenticated samples.

## Alternatives considered

- **Option B (sibling `trusted_time_nts` package).** Rejected: the conditional-import stub achieves Option B's goal (web users unaffected) without splitting distribution. The sibling-package design adds version-coupling overhead for no practical isolation benefit, since the platform-channel layer is already part of the core package's plugin manifest.
- **Pure-Dart TLS 1.3 implementation.** Rejected: enormous scope, ongoing security maintenance burden, and would still need an exporter implementation. Not viable.
- **`package:basic_utils`-style approach using existing pub crypto.** Rejected: the Dart pub ecosystem does not currently provide a TLS 1.3 client with exporter access.
- **Defer NTS indefinitely; rely on HTTPS-`Date`.** Rejected: HTTPS-`Date` gives only second-level granularity and the server can lie freely (TLS authenticates server identity, not the `Date` header content). NTS is the only path to authenticated sub-second time on native.
