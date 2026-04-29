# ADR 0002: Real headless background anchor refresh

- Status: **Accepted**
- Date: 2026-04-29
- Tracking issue: `trusted_time-e0v`
- Depends on: ADR 0001 (NTS integration), `package:nts` ≥ 1.3.0

## Context

The `enableBackgroundSync` API surfaces as a real periodic anchor refresh in the public dartdoc and in `TrustedTimeConfig.backgroundSyncInterval`, but the native implementations on both platforms only perform a connectivity probe:

- `android/src/main/kotlin/.../TrustedTimePlugin.kt`: `BackgroundSyncWorker.doWork()` issues an HTTPS HEAD against `https://www.google.com` and returns.
- `ios/Classes/TrustedTimePlugin.swift`: `performBackgroundCheck(task:)` issues the same HEAD request via `URLSession.shared.dataTask`.

Neither path acquires a `TimeSample`, runs the Marzullo consensus, or persists a refreshed `TrustAnchor`. The behaviour does not match the marketed capability, and consumers relying on a long-running session resuming with a fresh anchor at app re-entry are silently getting a stale persisted anchor (warm-restored via `_bootstrap()` in `TrustedTimeImpl`) plus a network probe that has no effect on trust state.

## Decision

**Implement Option 1: real headless anchor refresh on Android (`WorkManager` + headless `FlutterEngine`) and iOS (`BGAppRefreshTask` + headless `FlutterEngine`).** The host-side dispatch follows the **host-registered callback pattern** used by `package:workmanager` and `package:flutter_local_notifications`:

1. The host app declares a top-level `@pragma('vm:entry-point')` function that calls `await TrustedTime.runBackgroundSync()`.
2. Before `runApp`, the host registers it via `TrustedTime.registerBackgroundCallback(callback)`.
3. The package resolves the callback to an `int64` handle via `PluginUtilities.getCallbackHandle` and persists it through the `trusted_time/background` method channel — `SharedPreferences` on Android, `UserDefaults` on iOS.
4. When `WorkManager` or `BGTaskScheduler` fires, the native worker reads the handle, instantiates a headless `FlutterEngine`, runs the registered Dart entrypoint, awaits a completion notification on a method channel, and tears the engine down inside the OS budget.
5. **Back-compat fallback:** if no handle is registered, the worker falls back to the existing HTTPS HEAD probe and exits successfully. Existing integrators that called `enableBackgroundSync` without ever calling `registerBackgroundCallback` keep their previous behaviour and do not break.

The Dart entrypoint (`TrustedTime.runBackgroundSync`) bypasses `TrustedTimeImpl.init`'s timer/integrity-monitor setup; it constructs a `SyncEngine` directly, runs a single `await syncEngine.sync()` against the configured sources, persists the resulting `TrustAnchor` through `AnchorStore`, and returns. The next foreground `TrustedTime.initialize()` warm-restores from this freshly-written anchor and immediately reports trusted time without a network round-trip.

## Alternatives considered

- **Option 2: rename to `scheduleConnectivityCheck`.** Rejected. The marketed capability is "background sync"; renaming would be honest but loses real value to consumers operating long-running session apps that benefit from fresh anchors at re-entry. We chose to *honour* the contract instead of *retreating* from it.
- **Pattern B: package-internal `@pragma('vm:entry-point')` callback (zero host-app changes).** Rejected. Tree-shaking in release-mode AOT can elide a callback that is referenced only from native code unless it is anchored from a host-app symbol. The community standard (`workmanager`, `flutter_local_notifications`) is host-registered for this exact reason. The one-line cost on the host app is acceptable for a security-sensitive package where misconfiguration should be loud (a missing `@pragma` in release surfaces immediately at `registerBackgroundCallback` because `getCallbackHandle` returns `null`, which we throw on).
- **Use `package:workmanager` directly.** Rejected. Adding a 3rd-party plugin dependency for what is fundamentally a one-shot WorkManager job (Android) plus a one-shot BGAppRefreshTask (iOS) duplicates the plumbing already in `TrustedTimePlugin.kt` and `TrustedTimePlugin.swift`. The hand-rolled implementation is ~80 lines of Kotlin + ~80 lines of Swift on top of what we already have.

## Consequences

**Positive**

- The marketing claim becomes accurate: `anchor.networkUtcMs` actually advances after a background fire.
- Warm-restore at app re-entry uses fresh data instead of a potentially day-old anchor.
- The fallback path means existing callers see no breakage; the new behaviour is opt-in via `registerBackgroundCallback`.

**Negative**

- Battery cost: a headless engine cold-start plus a multi-source NTP/NTS query is more expensive than an HTTPS HEAD. Mitigated by the `intervalHours` clamp (`>= 1`) and the OS schedulers' own throttling.
- Cold-start latency in the OS budget: iOS BGAppRefreshTask grants ~30s; engine init + plugin registration + a `maxLatency: 3s` sync must fit. We rely on the existing `maxLatency` ceiling and the `package:nts` ≥ 1.2.0 deadline-aware budget enforcement (RFC 8915 §4 NTS-KE phase + UDP NTPv4 phase, both bounded by a single `Deadline`).
- The host app must add `@pragma('vm:entry-point')` to its callback. Misuse fails loudly at `registerBackgroundCallback` in debug, and falls through to the HTTPS HEAD fallback in release if `getCallbackHandle` returns null at registration time (we still throw an `ArgumentError`, but the worker fallback ensures no crash if the handle was never persisted).
- iOS host apps must add the BGTask identifier to `Info.plist`. Without it, `BGTaskScheduler.shared.register` fails silently and the worker never fires. Documented in the plugin dartdoc and in the existing Swift plugin docstring.

**Failure modes and operator response**

| Failure | Symptom | Remediation |
|---|---|---|
| Host forgot `@pragma('vm:entry-point')` | `getCallbackHandle` returns null in release | `registerBackgroundCallback` throws `ArgumentError` synchronously |
| Host forgot `registerBackgroundCallback` | Background fires execute HTTPS HEAD only | Documented as the back-compat fallback; debug log warns |
| iOS `Info.plist` missing `BGTaskSchedulerPermittedIdentifiers` | `register(forTaskWithIdentifier:)` returns false silently | Existing dartdoc on `TrustedTimePlugin` documents the requirement |
| Network unreachable during BG fire | `SyncEngine.sync` throws `TrustedTimeSyncException` | Worker returns `Result.retry()` (Android) / `setTaskCompleted(success: false)` (iOS); OS reschedules |
| OS kills the engine past the budget | `task.expirationHandler` (iOS) / `WorkInfo.State.CANCELLED` (Android) | Engine teardown is cancelled cleanly; next scheduled fire retries |

## Phased rollout

1. **Phase 1 (this ADR):** Dart-side API (`runBackgroundSync`, `registerBackgroundCallback`) + back-compat fallback. Existing callers unaffected.
2. **Phase 2:** Android `BackgroundSyncWorker` headless engine bootstrap.
3. **Phase 3:** iOS `BGAppRefreshTask` headless engine bootstrap.
4. **Phase 4:** Update example app, README, ARCHITECTURE.md.
5. **Phase 5:** Integration test demonstrating `anchor.networkUtcMs` advances after `runBackgroundSync()` (the unit-of-work boundary; full WM/BGTask end-to-end validation is documented as a manual on-device step).
