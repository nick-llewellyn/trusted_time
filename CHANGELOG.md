## 1.0.0

Initial public release of `trusted_time_nts` — an independently maintained, NTS-augmented fork of [`trusted_time`](https://pub.dev/packages/trusted_time) by `Sahad2701`. Renamed for distinct ownership on pub.dev and an independent release cadence; the original work is acknowledged with thanks.

**Core engine**
- Tamper-resistant UTC clock anchored to a hardware monotonic baseline (`SystemClock.elapsedRealtime` on Android, `ProcessInfo.systemUptime` on iOS/macOS, `CLOCK_BOOTTIME` on Linux, `GetTickCount64` on Windows; `performance.now()` on web).
- Multi-source Marzullo intersection across NTP, HTTPS-Date, and (optional) NTS samples; lower-endpoint-priority tie-breaking and overlap-depth tracking.
- Encrypted persistence of the trust anchor via `flutter_secure_storage`, surviving cold restarts.
- Synchronous `TrustedTime.now()` / `nowEstimated()` access with sub-microsecond overhead after warm-up.

**Network Time Security (NTS, RFC 8915)**
- `NtsSource` provides authenticated NTPv4 over UDP with TLS-derived AEAD keys via [`package:nts`](https://pub.dev/packages/nts).
- Opt-in via `TrustedTimeConfig.ntsServers`; IANA port `4460` is fixed.
- `TimeSourceMetadata.authenticated` distinguishes cryptographically authenticated samples from clear-text NTP/HTTPS.
- Half-RTT (`T3 + RTT/2`) adjustment applied so NTS samples honour the `TimeSample` UTC-at-receipt contract used by Marzullo consensus.
- Web is stubbed cleanly: NTS sources are silently skipped on the web platform.
- See [`doc/adr/0001-nts-integration-strategy.md`](doc/adr/0001-nts-integration-strategy.md) for the design rationale.

**Headless background sync**
- `TrustedTime.registerBackgroundCallback(...)` + `enableBackgroundSync(...)` schedule a real Marzullo-quorum refresh from the OS scheduler (Android `WorkManager`, iOS `BGAppRefreshTask`), spinning up a headless `FlutterEngine` and persisting a fresh anchor.
- Connectivity-only HTTPS HEAD fallback preserved for integrators that have not yet adopted the host-registered callback pattern.
- See [`doc/adr/0002-headless-background-sync.md`](doc/adr/0002-headless-background-sync.md) for the headless-engine design.

**Integrity monitoring**
- Reactive `Stream<IntegrityEvent>` for `systemClockJumped`, `deviceRebooted`, and `timezoneChanged` events.
- Clock-jump detection on Linux uses `timerfd` with `TFD_TIMER_CANCEL_ON_SET` for kernel-level signal of `CLOCK_REALTIME` changes.
- Reboot detection via monotonic-baseline mismatch versus persisted anchor.

**Timezone handling**
- IANA timezone database embedded via `package:timezone`; `TrustedTime.nowInZone(...)` is independent of device timezone setting.
- `UnknownTimezoneException` for unrecognised IANA identifiers.

**Platform support**
- Android, iOS, macOS, Windows, Linux, web — all platforms fully implemented.
- Native plugin classes: `TrustedTimeNtsPlugin` (Kotlin, Swift, C++); GLib type prefix `trusted_time_nts_plugin_*` on Linux; web entry `TrustedTimeNtsWebPlugin`.
- Method/event channels are namespaced under `trusted_time_nts/` (e.g. `trusted_time_nts/monotonic`).

**SDK requirements**
- `sdk: ^3.10.0`, `flutter: >=3.38.0`. The floor is driven by `package:nts` (Native Assets / `flutter_rust_bridge` v2 toolchain). Apps that do not enable NTS see no behavioural change beyond the SDK requirement.

**CI/CD**
- Matrix CI across Flutter `3.38.10` and `3.41.7` (Android + iOS), `pana`, and `flutter pub publish --dry-run`.
- Tag-driven release workflow publishes to pub.dev via OIDC trusted publishing — no long-lived tokens.
