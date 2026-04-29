# TrustedTime

[![pub package](https://img.shields.io/pub/v/trusted_time.svg)](https://pub.dev/packages/trusted_time)
[![Build Status](https://github.com/Sahad2701/trusted_time/actions/workflows/ci.yml/badge.svg)](https://github.com/Sahad2701/trusted_time/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Web%20%7C%20Desktop-blue.svg)](https://pub.dev/packages/trusted_time)

**TrustedTime** is a high-integrity, production-grade time guardian for Flutter. It provides a UTC clock anchored to hardware monotonic oscillators, ensuring your app's temporal logic remains correct even if the user manipulates the system clock. With optional Network Time Security ([NTS, RFC 8915](https://datatracker.ietf.org/doc/html/rfc8915)), the network samples themselves are also cryptographically authenticated end-to-end against on-path attackers.

[Architecture](ARCHITECTURE.md) • [Contributing](CONTRIBUTING.md) • [Security](SECURITY.md) • [Changelog](CHANGELOG.md)

Unlike `DateTime.now()`, which depends on the user-modifiable system clock, TrustedTime synchronizes with trusted network time sources and anchors that time to the device’s **hardware monotonic clock** — ensuring timestamps remain correct even if users change their device time or go offline.

---

## Why TrustedTime?

Many apps rely on time for correctness and security:

* Trial expirations
* Subscription billing
* Ticket validity
* Rate limiting
* Audit logging
* Token expiration

Unfortunately, **system time is untrusted** — users can move it forward or backward at will.

TrustedTime solves this by providing a **secure virtual clock** that:

✅ Works offline after first sync
✅ Detects clock tampering automatically
✅ Persists across app restarts
✅ Has near-zero runtime overhead
✅ Works across Android, iOS, Web, and Desktop

---

## Platform Support

| Android | iOS | Web | macOS | Windows | Linux |
| :---: | :---: | :---: | :---: | :---: | :---: |
| ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

---

## Features

*   **Tamper-Resistant Time**: Anchors network UTC to hardware monotonic uptime — survives user-side system-clock manipulation, app restarts, and offline operation.
*   **Multi-Source Consensus**: Quorum-based Marzullo intersection across NTP, NTS, and HTTPS bounds the impact of any single dishonest source.
*   **Authenticated Time (NTS, opt-in)**: [RFC 8915](https://datatracker.ietf.org/doc/html/rfc8915) Network Time Security adds cryptographic authentication of network samples against on-path attackers (TLS + AEAD).
*   **Secure Persistence**: Encrypted state recovery across app restarts.
*   **High Performance**: Synchronous, zero-latency access with <1μs overhead.
*   **Offline Ready**: Continues providing trusted time without connectivity once anchored.
*   **Integrity Monitoring**: Real-time event streams for clock jumps and reboots.

---

## Installation

Add **TrustedTime** to your `pubspec.yaml` via CLI:

```bash
flutter pub add trusted_time
```

### Platform-Specific Setup

#### Android
Ensure your `AndroidManifest.xml` (usually found in `android/app/src/main/AndroidManifest.xml`) includes the Internet permission:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

#### iOS / macOS / Windows / Linux / Web
No additional setup or permissions are required. The library automatically leverages native APIs for monotonic timing and secure storage.

---

## Quick Start

### 1️⃣ Initialize once at app startup

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Await initialization to ensure hardware monotonic anchoring is established.
  await TrustedTime.initialize();
  runApp(MyApp());
}
```

---

### 2️⃣ Get trusted time anywhere

```dart
final now = TrustedTime.now();
final unixMs = TrustedTime.nowUnixMs();
final iso = TrustedTime.nowIso();
```

---

### 3️⃣ Check trust state

```dart
if (TrustedTime.isTrusted) {
  // Time is verified and safe to use
} else {
  // Still syncing or integrity lost
}
```

---

### 4️⃣ Listen for tampering

```dart
TrustedTime.onIntegrityLost.listen((_) {
  print('System clock changed or device rebooted');
});
```

---

### 5️⃣ Force resync if needed

```dart
await TrustedTime.forceResync();
```

---

## Common Use Cases

### Ticketing & Access Control

Prevent users from activating passes early or extending them by changing device time.

### Trials & Subscriptions

Ensure “7-day trials” are exactly 7 days — even if the user adjusts their clock or goes offline.

### Anti-Fraud & Compliance

Use trusted timestamps for audit logs, transaction signing, and security-critical workflows.

### Rate Limiting & Cooldowns

Prevent cooldown bypass attacks caused by local clock manipulation.

---

## How It Works (Simple Explanation)

TrustedTime establishes a **Trust Anchor**:

1. It queries multiple network time sources (NTP + HTTPS).
2. It filters bad or slow sources using a quorum algorithm.
3. It stores the verified network time alongside the device’s **monotonic uptime**.
4. From then on, it computes:

```
trustedNow = (currentUptime - uptimeAtSync) + networkTimeAtSync
```

Because **monotonic uptime cannot be changed by the user**, this clock remains accurate even if:

* The system time is modified
* The device goes offline
* The app is restarted

Only a device reboot resets uptime — which TrustedTime detects and automatically resynchronizes.

---

## Advanced Configuration

```dart
await TrustedTime.initialize(
  config: TrustedTimeConfig(
    refreshInterval: Duration(hours: 12),
    ntpServers: ['time.google.com', 'pool.ntp.org'],
    ntsServers: ['time.cloudflare.com', 'nts.netnod.se'],
    httpsSources: ['https://www.google.com', 'https://www.cloudflare.com'],
    maxLatency: Duration(seconds: 2),
    minimumQuorum: 2,
    persistState: true,
  ),
);
```

### Authenticated time via NTS (RFC 8915)

Set `ntsServers` to opt into Network Time Security. NTS samples are cryptographically authenticated end-to-end, defending against on-path attackers who can forge or shift plain NTP replies. Each NTS sample carries `source.authenticated: true` on the `TimeSample`. The IANA-assigned NTS-KE port (`4460`) is used automatically; pass hostnames only.

NTS is supported on iOS, Android, macOS, Linux, and Windows via the [`nts`](https://pub.dev/packages/nts) package's Rust-backed implementation. On web, NTS sources are silently skipped and the engine falls back to `httpsSources`.

> **SDK requirement**: Enabling NTS pulls in the `package:nts` toolchain, which requires Dart `^3.10.0` / Flutter `>=3.38.0`.

### Background sync (real headless refresh)

When `enableBackgroundSync` is paired with a registered host-app callback, TrustedTime spins up a headless `FlutterEngine` from the OS scheduler (Android `WorkManager`, iOS `BGAppRefreshTask`), runs a real Marzullo-quorum sync, and persists a fresh `TrustAnchor` — so the next foreground launch warm-restores from current data without a network round-trip. See [ADR 0002](docs/adr/0002-headless-background-sync.md) for the full design.

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:trusted_time/trusted_time.dart';

@pragma('vm:entry-point')
void trustedTimeBackgroundCallback() {
  // Fire-and-forget: the host callback is `void Function()` and cannot
  // await; `unawaited(...)` documents the intent and keeps the
  // `unawaited_futures` lint clean.
  unawaited(TrustedTime.runBackgroundSync());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TrustedTime.initialize();
  await TrustedTime.registerBackgroundCallback(trustedTimeBackgroundCallback);
  await TrustedTime.enableBackgroundSync(interval: Duration(hours: 6));
  runApp(MyApp());
}
```

> **Required:** the callback **must** be a top-level or static function annotated with `@pragma('vm:entry-point')`, otherwise tree-shaking strips it in release builds and `registerBackgroundCallback` throws `ArgumentError`.

**Platform setup**

- **Android:** no extra setup. `WorkManager` and the headless engine bootstrap are wired by the plugin.
- **iOS:** add the BGTask identifier to `ios/Runner/Info.plist`:

  ```xml
  <key>BGTaskSchedulerPermittedIdentifiers</key>
  <array>
    <string>com.trustedtime.backgroundsync</string>
  </array>
  ```

  And register the host's plugin registrant onto the headless engine in `AppDelegate.swift`:

  ```swift
  import trusted_time
  // inside application(_:didFinishLaunchingWithOptions:):
  TrustedTimePlugin.setPluginRegistrantCallback { engine in
    GeneratedPluginRegistrant.register(with: engine)
  }
  ```

  Without the plugin-registrant shim, the headless engine cannot reach `flutter_secure_storage` and the persisted anchor write would fail.

**Back-compat fallback:** if `registerBackgroundCallback` is never called, `enableBackgroundSync` falls back to the pre-2.x connectivity-only HTTPS HEAD probe so existing integrators are not broken.

---

## Platform Behavior

### Android

* Uses `SystemClock.elapsedRealtime()` (hardware monotonic clock)
* Detects manual time and timezone changes automatically
* No setup required

### iOS

* Uses `ProcessInfo.systemUptime`
* Detects system clock changes automatically
* No setup required

### Web & Desktop

* Uses HTTPS time sources
* Uses browser/OS monotonic timers
* Works offline after sync

---

## Performance

| Operation           | Cost           |
| ------------------- | -------------- |
| `TrustedTime.now()` | **< 1μs**      |
| Initial sync        | ~100–500ms     |
| Memory overhead     | ~50 KB         |
| Background CPU      | Zero when idle |

After the initial sync, TrustedTime uses a single lightweight timer to schedule periodic anchor refreshes. No polling or busy-waiting is performed between syncs.

---

## Security Model

TrustedTime distinguishes two threat classes: **user-side** attacks against the local system clock, and **network-side** attacks against the time samples in flight. Coverage depends on which sources are configured.

### User-side threats (covered by the monotonic anchor)

These are mitigated regardless of which network source is configured, because trusted time is computed from hardware monotonic uptime plus a verified anchor — the user's system clock is never read after the anchor is established.

| Threat                  | Protected |
| ----------------------- | --------- |
| Manual clock change     | ✅         |
| System time rollback    | ✅         |
| Trial extension         | ✅         |
| App restart abuse       | ✅         |
| Offline replay          | ✅         |
| Device reboot           | ✅ (detected → resync) |

### Network-side threats (per source)

| Threat                                | NTP (default) | HTTPS `Date` header | NTS (RFC 8915) | Marzullo consensus across ≥2 sources |
| ------------------------------------- | :-----------: | :-----------------: | :------------: | :----------------------------------: |
| Passive eavesdropping                 |       ❌       |          ✅          |        ✅       |                  n/a                 |
| Off-path attacker (response spoofing) |       ❌       |          ✅          |        ✅       |                   ✅                  |
| On-path / MITM attacker               |       ❌       |        ⚠️ (1)       |        ✅       |                ⚠️ (2)                |
| Single dishonest server               |     ⚠️ (2)    |        ⚠️ (2)       |     ⚠️ (2)     |                   ✅                  |

(1) HTTPS `Date` is bound to a TLS handshake, so a network attacker cannot forge it without a valid certificate; however, the header is single-second resolution and the server itself is trusted.
(2) Mitigated by configuring multiple sources from independent operators — the engine's Marzullo intersection rejects samples that disagree with the quorum. A single attacker who controls fewer than half of the configured servers cannot shift the consensus.

**Recommendation for security-sensitive deployments:** configure at least two `ntsServers` from independent operators (e.g. `time.cloudflare.com`, `nts.netnod.se`) so that every accepted sample is cryptographically authenticated, and the consensus algorithm bounds the impact of any single compromised operator.

### Limitations

* Requires internet on first launch to establish the anchor.
* Cannot protect against hardware-level oscillator manipulation or a compromised OS that lies about monotonic uptime (rooted/jailbroken devices — see [SECURITY.md](SECURITY.md) "Out of Scope").
* Default-configured NTP and HTTPS sources are **not** end-to-end authenticated; rely on Marzullo consensus across multiple operators for MITM resistance, or opt into NTS for per-sample cryptographic authentication.
* HTTPS `Date` header has 1-second resolution and depends on the upstream server's clock accuracy.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

---

## Comparison

| Capability                 | `DateTime.now()` | `flutter_time_guard` | `flutter_kronos` | **TrustedTime** |
| -------------------------- | ---------------- | -------------------- | ---------------- | --------------- |
| Trusted timestamps         | ❌                | ❌                    | ⚠️ Basic         | ✅               |
| Offline after sync         | ❌                | ⚠️ Limited           | ✅                | ✅               |
| Detects clock tampering    | ❌                | ✅                    | ⚠️ Partial       | ✅               |
| Multi-source consensus     | ❌                | ❌                    | ❌                | ✅               |
| HTTPS fallback             | ❌                | ❌                    | ❌                | ✅               |
| Drift/uncertainty metadata | ❌                | ❌                    | ❌                | ✅               |
| Cross-platform             | ⚠️               | ⚠️                   | ❌                | ✅               |
| Zero-latency `now()`       | ❌                | ❌                    | ❌                | ✅               |
