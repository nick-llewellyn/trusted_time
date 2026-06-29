# trusted_time

[![pub package](https://img.shields.io/pub/v/trusted_time.svg)](https://pub.dev/packages/trusted_time)
[![Build Status](https://github.com/Sahad2701/trusted_time/actions/workflows/ci.yml/badge.svg)](https://github.com/Sahad2701/trusted_time/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A tamper-proof UTC clock for Flutter. `trusted_time` anchors network-verified time to the device's hardware monotonic uptime, so your app's timestamps remain accurate even when the system clock is changed by the user, the device goes offline, or the network is unreliable.

---

## Features

- **Tamper-proof** — anchored to the hardware monotonic oscillator, not the system wall clock
- **Multi-source consensus** — queries NTP servers and HTTPS endpoints in parallel; uses Marzullo's algorithm to find the most probable true time and discard outliers
- **NTS support** — optional Network Time Security (RFC 8915) for cryptographically authenticated time
- **Integrity monitoring** — automatically detects system clock jumps and device reboots and re-syncs
- **Background sync** — keeps the anchor fresh while the app is backgrounded (Android WorkManager, iOS BGAppRefreshTask, desktop Timer)
- **Offline safe** — projects time from the last known anchor using the monotonic clock when the network is unavailable
- **All platforms** — Android, iOS, macOS, Windows, Linux, Web

---

## Platform support

| Platform | Monotonic clock | Background sync | Time sources | Integrity events |
|----------|----------------|----------------|-------------|-----------------|
| Android  | `elapsedRealtime()` | WorkManager | NTP, HTTPS, NTS | BroadcastReceiver |
| iOS      | `systemUptime` | BGAppRefreshTask | NTP, HTTPS, NTS | NotificationCenter |
| macOS    | `systemUptime` | Timer.periodic | NTP, HTTPS, NTS | NotificationCenter |
| Windows  | `GetTickCount64()` | Timer.periodic | NTP, HTTPS, NTS | WM_TIMECHANGE |
| Linux    | `CLOCK_BOOTTIME` | Timer.periodic | NTP, HTTPS, NTS | timerfd |
| Web/WASM | `performance.now()` | — | HTTPS only | visibilitychange |

> **Android background sync note:** The WorkManager job validates network connectivity only. The trust anchor is refreshed on the next foreground app launch. This is intentional — full headless anchor refresh is planned for v2.1.0.

> **Web/WASM note:** Browsers don't support UDP/TCP sockets, so Web platforms use HTTPS `Date` headers from multiple endpoints. The library automatically configures Web-compatible sources when running in browsers or WASM.

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

### Windows, Linux, Web

No additional setup required.

---

## Usage

### Initialize at app startup

Call `initialize()` once before `runApp`. It restores the last persisted anchor from secure storage and begins the first network sync in the background.

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TrustedTime.initialize();
  runApp(const MyApp());
}
```

You can pass a `TrustedTimeConfig` to customise sources, sync intervals, and security requirements:

```dart
await TrustedTime.initialize(
  config: const TrustedTimeConfig(
    ntpServers: ['time.cloudflare.com', 'time.google.com', 'pool.ntp.org'],
    refreshInterval: Duration(hours: 6),
    backgroundSyncInterval: Duration(hours: 12),
    minGroupCount: 2,
  ),
);
```

### Get the current time

```dart
// Synchronous — no I/O, typically completes in under 50µs
final now = TrustedTime.now();

// Unix milliseconds — avoids DateTime allocation
final ms = TrustedTime.nowUnixMs();

// ISO-8601 string
final iso = TrustedTime.nowIso();

// Local time in a specific IANA timezone (immune to device timezone manipulation)
final tokyo = TrustedTime.trustedLocalTimeIn('Asia/Tokyo');
```

`now()` throws `TrustedTimeNotReadyException` if called before the engine has established its first anchor. Check `TrustedTime.isTrusted` before calling if you need to handle the unready state.

### Check trust status

```dart
if (TrustedTime.isTrusted) {
  final now = TrustedTime.now();
} else {
  // Still starting up, or sync failed
  final estimate = TrustedTime.nowEstimated();
}

// Qualitative confidence grade
final grade = TrustedTime.confidence; // ConfidenceLevel.low / medium / high

// Decaying freshness score (1.0 = just synced, approaches 0.0 over time)
final score = TrustedTime.confidenceScore;
if (score < 0.5) {
  await TrustedTime.forceResync();
}
```

### Enforce security requirements

```dart
// Require NTS-authenticated time for high-value operations
try {
  final secureNow = TrustedTime.getTime(requireSecure: true);
  // secureNow is backed by NTS-authenticated consensus
} on TrustedTimeSecurityException catch (e) {
  // NTS unavailable — fall back to consensus-only time or block the operation
}

// Require a minimum confidence level
try {
  final now = TrustedTime.getTime(minConfidence: ConfidenceLevel.high);
} on TrustedTimeSecurityException catch (e) {
  // Confidence too low
}
```

### Listen for integrity events

The engine monitors for system clock jumps and device reboots. When an anomaly is detected, it emits an event, invalidates the current anchor, and begins an immediate resync.

```dart
TrustedTime.onIntegrityLost.listen((event) {
  switch (event.reason) {
    case TamperReason.systemClockJumped:
      // System clock was changed while the app was running
    case TamperReason.deviceRebooted:
      // Device rebooted — monotonic counter reset
    case TamperReason.timezoneChanged:
      // Timezone changed — UTC time unaffected but local time may differ
  }
});
```

### Enable background sync

```dart
await TrustedTime.enableBackgroundSync(
  interval: const Duration(hours: 12),
);
```

On Android this schedules a WorkManager `PeriodicWorkRequest`. On iOS it registers a `BGAppRefreshTask`. On desktop it uses a `Timer.periodic` within the Dart isolate. Web is not supported.

### NTS (Network Time Security)

Pass `ntsServers` in the config to enable RFC 8915 authenticated time. NTS is opt-in and off by default — apps that do not configure it have zero overhead from the feature.

```dart
await TrustedTime.initialize(
  config: const TrustedTimeConfig(
    ntsServers: ['time.cloudflare.com', 'nts.netnod.se'],
  ),
);

// Check whether the current anchor is NTS-authenticated
print(TrustedTime.isSecure);     // true / false
print(TrustedTime.authLevel);    // NtsAuthLevel.verified / none
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
    final ts = TrustedTime.now();
    expect(ts.year, 2026);
  });
}
```

---

## Configuration reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ntpServers` | `List<String>` | `pool.ntp.org`, `time.google.com` | NTP server hostnames |
| `httpsSources` | `List<String>` | Google, Cloudflare, Apple, Microsoft | HTTPS `Date` header sources |
| `ntsServers` | `List<String>` | `['time.cloudflare.com']` | NTS server hostnames (opt-in) |
| `ntsPort` | `int` | `4460` | NTS-KE port |
| `refreshInterval` | `Duration` | `30m` | How often to re-sync in the foreground |
| `backgroundSyncInterval` | `Duration?` | `null` | If set, enables background sync at this interval |
| `maxLatency` | `Duration` | `4s` | Per-source query timeout |
| `maxConcurrentDnsLookups` | `int?` | `null` → `6` | Cold-start ceiling on concurrent *uncached* DNS lookups, shared across source kinds (NTP governed in-process; forwarded to NTS). Supersedes the deprecated NTS-only `ntsDnsConcurrencyCap` — see [ADR 0008](doc/adr/0008-unified-dns-tls-budget.md) |
| `minimumQuorum` | `int` | `2` | Minimum sources required for consensus |
| `minQuorumRatio` | `double` | `0.6` | Fraction of responding sources required |
| `minGroupCount` | `int` | `2` | Minimum distinct provider groups required |
| `maxAllowedUncertaintyMs` | `int` | `5000` | Sources above this uncertainty are excluded |
| `persistState` | `bool` | `true` | Persist anchor to secure storage across launches |
| `earlyExit` | `bool` | `true` | Return as soon as a stable quorum is reached |
| `oscillatorDriftFactor` | `double` | `0.00005` | Used for offline time estimation error calculation |
| `cadenceMode` | `CadenceMode` | `singleTier30m` | Sync schedule: the legacy single uniform loop, or the tiered establish/validate model (mobile) — see [Tiered sync cadence](#tiered-sync-cadence-mobile) |
| `validateInterval` | `Duration` | `1h` | Tiered mode only: how often the lightweight validate probe runs in the foreground |
| `foregroundValidateThreshold` | `Duration` | `15m` | Tiered mode only: minimum time backgrounded before a foreground resume triggers a validate probe |
| `validateBurstCount` | `int` | `4` | Tiered mode only: NTS queries issued per validate probe; the lowest-RTT sample is kept |

---

## Security model

| Threat | Status | Mechanism |
|--------|--------|-----------|
| System clock manipulation by user | ✅ Protected | Monotonic anchoring |
| Device reboot (clock reset) | ✅ Detected | Uptime comparison on warm start |
| Single rogue NTP server | ✅ Mitigated | Marzullo consensus + quorum floor |
| Correlated provider failure | ✅ Mitigated | Group diversity requirement |
| On-path NTP spoofing (MITM) | ✅ Mitigated | RFC 8915 NTS (AES-SIV-CMAC-256 AEAD) when enabled; `verified` for bundled/custom-root chains |
| Offline drift | ⚠️ Estimated | Monotonic projection with drift factor |

---

## How it works

When `initialize()` is called:

1. The last persisted `TrustAnchor` is loaded from encrypted platform storage (Android Keystore / iOS Keychain / Windows DPAPI / Linux libsecret).
2. If the anchor is valid (device has not rebooted since it was written), time is available immediately — no network round-trip needed.
3. A background sync begins: NTP, HTTPS, and NTS sources are queried in parallel. As samples arrive they are fed into Marzullo's algorithm. Once a stable, group-diverse quorum is reached, a new anchor is written.

After initialization, `TrustedTime.now()` is a pure arithmetic operation it adds the elapsed monotonic time since the anchor was captured to the anchor's UTC value. There is no I/O and no platform channel call per invocation.

The integrity monitor runs continuously. On Android and iOS it listens for system broadcast events (`TIME_SET`, `TIMEZONE_CHANGED`, `NSSystemClockDidChange`). On Windows it subclasses a message window for `WM_TIMECHANGE`. On Linux it uses a `timerfd` with `TFD_TIMER_CANCEL_ON_SET` to detect kernel clock changes with zero idle CPU cost. When a jump is detected the anchor is invalidated and an immediate resync begins.

---

## Tiered sync cadence (mobile)

By default `TrustedTime` runs a single uniform refresh loop
(`CadenceMode.singleTier30m`): every `refreshInterval` it re-races all
sources through full Marzullo consensus. This is unchanged from 1.x.

Mobile apps can opt into a two-tier schedule that is far cheaper on
battery and radio while keeping the anchor fresh:

- **Establish** — the full consensus cycle, run infrequently (24h via
  `mobileDefaults()`). This is the only tier that builds a new anchor.
- **Validate** — a lightweight freshness probe run frequently
  (`validateInterval`, 1h default): a short authenticated NTS burst
  against one source, keeping the lowest-RTT sample, with no consensus
  rebuild. If the probe disagrees with the anchor beyond
  `maxAllowedUncertaintyMs`, an establish cycle is triggered to recover.

In tiered mode the library also installs a `WidgetsBindingObserver` and
runs a validate probe when the app returns to the foreground after being
backgrounded for at least `foregroundValidateThreshold` (15m default) —
the moment the anchor is most likely to have drifted.

```dart
// Opt in to the tiered mobile schedule.
await TrustedTime.initialize(config: TrustedTimeConfig.mobileDefaults());

// Or compose it onto an existing config.
await TrustedTime.initialize(
  config: myConfig.copyWith(cadenceMode: CadenceMode.tieredMobile),
);

// Cheaply confirm the anchor on demand (e.g. before a sensitive action)
// without forcing a full resync. Returns false if the anchor disagrees
// with network time; throws TrustedTimeFreshnessProbeException if the
// probe could not run (no anchor yet, or no NTS source configured).
final fresh = await TrustedTime.validateFreshness();
```

`WidgetsFlutterBinding.ensureInitialized()` must have run before
`initialize()` for the foreground trigger to attach; in a headless
isolate the periodic validate timer still drives cadence on its own.

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
