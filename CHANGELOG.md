## 2.0.2

**Docs: scope security claims to per-source threat coverage**
- Reworked README "Security Model" section to separate user-side threats (covered by the monotonic anchor regardless of source) from network-side threats (per-source coverage matrix across NTP / HTTPS / NTS / Marzullo consensus).
- Qualified the lead paragraph and Features list: "tamper-proof" is now scoped to user-side system-clock manipulation; per-sample MITM resistance is correctly attributed to NTS (RFC 8915) rather than implied as a property of every source.
- Cross-linked `SECURITY.md` from the Security Model section for vulnerability disclosure.
- No code or behavior changes.

## 2.0.1

**Fix: NTS sample timestamp accuracy**
- `NtsSource` now applies the standard NTP symmetric-path estimator (`T3 + RTT/2`) when constructing `TimeSample.networkUtc`. Previously the raw server transmit timestamp (T3) was forwarded unadjusted, which violated the `TimeSample` contract requiring UTC-at-receipt anchored to `capturedMonotonicMs` (≈ T4). The systematic underestimate (typical RTT/2 of 4–15ms) would have biased the `SyncEngine` Marzullo consensus negative, especially when NTS was the only authenticated source in the mix.
- Added a dedicated unit test pinning the half-RTT adjustment behavior, including odd-RTT truncation and zero-RTT degenerate cases.

## 2.0.0

**New: Network Time Security (NTS, RFC 8915)**
- Added `NtsSource` — authenticated NTPv4 over UDP with TLS-derived AEAD keys, wrapping [`package:nts`](https://pub.dev/packages/nts).
- Added `TrustedTimeConfig.ntsServers` (opt-in, empty by default) for configuring NTS-KE hosts. The IANA-assigned port `4460` is always used.
- Added `TimeSourceKind.nts` and `TimeSourceMetadata.authenticated` (defaults to `false` for NTP/HTTPS/custom; `true` for NTS).
- `SyncEngine` queries NTS sources concurrently alongside NTP and HTTPS, treating their samples identically for Marzullo intersection.
- Web behavior unchanged: `NtsSource` is stubbed out via conditional export and silently skipped by the engine.
- See `docs/adr/0001-nts-integration-strategy.md` for the design rationale.

**Breaking**
- SDK floor raised: `sdk: ^3.10.0`, `flutter: >=3.38.0`. Required by `package:nts` and the underlying Native Assets / `flutter_rust_bridge` v2 toolchain. The Dart-level API surface remains additive — apps that don't configure `ntsServers` see no behavioral change beyond the SDK requirement.

## 1.2.1


**Critical enhancements**
- iOS/macOS: Enhanced channel initialization avoiding naming mismatch
- Android: Optimized `BroadcastReceiver` lifecycle to efficiently detach
- Android: Upgraded `BackgroundSyncWorker` to perform HTTPS connectivity check
- `SyncClock.elapsedSinceAnchorMs()` upgraded to use Dart `Stopwatch` (monotonic) instead of wall-clock delta
- Linux: Implemented proper `get_platform_version()` parsing to resolve implicit logic
- Example integration test upgraded to effectively await `TrustedTime.initialize()`

**High-priority enhancements**
- iOS BGTask handler upgraded to perform HTTPS HEAD check (parity with Android worker)
- iOS BGTask closure stabilized to capture dynamic interval value
- Windows native test enhanced building with explicit constructor
- Example widget test stabilized to match actual app UI

**Engine improvements**
- Serialized sync via `Completer` introduced to prevent concurrent `_performSync()` calls
- Integrity events (`systemClockJumped`, `deviceRebooted`) configured to invalidate trust and optimally trigger resync
- Automatic retry engine introduced with configurable delay on sync failure
- Background sync optimally enabled on both warm-restore and cold-start paths
- `dispose()` architecture enhanced to clear `SyncClock` static state, preventing cross-test leakage
- `initialize()` short-circuits engine init immediately when test mock is active
- `timezoneChanged` streamlined as an intentional non-resync event (UTC is timezone-independent)
- All `debugPrint` calls optimized and guarded by `kDebugMode` for release builds

**Algorithm & sources optimizations**
- Marzullo tie-breaking upgraded: lower endpoints prioritize over upper at equal times
- `bestEnd` intelligently resets when finding new maximum overlap depth
- `HttpsSource`: Implemented robust HEAD→GET fallback architecture on 405 or missing Date header
- Comprehensive HTTP date parser expanded (RFC 7231 + RFC 850 formats)
- NTP source optimized via conditional imports (`dart:io` guard) for deep web compatibility
- `TrustedTimeConfig.operator==` and `hashCode` stabilized to comprehensively include `additionalSources`

**Platform native architecture**
- Android: Migrated `RECEIVER_NOT_EXPORTED` flags properly for API 33+ implicit-intent receivers
- Android: Deprecated and removed unused `SharedPreferences` writes from background worker
- Android: Standardized `build.gradle` structure alongside `AndroidManifest.xml`
- iOS: `BGTaskScheduler.register` initialization restricted optimally to run once via `bgRegistered` flag
- iOS: `Info.plist` properly documents `BGTaskSchedulerPermittedIdentifiers` requirement tracking
- Windows: Deprecated legacy `"trusted_time"` method channel registration safely
- Linux: Deprecated legacy `"trusted_time"` method channel registration safely
- Web: Registered `MethodChannel` handlers gracefully for monotonic and background channels

**Cleanup & Standardization**
- Deprecated 7 dead platform abstraction files
- Streamlined bundle, removing `plugin_platform_interface` dependency
- Reverted misleading `Package.swift` SPM target for CocoaPods plugin standard
- Stripped committed `test_results.txt` and `logcat_full.txt` logs fully prioritizing Git cleanliness
- Renamed `sync_engine_test.dart` → `models_test.dart` to logically match content
- Broadened SDK constraints scaling accessibility: `sdk: >=3.4.0`, `flutter: >=3.19.0`

**Validation Pipeline Enhancement**
- Scaled 54 total tests across 9 test files (up from 8 tests originally)
- Instated `TrustedTimeEstimate` tests (isReasonable, toString)
- Instated `IntegrityMonitor` tests (reboot detection, multiple attach, double dispose)
- Instated `TrustedTimeConfig` equality tests covering `additionalSources`
- Instated `SyncClock.reset()` verification structure
- Adjusted timing bounds dynamically in SyncClock tests for CI reliability scaling

**CI & Documentation**
- CI workflow modernized to deeply analyze example app alongside plugin
- `SECURITY.md` validation tables strictly updated
- `CHANGELOG.md` properly reflects comprehensive audit validations

## 1.2.0

Major stability and accuracy update with desktop support.

- Added integrity monitoring (`Stream<IntegrityEvent>`)
- Added offline time via `nowEstimated()`
- Added testing override support
- Improved timezone reliability (IANA-based)
- Added Windows & Linux observers

**Fixes & improvements**
- Safer storage behavior
- Correct config usage (NTP/HTTPS)
- Windows & Linux stability fixes
- SDK updates

**Breaking**
- `UnknownTimezoneException` replaces generic errors

## 1.0.5

* **iOS/macOS**: Implemented proper Swift Package Manager (SPM) support following Flutter 3.24+ standards.
* **Chore**: Removed obsolete lint rules from `analysis_options.yaml` for Dart 3.x compatibility.


## 1.0.4

* **Web**: Full WASM compatibility by removing `dart:io` dependencies and implementing conditional imports.


## 1.0.3

* Fix workflows: formatting and release check (fa4e61a)
* Format env block in release workflow (35168a2)
* Add automated release workflows and iOS packaging (68949cd)

## 1.0.1

- **Chore**: Implemented a fully automated release and publishing workflow using GitHub Actions.
- **Fix**: Added full platform support for Web, Windows, macOS, and Linux.

## 1.0.0

- **Initial High-Integrity Release**: Production-ready engine for tamper-proof UTC time.
- **Marzullo Consensus**: Multi-source quorum resolution from Tier-1 NTP and HTTPS providers.
- **Temporal Baseline**: Hardware-anchored monotonic timeline ensuring zero-drift consistency.
- **Full Jitter Backoff**: Industry-standard retry strategy for high-resiliency cloud connectivity.
- **Zero-Alloc Performance**: Memory-optimized internal stack with <1μs synchronous retrieval.
