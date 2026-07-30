# trusted_time

[![pub package](https://img.shields.io/pub/v/trusted_time.svg)](https://pub.dev/packages/trusted_time)
[![Build Status](https://github.com/Sahad2701/trusted_time/actions/workflows/ci.yml/badge.svg)](https://github.com/Sahad2701/trusted_time/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A tamper-proof UTC clock for Flutter. `trusted_time` anchors network-verified time to the device's hardware monotonic uptime, so your app's timestamps remain accurate even when the system clock is changed by the user, the device goes offline, or the network is unreliable.

---

## Features

- **Tamper-proof** — anchored to the hardware monotonic oscillator, not the system wall clock
- **Multi-source consensus** — queries NTP and NTS servers in parallel; uses Marzullo's algorithm to find the most probable true time and discard outliers
- **NTS support** — optional Network Time Security (RFC 8915) for cryptographically authenticated time
- **Integrity monitoring** — detects device reboots across restarts and reports degraded sync cycles
- **Background sync** — keeps the anchor fresh while the app is backgrounded (Android WorkManager, iOS BGAppRefreshTask, desktop Timer)
- **Offline safe** — projects time from the last known anchor using the monotonic clock when the network is unavailable
- **Cross-platform** — Android, iOS, macOS, Windows, Linux

---

## Platform support

| Platform | Monotonic clock | Background sync | Time sources |
|----------|----------------|----------------|-------------|
| Android  | `elapsedRealtime()` | WorkManager | NTP, NTS |
| iOS      | `systemUptime` | BGAppRefreshTask | NTP, NTS |
| macOS    | `systemUptime` | Timer.periodic | NTP, NTS |
| Windows  | `GetTickCount64()` | Timer.periodic | NTP, NTS |
| Linux    | `CLOCK_BOOTTIME` | Timer.periodic | NTP, NTS |

> **Mobile background sync note:** On Android and iOS, background fires perform a real headless anchor refresh **if** the host app registers a background callback via `TrustedTime.registerBackgroundCallback` (plus, on iOS, the `AppDelegate` plugin-registrant hook — see [Enable background sync](#enable-background-sync)). Without registration, background fires are no-ops — no network activity of any kind — and the anchor is refreshed on the next foreground launch. All network traffic is strictly limited to the configured time sources.

---

## Installation

```yaml
dependencies:
  trusted_time: ^2.0.0
```

---

## Setup

### Android

Add the `INTERNET` permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest ...>
    <uses-permission android:name="android.permission.INTERNET" />
    ...
</manifest>
```

If you call `enableBackgroundSync()`, WorkManager is used automatically. No additional manifest entries are required — WorkManager registers its own components.

### iOS

If you call `enableBackgroundSync()`, add the background task identifier to your `ios/Runner/Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.trustedtime.backgroundsync</string>
</array>
```

Also add the Background Modes capability in Xcode (`Signing & Capabilities → + Capability → Background Modes`) and enable **Background fetch**.

### macOS

Add the network entitlement to `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

### Windows, Linux

No additional setup required.

---

## Usage

### Initialize at app startup

Call `initialize()` once before `runApp`. It restores the last persisted anchor from secure storage and begins the first network sync in the background — the returned future resolves after local work only and never blocks on the network, so startup latency is independent of network conditions.

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TrustedTime.initialize(); // Fast: local work only.
  runApp(const MyApp());
}
```

On a warm start (persisted anchor restored) time is trusted as soon as `initialize()` resolves. On a cold start the first sync continues in the background: `getAssessment().syncInProgress` reports it, and `TrustedTime.firstSyncSettled` awaits its conclusion when a definitive first answer is required:

```dart
await TrustedTime.firstSyncSettled; // Concluded: success or failure.
final a = TrustedTime.getAssessment(); // Verdict lives here.
```

Configuration errors (an invalid `TrustedTimeConfig`) still throw from `initialize()` itself; network outcomes never do — a failed first sync surfaces as `TrustStatusReason.syncFailed` on the assessment.

You can pass a `TrustedTimeConfig` to customise sources, sync intervals, and security requirements:

```dart
await TrustedTime.initialize(
  config: const TrustedTimeConfig(
    ntsServers: ['time.cloudflare.com', 'nts.netnod.se'],
    refreshInterval: Duration(hours: 6),
    backgroundSyncInterval: Duration(hours: 12),
    minGroupCount: 2,
  ),
);
```

The plain-NTP host list is not configurable: the library ships a fixed, curated inventory of 51 verified hosts (see `ntpServers` in the configuration reference below). `config.ntpInventory` exposes each host's tier, observed stratum and autonomous system, and leap-second evidence via `NtpServerInfo`.

### Get the current time

All retrieval goes through one synchronous call — `getAssessment()` — which returns the time, the reason it is (or is not) trustworthy, and every caveat in a single immutable snapshot:

```dart
Future<void> stampEvent(Event event) async {
  final assessment = TrustedTime.getAssessment();

  switch (assessment.reason) {
    case TrustStatusReason.synchronized:
      // Fully verified: NTS-authenticated consensus.
      event.timestamp = assessment.time!;
    case TrustStatusReason.degraded:
      // Usable time, but no cryptographic guarantee (NTP-only quorum).
      event.timestamp = assessment.time!;
    case TrustStatusReason.neverSynced:
    case TrustStatusReason.rebootDetected:
    case TrustStatusReason.syncFailed:
      // No trusted time. assessment.time is null; reason says why.
      if (assessment.syncInProgress) {
        // A sync cycle is already in flight — show a wait state and
        // re-assess when it concludes instead of triggering another
        // cycle. On a cold start (neverSynced) the in-flight cycle is
        // the first one, so firstSyncSettled is the rendezvous for
        // its conclusion. Later cycles (a retry after syncFailed, a
        // scheduled refresh) settle no dedicated future: re-assess
        // after a short delay or on the next meaningful boundary.
        if (assessment.reason == TrustStatusReason.neverSynced) {
          await TrustedTime.firstSyncSettled;
        }
      } else {
        await TrustedTime.forceResync();
      }
  }
}

// Local time in a specific IANA timezone (immune to device timezone manipulation)
final tokyo = TrustedTime.trustedLocalTimeIn('Asia/Tokyo');
```

`getAssessment()` never throws for posture reasons: an unanchored engine yields `time == null` plus the explanatory `reason` instead of an exception. It is a pure arithmetic projection (no I/O, typically under 50µs), so call it at every meaningful boundary — after `initialize()`, on app resume, before a high-value operation — rather than caching one result.

### Inspect the caveats

```dart
final a = TrustedTime.getAssessment();

a.isTrusted;       // time != null
a.isSecure;        // authLevel == NtsAuthLevel.verified
a.confidence;      // ConfidenceLevel.none / low / medium / high
a.uncertainty;     // ± error bound (the anchor's measured consensus interval)
a.anchorAge;       // elapsed monotonic time since the anchor was minted
a.syncInProgress;  // a sync cycle is in flight right now
a.driftRate;       // observed oscillator drift this boot (≥1h span), or null
a.driftCorrectedTime; // time de-skewed by driftRate — experimental
```

### Enforce security requirements

Strictness is a caller-side decision on the assessment — there is no throwing "secure getter":

```dart
final a = TrustedTime.getAssessment();

// Require NTS-authenticated time for high-value operations
if (a.isSecure) {
  submit(a.time!); // backed by NTS-authenticated consensus
} else {
  // Degraded or unanchored — block the operation or flag it
}

// Require a minimum confidence level
if (a.confidence.index >= ConfidenceLevel.high.index) {
  submit(a.time!);
}
```

### Trust posture changes

Because time projection is anchored to the monotonic clock, changing the system wall clock has no effect on projected time — no monitoring is needed for that. The two posture degradations are both expressed through assessment state:

- **Tier degradation** — a sync cycle that cannot form an authenticated (Tier 1) quorum mints a best-effort anchor; assessments report `TrustStatusReason.degraded` with `isSecure == false`.
- **Reboot** — a reboot always ends the process, so it is detected during `initialize()`: the stale anchor is discarded and assessments report `TrustStatusReason.rebootDetected` with `time == null` until a fresh network sync succeeds.

Check `getAssessment()` after `initialize()` (and on app resume) rather than waiting for an event.

### Enable background sync

```dart
await TrustedTime.enableBackgroundSync(
  interval: const Duration(hours: 12),
);
```

On Android this schedules a WorkManager `PeriodicWorkRequest`. On iOS it registers a `BGAppRefreshTask`. On desktop it uses a `Timer.periodic` within the Dart isolate.

**Headless anchor refresh (Android/iOS):** for a background fire to perform a real anchor refresh (without registration, fires are no-ops), register a top-level `@pragma('vm:entry-point')` callback before `runApp`:

```dart
import 'dart:async';

@pragma('vm:entry-point')
void trustedTimeBackgroundCallback() {
  unawaited(TrustedTime.runBackgroundSync());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TrustedTime.registerBackgroundCallback(trustedTimeBackgroundCallback);
  runApp(const MyApp());
}
```

On iOS, additionally wire the plugin registrant onto the headless engine in your `AppDelegate` (required so `flutter_secure_storage` can persist the refreshed anchor):

```swift
import trusted_time

TrustedTimePlugin.setPluginRegistrantCallback { engine in
  GeneratedPluginRegistrant.register(with: engine)
}
```

Background refresh bounds the staleness of the fallback anchor: if a sync fails at app start or re-entry (transient network failure, time servers unreachable, quorum miss), warm-restore falls back to the most recent persisted anchor — with background refresh that anchor is at most one background interval old, regardless of how long the app was closed. Why sync in the background at all when foreground sync exists? See [ADR 0002](doc/adr/0002-headless-background-sync.md).

### NTS (Network Time Security)

RFC 8915 authenticated time is on by default: `ntsServers` ships with two anycast anchors from distinct operators (`time.cloudflare.com`, `nts.netnod.se`), enough to mint a verified truth box under the default `minGroupCount` of 2. Pass your own list to customise, or an empty list to disable NTS entirely — apps that pass `ntsServers: []` have zero overhead from the feature.

```dart
await TrustedTime.initialize(
  config: const TrustedTimeConfig(
    ntsServers: ['time.cloudflare.com', 'nts.netnod.se'],
  ),
);

// Check whether the current anchor is NTS-authenticated
final a = TrustedTime.getAssessment();
print(a.isSecure);   // true / false
print(a.authLevel);  // NtsAuthLevel.verified / none
```

> **NTS implementation note:** NTS uses [`package:nts`](https://pub.dev/packages/nts), a Rust-backed RFC 8915 client (TLS 1.3 with RFC 5705 keying-material exporters and AES-SIV-CMAC-256 AEAD), so authenticated samples are fully cryptographically verified — not advisory. A successful handshake is recorded as `NtsAuthLevel.verified` only when the chain was anchored by the library-controlled trust store (bundled `webpki-roots` or caller-supplied custom roots); platform-mediated paths, which may chain through a corporate-injected or MDM-installed CA, are recorded as `NtsAuthLevel.none`. See [ADR 0007](doc/adr/0007-hybrid-trust-model.md) and `doc/design/tiered-trust-implementation.md` for the full rationale.

### Observability

Register a `SyncObserver` to receive structured metrics from every sync cycle:

```dart
class MySyncObserver implements SyncObserver {
  @override
  void onMetricsReported(SyncMetrics metrics) {
    print('Latency: ${metrics.latencyMs}ms');
    print('Uncertainty: ±${metrics.uncertaintyMs}ms');
    print('Participants: ${metrics.participantCount}');
    print('Confidence: ${metrics.confidence}');
  }

  @override
  void onSourceFailed(String sourceId, Object error) {
    print('Source $sourceId failed: $error');
  }

  // ... other callbacks
}

TrustedTime.registerObserver(MySyncObserver());
```

---

## Testing

Use `TrustedTime.overrideForTesting` to inject a deterministic mock in unit and widget tests. Tests do not need network access.

```dart
void main() {
  setUp(() {
    TrustedTime.overrideForTesting(TrustedTimeMock(
      now: DateTime.utc(2026, 1, 1, 12, 0, 0),
      isTrusted: true,
      confidence: ConfidenceLevel.high,
    ));
  });

  tearDown(() {
    TrustedTime.resetOverride();
  });

  test('uses trusted time for timestamp', () {
    final ts = TrustedTime.getAssessment().time!;
    expect(ts.year, 2026);
  });
}
```

---

## Configuration reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ntpServers` | `List<String>` | curated 51-host inventory | **Read-only.** Hostnames from the library's fixed NTP inventory, verified by live probe. No host is a documented leap-second smearer — Google, AWS, and Meta are excluded on published-smear evidence, since a smeared source diverges from stepping sources by up to a full second around a leap event |
| `ntpInventory` | `List<NtpServerInfo>` | curated 51-host inventory | **Read-only.** The same inventory with per-host metadata: `tier` (anycast / unicast stratum 1 / unicast stratum 2), `observedStratum`, `observedGroupId`, and `leapPolicy` |
| `ntpBurstCount` | `int` | `8` | Sequential SNTP exchanges per NTP source per sync; the lowest-delay sample is kept |
| `ntsServers` | `List<String>` | `time.cloudflare.com`, `nts.netnod.se` | NTS server hostnames |
| `ntsPort` | `int` | `4460` | NTS-KE port |
| `refreshInterval` | `Duration` | `48h` | Foreground re-sync period and the on-resume anchor staleness bound |
| `backgroundSyncInterval` | `Duration?` | `null` | If set, enables background sync at this interval |
| `maxLatency` | `Duration` | `4s` | Per-source query timeout |
| `maxConcurrentDnsLookups` | `int?` | `null` → `6` | Cold-start ceiling on concurrent *uncached* DNS lookups, shared across source kinds (NTP governed in-process; forwarded to NTS). Supersedes the deprecated NTS-only `ntsDnsConcurrencyCap` — see [ADR 0008](doc/adr/0008-unified-dns-tls-budget.md) |
| `minimumQuorum` | `int` | `2` | Minimum sources required for consensus |
| `minQuorumRatio` | `double` | `0.6` | Fraction of responding sources required |
| `minGroupCount` | `int` | `2` | Minimum distinct provider groups required |
| `maxAllowedUncertaintyMs` | `int` | `5000` | Sources above this uncertainty are excluded |
| `persistState` | `bool` | `true` | Persist anchor to secure storage across launches |
| `earlyExit` | `bool` | `true` | Return as soon as a stable quorum is reached |

---

## Security model

| Threat | Status | Mechanism |
|--------|--------|-----------|
| System clock manipulation by user | ✅ Protected | Monotonic anchoring |
| Device reboot (clock reset) | ✅ Detected | Uptime comparison on warm start |
| Single rogue NTP server | ✅ Mitigated | Marzullo consensus + quorum floor |
| Correlated provider failure | ✅ Mitigated | Group diversity requirement |
| On-path NTP spoofing (MITM) | ✅ Mitigated | RFC 8915 NTS (AES-SIV-CMAC-256 AEAD) when enabled; `verified` for bundled/custom-root chains |
| Offline drift | ⚠️ Observed | Passive per-boot drift history (`getDriftHistory()`); ≥1h observations surface as `driftRate` |

---

## How it works

When `initialize()` is called:

1. The last persisted `TrustAnchor` is loaded from encrypted platform storage (Android Keystore / iOS Keychain / Windows DPAPI / Linux libsecret).
2. If the anchor is valid (device has not rebooted since it was written), time is available immediately — no network round-trip needed.
3. A background sync begins: NTP and NTS sources are queried in parallel. As samples arrive they are fed into Marzullo's algorithm. Once a stable, group-diverse quorum is reached, a new anchor is written.

After initialization, `TrustedTime.getAssessment()` is a pure arithmetic operation: it adds the elapsed monotonic time since the anchor was captured to the anchor's UTC value. There is no I/O and no platform channel call per invocation.

Because projection depends only on the anchor and the monotonic clock, wall-clock changes made while the app is running (or stopped) cannot move trusted time — no runtime clock surveillance is required. The one event that invalidates an anchor is a reboot, which resets the monotonic counter; it is detected at initialization by comparing the anchor's recorded boot-session identifier against the current one (step 2 above).

---

## Sync cadence (mobile)

`TrustedTime` implements a 48h anchor-age policy that is cheap on
battery and radio. An anchor is kept fresh by (a) the foreground
refresh timer (every `refreshInterval`, 48h default), (b) the OS-level
background job when `enableBackgroundSync()` is active, and (c) an
anchor-age check when the app returns to the foreground — if the
anchor is older than `refreshInterval` (or absent), a full sync runs
immediately instead of waiting for the next timer tick.

`mobileDefaults()` sets `backgroundSyncInterval` to 24h against the
48h staleness bound: the background task attempts a refresh daily,
and the foreground resume trigger only forces a sync if the
best-effort OS scheduler (iOS `BGTaskScheduler`, Android
`WorkManager`) has failed to land the job for more than 48 hours.

```dart
// Opt in to the mobile schedule (daily background refresh).
await TrustedTime.initialize(config: TrustedTimeConfig.mobileDefaults());
```

`WidgetsFlutterBinding.ensureInitialized()` must have run before
`initialize()` for the foreground trigger to attach; in a headless
isolate the periodic timers still drive cadence on their own.

---


## Comparison

| Capability | `DateTime.now()` | `flutter_kronos` | **TrustedTime v2.0** |
| :--- | :---: | :---: | :---: |
| Tamper-Proof | ❌ | ⚠️ | ✅ |
| Offline Safe | ❌ | ✅ | ✅ |
| Consensus | ❌ | ❌ | ✅ |
| NTS (Security) | ❌ | ❌ | ✅ |
| Confidence Decay | ❌ | ❌ | ✅ |
| Adaptive Filtering | ❌ | ❌ | ✅ |
| Group Diversity | ❌ | ❌ | ✅ |
| Zero-IO `now()` | ✅ | ❌ | ✅ |


## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All PRs require one approval and must pass the full CI matrix (Android, iOS, macOS, Windows, Linux across two Flutter versions) before merging.

## License

MIT see [LICENSE](LICENSE).
