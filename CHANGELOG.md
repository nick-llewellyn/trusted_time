# Changelog

## [Unreleased]

### Breaking Changes

- **`ntpServers` is no longer settable; the library ships a curated
  51-host inventory.** The `TrustedTimeConfig` constructor parameter
  is removed and `ntpServers` becomes a read-only getter returning a
  fixed inventory verified by live probe (`trusted_time-5fz`,
  2026-07-26): 51 hosts spanning 27 ASN groups, tiered anycast /
  unicast S1 / unicast S2. This exists so source selection can
  explore a real inventory rather than three hosts, and so the host
  set is a property of the library rather than of each install.
  Consumers passing `ntpServers:` must delete the argument; there is
  no replacement, including for internal or enterprise NTP. A
  `@visibleForTesting` `disableNtpForTesting` flag suppresses the
  pool for hermetic tests and is not a supported production knob.

  No host in the inventory is a documented smearing operator —
  `time.google.com`, `time.aws.com`, and `time.facebook.com` were
  probed and excluded on published-smear evidence. Stepping is
  documented for the major operators and metrology institutes and
  presumed for the remaining public servers, which run stock
  `ntpd`/`chrony`; the runtime defence against a smeared outlier
  remains the Marzullo intersection.

- **Default NTS list rebuilt around a stepping-only leap-second
  policy and administrative diversity.** `ntsServers` now defaults to
  `['time.cloudflare.com', 'nts.netnod.se']`: two anycast anchors
  from distinct operators, so the out-of-the-box config satisfies the
  default `minGroupCount` of 2 and can mint a verified truth box on
  its own (the previous single-host default never could). Every
  default host steps. Consumers pinning the old defaults explicitly
  are unaffected; consumers relying on the implicit defaults get the
  new list on their next sync.

- **NTS sources now group by registrable domain instead of full
  hostname.** `NtsSource.groupId` for `gbg1.nts.netnod.se`,
  `mmo1.nts.netnod.se`, and `nts.netnod.se` is now the single group
  `netnod.se` rather than three distinct groups, so
  `minGroupCount` counts administrative operators and a "diverse"
  verified quorum can no longer be minted from one operator's
  regional endpoints. Multi-label public suffixes are handled by a
  small embedded suffix set (`cam.ac.uk` under `ac.uk`,
  `neu.edu.cn` under `edu.cn`, etc.); unknown suffixes collapse
  conservatively to the last two labels, which can only merge groups
  (under-count diversity), never split them. The NTP tier's
  ASN-derived grouping is unchanged. Pools that relied on
  hostname-level grouping to reach `minGroupCount` from one
  operator's endpoints will now need genuinely distinct operators.

- **Removed the tiered validate cadence in favour of a 48h anchor-age
  policy.** `CadenceMode`, `TrustedTimeConfig.validateInterval`,
  `TrustedTimeConfig.foregroundValidateThreshold`,
  `TrustedTime.validateFreshness()`, and
  `TrustedTimeFreshnessProbeException` are gone, along with the
  periodic validate timer and the desktop sleep/wake divergence probe.
  A validate probe that agreed told you nothing `anchorAge` /
  `uncertainty` didn't already report, and one that disagreed escalated
  to a full sync anyway — so the engine now just syncs when the anchor
  is stale. The default `refreshInterval` changes from 30 minutes to
  48 hours, and a lifecycle observer (now installed in every mode)
  runs a full sync on app resume iff no trusted anchor exists or the
  anchor is at least one refresh interval old, measured on the same
  monotonic timeline `TimeAssessment.anchorAge` reports. The anchored
  staleness check honours `pauseAutomaticRefresh()`: while
  `automaticRefreshActive` is `false`, the engine initiates no
  anchor-age-driven syncs at all (timer and resume trigger alike);
  the unanchored resume *establish* attempt still proceeds.
  `TrustedTimeConfig.mobileDefaults()` pairs the 48h staleness bound
  with a 24h `backgroundSyncInterval`, giving the best-effort OS
  scheduler (iOS `BGTaskScheduler`, Android `WorkManager`) a full day
  of slack to land the daily job before a foreground resume forces a
  sync. Migration: delete any `cadenceMode:` / `validateInterval:` /
  `foregroundValidateThreshold:` arguments; pass an explicit
  `refreshInterval` if you relied on the old 30m foreground loop;
  replace `validateFreshness()` calls with a
  `getAssessment().anchorAge` check (staleness) or `forceResync()`
  (re-establish on demand).

- **Removed the offline estimation surface and speculative drift
  modelling in favour of observed per-boot drift history.**
  `TrustedTimeEstimate`, `TimeAssessment.estimate`, and
  `TrustedTimeConfig.oscillatorDriftFactor` are gone, along with the
  adaptive drift calibrator and the `tt_last_trusted_utc_ms` /
  `tt_last_anchor_wall_ms` secure-storage keys (never written or read
  anymore; the storage layer's wipe path still deletes them, so
  upgrading installs don't strand stale ciphertext). Two consequences:
  `getAssessment().uncertainty` is now the anchor's measured consensus
  uncertainty alone — it no longer grows with anchor age, so apply
  your own staleness policy against `anchorAge` — and unanchored
  postures carry no fallback timestamp (wall-clock extrapolation was
  manipulable by the very adversary this library defends against).
  In their place the engine passively records real oscillator
  behaviour: a new `TrustedTime.getDriftHistory()` diagnostics API
  returns per-boot `DriftBootRecord`s (first/latest anchor pairs,
  persisted for the last 10 boots), and `TimeAssessment` gains
  experimental `driftRate` / `driftCorrectedTime` fields, populated
  once the current boot has ≥1h of observed span. Prior boots'
  observations are never applied for correction. `TrustedTimeMock`
  assessments report the drift fields as `null` and
  `getDriftHistory()` as empty under a mock override.

- **`TrustedTime.initialize()` no longer waits for the first network
  sync.** The returned future resolves after local work only (storage
  restore, reboot check, timer arming) on every path; on a cold start
  the first sync cycle runs in the background. Anyone relying on
  "awaited `initialize()` ⇒ time is trusted" on a cold start is
  broken by this change and must adopt one of the two new
  primitives: `TimeAssessment.syncInProgress` (a new field — `true`
  whenever a sync cycle is in flight, including background refreshes
  and `forceResync`; unanchored + `syncInProgress` is the "resolution
  imminent" wait state) or `TrustedTime.firstSyncSettled` (a future
  completing when the first cycle concludes — success or failure
  alike; already complete on a warm restore; consult
  `getAssessment()` for the verdict afterwards). Awaiting
  `initialize()` then immediately reading `getAssessment()` on a cold
  start now yields `neverSynced` with `syncInProgress: true` instead
  of a concluded posture; insert `await TrustedTime.firstSyncSettled`
  where the old blocking behaviour is genuinely required. The error
  split is unchanged and now uniform: configuration errors
  (`ArgumentError` for an invalid trust config — now validated
  eagerly on every path, including warm restores that previously
  deferred it — or `TrustedTimeSecurityException` for an
  unsatisfiable `requireSleepAwareProjection`) throw from
  `initialize()`; network outcomes never do. `TrustedTimeMock` gains
  `setSyncInProgress()` to script the new field.

- **Unified the public retrieval surface into a single
  `TrustedTime.getAssessment()` call returning a `TimeAssessment`
  snapshot.** The fragmented getters — `now()`, `nowUnixMs()`,
  `nowIso()`, `getTime({requireSecure, minConfidence})`, `isTrusted`,
  `isSecure`, `authLevel`, `confidence`, `confidenceScore`,
  `nowEstimated()` — are removed. `TimeAssessment` carries the time
  and every caveat in one immutable value: `time` (`DateTime?`,
  non-null iff trusted), `reason` (`TrustStatusReason.synchronized` /
  `degraded` / `neverSynced` / `rebootDetected` / `syncFailed`),
  `authLevel`, `confidence` (now including `ConfidenceLevel.none`),
  `uncertainty`, `anchorAge`, plus derived `isTrusted`
  and `isSecure`. Posture is never an exception: an unanchored engine
  yields `time == null` with an explanatory `reason` instead of
  `TrustedTimeNotReadyException`, and strictness
  (`requireSecure` / `minConfidence`) becomes a caller-side gate on
  `isSecure` / `confidence` instead of a
  `TrustedTimeSecurityException` throw. The `onIntegrityLost` stream,
  `IntegrityEvent`, and `TamperReason` are removed with it: tier
  degradation is reported as `TrustStatusReason.degraded` on every
  assessment (plus an engine log warning), and reboot as
  `rebootDetected` — the pull model replaces the push stream.
  Migration: replace each removed getter with the corresponding
  `TimeAssessment` field, replace `getTime(requireSecure: true)` with
  an `isSecure` check, and replace `onIntegrityLost` listeners with
  `reason` checks at meaningful boundaries (after `initialize()`, on
  resume, before high-value operations). `TrustedTimeMock` loses
  `simulateTampering()` / `dispose()` and gains `setConfidence()`;
  `trustedLocalTimeIn()` and the exception types it throws are
  unchanged.

- **Removed the wall-clock drift monitor and native clock-change
  hooks.** Time projection is monotonic-only, so wall-clock
  manipulation cannot affect projected time; monitoring it added
  battery/complexity cost without a security benefit. Removed:
  `TamperReason.systemClockJumped`, `TamperReason.timezoneChanged`,
  the Dart-side adaptive drift-check loop, and the
  `trusted_time/integrity` platform event channel with all five native
  implementations (Android `IntegrityWatcher` broadcast receiver,
  iOS/macOS `NSSystemClockDidChange` observers, Windows
  `WM_TIMECHANGE` subclassing, Linux `timerfd` cancel-on-set watcher).
  Reboots (warm-start boot-ID check) and tier degradation are
  expressed through state rather than as stream events (see the
  assessment-API entry above). Migration: delete `switch` cases on
  the two removed enum members; reboot and degraded-tier handling
  is unchanged.

- **Dropped Web platform support.** The Web plugin
  (`trusted_time_web.dart`), its `pubspec.yaml` registration, the
  `web` / `flutter_web_plugins` dependencies, all `kIsWeb` runtime
  branches, and the conditional-import stubs for the NTP/NTS sources
  are removed; `dart:io` implementations are now imported directly.
  Web had no built-in time transport left after the HTTPS-source
  removal, no persistent monotonic clock (`performance.now()` is
  session-relative, so anchors could never survive a page load), and
  no background scheduler. Supported platforms are Android, iOS,
  macOS, Windows, and Linux.

- **Removed HTTPS `Date`-header time sources.** `HttpsSource`, the
  `TrustedTimeConfig.httpsSources` field, the `TrustedTimeConfig.web()`
  factory, and the `package:http` dependency are gone. HTTPS `Date`
  headers have whole-second granularity, no application-layer
  authentication, and consistently produced the widest intervals in
  consensus; NTP and NTS are strictly better on every axis on the
  supported IO platforms. Migration: delete `httpsSources:` arguments
  and rely on `ntpServers` / `ntsServers`.

- **Removed the `google.com` connectivity-probe fallback from mobile
  background sync.** Previously, a background fire without a registered
  callback (Android), or without a callback / plugin registrant (iOS),
  fell back to an HTTPS HEAD probe against `https://www.google.com` —
  the only network endpoint in the package not derived from
  user-configured time sources. Such fires are now no-ops that perform
  no network activity; the anchor is refreshed on the next foreground
  launch. All network traffic is strictly limited to the configured
  time sources. Integrators relying on the probe's keep-alive semantics
  should register a background callback via
  `TrustedTime.registerBackgroundCallback` (see ADR 0002 amendment).

- **`TrustedTimeConfig.ntsTrustMode` removed; trust policy is now
  expressed via two fields.** The single `nts.TrustMode` passthrough
  (`ntsTrustMode`, default `platformWithFallback`) is replaced by
  `usePlatformTrust` (`bool`, default `false`) and `customRootCerts`
  (`List<int>`, default `const []`). Migrate:
  - `ntsTrustMode: nts.TrustMode.bundledOnly` (or unset) → leave both
    new fields at their defaults (set nothing).
  - `ntsTrustMode: nts.TrustMode.platformOnly` → `usePlatformTrust: true`.
  - `ntsTrustMode: nts.TrustMode.custom` (with engine-supplied roots) →
    `customRootCerts: <int>[...]`.

  Setting both `usePlatformTrust: true` and a non-empty `customRootCerts`
  names two mutually exclusive trust sources and throws `ArgumentError`
  when the engine resolves the trust mode (via
  `TrustedTimeConfig.effectiveTrustMode`).

- **Security-by-default: the effective trust mode now defaults to
  `bundledOnly`.** The previous effective default,
  `platformWithFallback`, silently accepts a platform- or MDM-installed
  inspection CA — and therefore a man-in-the-middle NTS-KE handshake —
  whenever one is present in the OS trust store. The default now
  validates every NTS-KE handshake against the bundled `webpki-roots`
  set only, so authenticity is end-to-end. Managed-device deployments
  that depend on a pinned corporate CA must explicitly opt in with
  `usePlatformTrust: true`; the change is visible and intentional.

- **`TimeInterval` constructor is no longer `const`.** Inverted bounds
  (`startMs > endMs`) previously slipped past a debug-only `assert` in
  release builds, silently corrupting midpoint/width arithmetic
  downstream. The constructor now throws `ArgumentError` in all build
  modes, which removes `const` constructibility. Migrate
  `const TimeInterval(...)` (and enclosing `const` contexts that
  contain one) to non-const construction — typically `const x = ...` →
  `final x = ...`. Behaviour is otherwise unchanged for valid
  intervals.

### Added

- **`NtpServerInfo`, `NtpServerTier`, `NtpLeapPolicy`, and
  `config.ntpInventory`.** The curated inventory carries per-host
  metadata rather than bare strings: the curation tier a host was
  admitted under, the stratum and autonomous system a live probe
  observed, and how firmly its leap-second behaviour is established.
  Source selection needs the tier to know which hosts are
  self-localizing, and the group id to avoid drawing a quorum that
  counts one operator eleven times; both were previously recoverable
  only from a doc comment. `ntpServers` remains the hostname view of
  the same data.

  Measured RTT and resolved IP are deliberately absent. An RTT from
  the probe's UK vantage is a misleading prior for a device elsewhere,
  and a resolved address is stale as soon as an operator renumbers —
  both are properties of a query rather than of a host.

- **Durable per-source quality stats** (`SourceQualityTracker`): the
  smoothed source metrics — EWMA RTT (from measured `TimeSample.delayMs`),
  EWMA in-cycle burst jitter, EWMA success rate, last-probed timestamp,
  and stratum — now survive process death. They are persisted through
  `AnchorStorage` (new `loadSourceStats`/`saveSourceStats`, secure-storage
  key `tt_source_stats_v1`), saved after every successfully banked cycle
  and restored on engine start (both foreground `initialize()` and the
  headless background worker), all gated on `persistState` like the
  anchor. A background cycle therefore ranks servers on accumulated
  RTT/success history instead of starting blind. RTT is the proximity
  signal proper — it stays honest through VPNs, travel, and CGNAT where
  geography lies. Scoring now weighs measured RTT (30%), consensus
  participation (25%), success rate (25%), burst jitter (10%), and
  stratum (10%); a probe timeout decays a source's success rate —
  penalizing and deferring it — but never permanently drops it, so one
  lost UDP packet on a lossy link cannot blacklist a good server.
  Persisted stats are pruned to the 32 most recently probed sources and
  entries older than 30 days are discarded on restore.

- **Sleep-aware projection is now observable and enforceable.** The
  suspend-frozen `Stopwatch` fallback (below) was previously silent: a
  bridge-less config could not tell which timeline projection rode.
  - `TrustedTime.isProjectionSleepAware` reports whether projection
    rides the sleep-aware `nts.MonotonicClock` (`true`) or the
    suspend-frozen `Stopwatch` fallback (`false`).
  - `TrustedTimeConfig.requireSleepAwareProjection` (default `false`)
    makes suspend-correct projection a hard requirement: when only the
    fallback is available, `initialize()` throws
    `TrustedTimeSecurityException` at engine start (fail-fast), and
    time projection carries the same guard as defence in depth. The
    default preserves existing behaviour — the fallback is accepted
    and merely observable.
  - `resolveMonotonicReader()` now returns a `MonotonicReader` carrying
    the resolved `read` function and an `isSleepAware` flag;
    `SyncClock` exposes `isSleepAware` for the reader captured with the
    current anchor (probing the factory before the first anchor).

### Changed

- **A sync cycle no longer sweeps the whole NTP inventory.** Each cycle
  now queries the 10 vantage-independent hosts — reached by anycast or
  DNS steering, so they resolve to something near the caller wherever
  the device is and need no per-install ranking — plus a bounded sample
  of the 41 vantage-dependent unicast hosts, whose proximity varies by
  where the device happens to be and so has to be measured. That is the
  `NtpServerTier.anycast` tier in full, against a rotating slice of the
  two unicast tiers, rather than all 51 hosts every cycle. The unicast
  sample rotates by staleness, never-probed first, so every host is
  still measured; it just takes a few cycles rather than one. An
  integrator observes materially fewer outbound queries per cycle at
  unchanged consensus quality: that quorum alone satisfies the default
  `minGroupCount`, and the unicast tier was only ever feeding the
  ranking.

  The rotation order is a per-install permutation, seeded once and
  persisted (secure-storage key `tt_explorer_seed_v1`, gated on
  `persistState` like the anchor). A fixed order would make the
  sequence of hosts a device contacts a constant shared by every
  install, and therefore usable as a join key across networks that see
  only part of the traffic. Losing the seed costs an install its walk
  order and nothing else.

  How many unicast hosts a cycle samples depends on the platform: three
  on iOS, eight everywhere else. iOS is the only target whose OS
  hard-kills a background run at a deadline (`BGAppRefreshTask`, ~30 s),
  and the narrow budget is what fits under it alongside the quorum.
  No configuration surface changed — `TrustedTimeConfig` gained no
  required field and the new behaviour is the default.

- **A fresh install now converges on its server ranking in days rather
  than weeks.** The first eight foreground cycles after install sample
  the wider unicast budget regardless of platform, which is ~1.6 sweeps
  of the unicast pool — enough that most hosts have a second
  observation for the EWMAs to smooth against. The count is persisted
  (`tt_explorer_boost_v1`) and decays per banked cycle, so it survives
  process death and stops on its own; an install upgrading from a
  version before the counter existed gets one front-load, the same
  posture as a fresh install. Headless background cycles are never
  front-loaded, so the iOS deadline is unaffected.

  Exploratory probes run outside the cycle's critical path under their
  own 2 s timeout: they feed the ranking only and cannot contribute to
  consensus, so `sync()` completes on the anycast quorum without
  waiting for them. The front-load therefore costs no cycle latency.
  For the same reason the reported `confidence` breakdown divides by
  the consensus-eligible sources only — the coverage ratios do not move
  with the exploration width.

### Fixed

- **Projected time no longer freezes during device sleep** (with NTS
  configured). `SyncClock` — the sub-microsecond projection behind
  the assessment — and the foreground-validate background-duration reading
  previously measured elapsed time with Dart's `Stopwatch`, whose
  underlying clock (`CLOCK_MONOTONIC` / `mach_absolute_time`) stops
  during suspend. A device that slept between syncs returned a
  projected time behind by the sleep duration until the next sync or
  reconciliation. Both now prefer the sleep-aware
  `nts.MonotonicClock` (`CLOCK_BOOTTIME` / `mach_continuous_time` /
  `QueryInterruptTimePrecise`), resolved per anchor update so a
  bridge initialized after startup is picked up at the next sync.
  Configs that never initialize the nts bridge (NTP-only)
  keep the previous `Stopwatch` behaviour. `SyncClock` gains an
  injectable `readerFactory` seam for tests.

## [2.1.0]

### Breaking Changes

- **`NtsAuthLevel.advisory` removed** (deprecated since v2.0.3).
  Any exhaustive `switch` or `if` branch handling `.advisory` will fail at compile
  time — simply delete the case. Code that previously treated `.advisory` as a
  weak-auth signal should use `NtsAuthLevel.none` for unauthenticated sources and
  `NtsAuthLevel.verified` for RFC 8915-authenticated ones.

  **Persisted anchor migration**: `authLevel` is now serialized by name — a
  self-describing encoding that survives enum changes — so a `verified` anchor
  round-trips back to `verified`. `TrustAnchor.fromJson` reads the current name
  form and still decodes legacy v2.0.x ordinals (`none=0, advisory=1,
  verified=2`): old `advisory` decodes as `none`, old `verified` as `verified`.
  No data loss, no misidentification as verified.

### Dependencies

- **`nts`** (already `^5.0.0` on this fork since #40): v2.1.0 now consumes the
  per-query `serverStratum` on `NtsTimeSample`, feeding NTS server stratum into
  source quality scoring. The `RustLib` → `NtsRustLib` rename is handled
  internally; no consumer changes needed.
- **`flutter_secure_storage` `^10.0.0`** (lower bound unchanged — all 10.x are
  API-compatible; consumers on any 10.x version are unaffected).
- **`http` `">=1.0.0 <2.0.0"` → `^1.3.0`**: Tightens the lower bound to a known-good
  version. Consumers already on 1.3.x+ are unaffected.
- **`timezone` `">=0.9.0 <1.0.0"` → `">=0.9.0 <0.12.0"`**: Tightens the upper
  bound, capping below the untested `0.12.0` line. Consumers on 0.9.x–0.11.x
  remain satisfied; `0.12.0` and above are now excluded.

### Added

- **Adaptive Clock Drift Compensation** (`DriftCalibrator`): The engine now tracks
  per-device oscillator drift across successive trust anchors and computes a
  device-specific drift rate using median filtering. This rate replaces the static
  `oscillatorDriftFactor` in `nowEstimated()` once a 30-minute observation window
  has been accumulated. The calibrator enforces a 100 ppm sanity cap — measurements
  above this threshold are discarded and the static fallback is retained. Drift state
  is cleared on integrity violations (clock jump, reboot).

- **Dynamic Time Source Quality Scoring** (`SourceQualityTracker`): The sync engine
  now ranks sources each cycle based on a weighted score combining RTT/uncertainty
  (40%), consensus participation rate (40%), and NTP stratum (20%). Higher-quality
  sources are queried first to improve early-exit latency.

  **Starvation guard**: Sources that haven't been queried within 5 consecutive cycles
  are force-included regardless of their rank, keeping their quality estimates fresh
  and preventing permanent exclusion of lower-ranked sources.

  NTP stratum hints can be registered via `SourceQualityTracker.setStratum()` when
  a source's stratum is known externally (e.g. via SNMP or NTP extension fields).

### Tests

- `test/drift_calibrator_test.dart`: 6 tests covering the observation window gate,
  synthetic drift measurement, 100 ppm rejection, outlier filtering via median, and
  reset behaviour.
- `test/source_quality_tracker_test.dart`: 10 tests covering ranking by participation,
  uncertainty, and stratum; the full starvation lifecycle; deduplication; and
  out-of-range stratum handling.
- `test/nts_auth_level_migration_test.dart`: 6 tests verifying the two-variant enum
  shape and the v2.0.x → v2.1.0 `fromJson` ordinal migration (none, advisory→none,
  verified, out-of-range).

---

## [2.0.3]

### Changed
- **Breaking**: Bumped minimum SDK requirements to Dart 3.10.0 / Flutter 3.38.0 for Native Assets support.
- **NTS RFC 8915 Compliance**: Migrated from pure-Dart NTS implementation to [`package:nts`](https://pub.dev/packages/nts).
  - Now uses Rust-based TLS 1.3 with proper RFC 5705 keying material exporters.
  - Full AES-SIV-CMAC-256 AEAD authentication (previously advisory-only).
  - `NtsAuthLevel.advisory` is now deprecated; use `NtsAuthLevel.verified` for cryptographic guarantees.
  - Thanks to `nick-llewellyn` for the technical guidance on RFC 5705 constraints.

### Improved
Thanks to `nick-llewellyn` for the correctness audit enhancing the Marzullo consensus implementation:

- **Robust source counting**: Enhanced `participantCount` to use multiset-based unique source tracking. Multiple overlapping samples from a single source now correctly contribute one participant to the quorum.
- **Improved sweep algorithm**: The Marzullo sweep now optimizes on unique source diversity rather than raw interval overlap, yielding higher-quality consensus when sources provide multiple samples.
- **Precision safeguards**: Added minimum 1ms floor to `uncertaintyMs`. Narrow intervals now report realistic precision instead of implying sub-millisecond accuracy.
- **Input validation**: `SyncEngine` now filters samples with negative uncertainty before processing, protecting the monotonic clock reference from malformed measurements.
- **Enhanced anchor integrity**: Anchor creation now validates against `ConsensusResult.participants`, ensuring only samples overlapping the consensus window influence the trusted time estimate.

### Fixed
- **HTTP Security**: Updated `http` package constraints to resolve pub.dev security advisory decoding issues.
- **Pub.dev Compatibility**: Fixed `FormatException: advisoriesUpdated must be a String` error during dependency resolution.
- **Quorum Messaging**: Improved error messages to show accurate counts of eligible vs rejected samples with proper pluralization.

## [2.0.2]

### Fixed
- **Documentation**: Comprehensive enhancement of all public API dartdoc comments with detailed descriptions.
  - Replaced 8+ placeholder "Documented." comments with full documentation
  - Enhanced `TrustedTimeMock` constructor and method documentation
  - Added detailed docs for `TrustAnchor`, `SyncMetrics`, `ConsensusResult`
  - Documented exception classes and configuration classes
  - Improved public API coverage for pub.dev scoring

## [2.0.1]

### Fixed
- **Dependency Resolution**: Loosened constraints for `web`, `http`, and `timezone` to resolve pub.dev analyzer conflicts.
- **Documentation**: Enhanced dartdocs for public symbols to improve pub.dev score.

## [2.0.0]

### Added
- **Probabilistic Trust Modeling**: Introduced `ConfidenceLevel` (Low, Medium, High) and `confidenceScore` with exponential decay to model temporal uncertainty over time.
- **Self-Healing Consensus Engine**:
    - **Adaptive Thresholds**: Dynamic sample filtering based on 3x median uncertainty.
    - **Exponential Source Cooldown**: Failure-count based blacklisting ($2^{failureCount}$ min) to isolate consistently unreliable authorities.
    - **Consensus Stability Guard**: Incremental processing now requires $N=2$ (or $N=3$ under high variance) consecutive matching intervals before early-exit.
- **NTS (RFC 8915) Authenticated Time**: Pure-Dart implementation of Network Time Security for tamper-proof NTP synchronization (Cryptographic Preview).
- **Enterprise Observability**:
    - Introduced `SyncMetrics` for machine-readable telemetry (latency, uncertainty, diversity, depth).
    - Added structured **Confidence Breakdown** for deep-field debugging of trust establishment.
- **Strict Security Intent API**: New `TrustedTime.getTime({bool requireSecure})` for fail-fast cryptographic guarantees.
- **Capability Discovery**: Added `supportsSecureTime` to allow graceful application fallback when NTS is unavailable.
- **Robust Desktop Support**: Verified native implementations for macOS, Windows, and Linux, ensuring consistent monotonic clock behavior across all six Flutter platforms.
- **Intelligent Background Sync**: Scheduler-backed synchronization on mobile (WorkManager for Android, BGTaskScheduler for iOS) with safe `Timer`-based fallbacks for desktop.

### Changed
- **Domain Refactor**: Split `TimeSample` into `TimeInterval` (pure mathematical primitive) and `TimeSample` (enriched telemetry wrapper).
- **Integrity Feedback Loop**: Anomaly detection now triggers immediate state purge (cache invalidation) and high-priority synchronization.
- **Hardened Consensus**: Strictly enforced group-diversity requirements to mitigate median-poisoning and correlated failures.
- **Architecture Decisions**: Published comprehensive ADRs (0001-0004) covering monotonic strategy, Marzullo consensus, NTS implementation, and background sync.
- **Unified Darwin Layout**: Migrated iOS and macOS native implementations to a shared SwiftPM-ready directory for perfect pub.dev compliance.

### Fixed
- **Marzullo Engine Correctness**:
  - Fixed tie-breaking to use closed-interval semantics (depth counting).
  - Corrected `participantCount` to report unique source IDs instead of raw overlap depth.
  - Implemented 1ms uncertainty floor to prevent downstream calculation errors.
- **Platform Hardening**:
  - Windows: Migrated to `GetTickCount64` and subclassed `WM_TIMECHANGE` for robust integrity monitoring.
  - Linux: Switched to `CLOCK_BOOTTIME` and `timerfd` to correctly track time during system suspend.
  - Thread Safety: Re-affirmed and enforced main-thread dispatching for all Darwin platform event channels.

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
