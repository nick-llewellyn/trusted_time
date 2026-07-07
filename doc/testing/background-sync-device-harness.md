# On-device harness: forcing and observing background sync fires

Practical runbook for exercising the headless background anchor refresh
(ADR 0002) on real Android and iOS devices and reading back what happened.
Written for future AI/agent sessions as much as for humans — every command
below has been verified on the reference devices.

## Reference devices

- Android tablet (Pixel Tablet class), Android 16 (API 36).
  Substitute your own serial for `<serial>` in the `adb -s` flags below
  (`adb devices` to list).
- iPad, iOS 17.5. Substitute your own identifier for `<identifier>` in
  the `devicectl --device` flags below
  (`xcrun devicectl list devices`).

## Build-time switches

Both switches are `--dart-define`s read via `fromEnvironment` in the
example app, so they are compile-time constants (tree-shaken when unset):

| Define | Default | Effect |
|---|---|---|
| `BG_SYNC_MINUTES=<n>` | unset (0) | Auto-schedules the periodic background sync at startup with an `n`-minute interval, bypassing the Section 5 switch. Android floors this to WorkManager's 15-minute minimum. Unset keeps the normal switch-driven 24 h flow. |
| `BG_SYNC_LOG=true` | unset (false) | Enables the FIRE transcript in **release** builds. Debug builds always log. An ordinary release build compiles the writer out entirely (`BackgroundSyncFileLog.enabled` is `const`), and the Section 5b panel shows a "logging is disabled in this build" empty state instead of the misleading "no fires yet". |

Typical test install (either platform):

```bash
cd example
flutter run -d <device> --release \
  --dart-define=BG_SYNC_LOG=true --dart-define=BG_SYNC_MINUTES=60
```

Use `--release` for anything soak-shaped: on iOS a debug build's Dart VM
service keeps the process in a state the scheduler treats differently,
and on both platforms release is what production consumers actually run.
Transcript readback is deliberately **ungated** — a disabled build can
still display (and clear) a transcript left behind by an earlier
opted-in install, since the documents directory survives reinstalls of
the same bundle ID.

## The FIRE transcript (source of truth)

Background fires run in a headless isolate that the OS tears down
immediately afterward; logcat is ring-buffered and lost across reboots.
The example app therefore keeps a durable append-only transcript:

```
<app documents dir>/logs/nts_bg_syncs.log
(on device: /data/data/com.example.trusted_time_example/app_flutter/logs/nts_bg_syncs.log)
```

Every fire appends lines prefixed `FIRE` (see
`example/lib/background_sync_file_log.dart` and
`_runAndLogBackgroundSync` in `example/lib/main.dart`):

```
FIRE      BEGIN
FIRE      STOPINFO state=RUNNING prevStopReason=NOT_STOPPED(-256)
FIRE      DEBUG    [TrustedTime] nts:time.cloudflare.com burst 4/4 succeeded rtts=[41.7, ...]ms receipts=[+0, +3, +3, +18]ms
FIRE      DEBUG    [TrustedTime] consensus receiptSpread=95ms (4/4 stamped)
FIRE      SUCCESS  elapsed=1125ms utc=2026-07-05T19:35:59.750Z auth=verified confidence=high ±28ms
```

`FIRE DEBUG` lines are the library's internal `[TrustedTime]` diagnostics,
tee'd from `debugPrint` into the transcript (debug builds only). The tee
queues writes onto a sequential `Future` chain that is drained before the
isolate signals completion to the native side, so lines cannot be lost to
isolate teardown and always precede the `SUCCESS`/`FAILURE` line.

Read it back on Android (works even with no process alive):

```bash
adb -s <serial> shell run-as com.example.trusted_time_example \
  tail -30 app_flutter/logs/nts_bg_syncs.log
```

On iOS, pull the file over the pairing channel (no debugger needed;
works for release builds because the app is dev-signed):

```bash
xcrun devicectl device copy from \
  --device <identifier> \
  --source Documents/logs/nts_bg_syncs.log \
  --destination /tmp/ipad_bg.log \
  --domain-type appDataContainer \
  --domain-identifier com.example.trustedTimeExample
```

## Build, install, register the job

```bash
cd example
flutter build apk --debug
adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
```

Launch the app once so `enableBackgroundSync` runs and WorkManager
registers the periodic job:

```bash
adb -s <serial> shell am start -n com.example.trusted_time_example/.MainActivity
sleep 15   # give init + enableBackgroundSync time to complete
```

**Gotcha:** if a previous install left WorkManager's DB in a bad state
(job shows `FAILED` in diagnostics, nothing registered in jobscheduler),
`pm clear` and relaunch:

```bash
adb -s <serial> shell pm clear com.example.trusted_time_example
```

## Forcing a fire (Android 16 namespace gotcha)

On API 36, WorkManager registers its jobs under the JobScheduler namespace
`androidx.work.systemjobscheduler`. The plain form fails:

```bash
# FAILS on Android 16: "Could not find job N in package ..."
adb shell cmd jobscheduler run -f com.example.trusted_time_example <id>
```

Find the job ID, then run with `-n`:

```bash
adb -s <serial> shell dumpsys jobscheduler | grep "u0a.*BackgroundSyncWorker"
# -> JOB androidx.work.systemjobscheduler:u0aNNN/<id>: ... BackgroundSyncWorker ...

adb -s <serial> shell cmd jobscheduler run -f \
  -n androidx.work.systemjobscheduler com.example.trusted_time_example <id>
# -> "Running job [FORCED]"
```

For a genuine cold-process test, kill the process first (the `am kill`
only works once the app is backgrounded):

```bash
adb -s <serial> shell input keyevent KEYCODE_HOME
sleep 2
adb -s <serial> shell am kill com.example.trusted_time_example
adb -s <serial> shell "pidof com.example.trusted_time_example || echo NO_PROCESS"
```

Then force the fire, wait ~30–40 s, and read the transcript tail.

## Checking WorkManager's own view

WorkManager's diagnostics broadcast dumps work state to logcat (needs a
live process — launch the app first):

```bash
PID=$(adb -s <serial> shell pidof com.example.trusted_time_example | tr -d '\r')
adb -s <serial> shell am broadcast \
  -a "androidx.work.diagnostics.REQUEST_DIAGNOSTICS" \
  -p com.example.trusted_time_example
sleep 3
adb -s <serial> logcat -d --pid=$PID | grep WM-DiagnosticsWrkr | grep BackgroundSyncWorker
```

Healthy output shows the worker as `ENQUEUED` with unique name
`trusted_time_sync`.

## Live diagnostics via logcat

On debug builds the `[TrustedTime]` lines also stream to logcat, useful
while iterating with the process alive:

```bash
adb -s <serial> logcat -d --pid=$PID | grep -E "flutter.*TrustedTime"
```

But treat the transcript as authoritative for anything that fired from a
dead process.

## iOS: forcing a BGAppRefresh fire via lldb

There is no `devicectl` equivalent of `cmd jobscheduler run`; the only
way to force a `BGTaskScheduler` fire on a physical device is Apple's
private debugger hook, `_simulateLaunchForTaskWithIdentifier:`, evaluated
from lldb while attached to the running app. Verified working recipe
(release build, dev-signed):

```bash
PID=$(xcrun devicectl device info processes \
  --device <identifier> 2>/dev/null | grep "Runner.app/Runner" | tail -1 | awk '{print $1}')

cat > /tmp/bgtask_simulate.lldb <<EOF
device select <identifier>
device process attach --pid $PID
script import time; time.sleep(6)
script lldb.debugger.HandleCommand("process interrupt")
script import time; time.sleep(3)
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.trustedtime.backgroundsync"]
continue
script import time; time.sleep(30)
script lldb.debugger.HandleCommand("process interrupt")
script import time; time.sleep(2)
detach
quit
EOF
lldb -s /tmp/bgtask_simulate.lldb
```

Gotchas learned the hard way:

- **Settle, then interrupt, then evaluate.** Attaching over the wireless
  pairing channel needs a few seconds to stabilise; evaluating the hook
  while the process is running yields "unable to evaluate expression".
  The `sleep(6)` + explicit `process interrupt` before the `e` command
  is what makes it reliable.
- **The task identifier** is `com.trustedtime.backgroundsync`
  (`BGTaskSchedulerPermittedIdentifiers` in `example/ios/Runner/Info.plist`).
- **The app must be backgrounded** (home screen) — BGAppRefresh does not
  dispatch while the app is foreground.
- After `detach`, kill any stray lldb (`pkill -f "usr/bin/lldb"`) and
  confirm the app survived via `devicectl device info processes`.
- Pull the transcript afterwards with the `devicectl device copy from`
  command above; expect a `FIRE BEGIN` / `FIRE SUCCESS` pair.

## Soak findings (overnight, 2026-07-05 → 06, 15-min cadence)

Release builds with `BG_SYNC_LOG=true BG_SYNC_MINUTES=15`, both devices
backgrounded, displays off, on Wi-Fi and charger.

| | Android tablet (Android 16) | iPad (iOS 17.5) |
|---|---|---|
| Natural OS-scheduled fires | **10/10 success** | 0 while parked; 1 executed at next app launch |
| Simulated/forced fires | verified | 1/1 success via lldb hook |
| Auth level | all `verified` | all `verified` |
| Confidence | `high` (one `medium` ±62 ms) | `high`, ±25–38 ms |
| Typical elapsed | 0.9–5.3 s | 1.4–1.5 s |

Interpretation:

- **Android is dependable.** WorkManager honoured the periodic schedule
  all night with the screen off. Inter-fire gaps were mostly 15–18 min,
  with two longer Doze-batched gaps (~40 min and ~5.5 h in the deepest
  idle window) — deferral, not loss: every dispatched fire succeeded.
- **iOS is opportunistic.** The OS jetsam'd the resident process during
  the night and never woke it for BGAppRefresh; the pending task instead
  executed on the next app launch. That is expected DAS (Duet Activity
  Scheduler) behaviour for a dev-signed, low-engagement app, not a
  defect. Consumers should treat iOS background sync as best-effort and
  rely on the on-launch sync for freshness guarantees (ADR 0002).
- The headless path itself — engine spin-up, burst, consensus, anchor
  persist, transcript append — is **fully verified end-to-end on both
  platforms**.

## Known limitations

- **Debug builds only** for `FIRE DEBUG` lines: both the library's
  diagnostics and the tee are `kDebugMode`-gated. Release builds still
  write `BEGIN`/`STOPINFO`/`SUCCESS`/`FAILURE` lines (when `BG_SYNC_LOG`
  is set — an ordinary release build writes nothing at all).
- **Organic periodic dispatch was initially thought unreliable on the
  reference tablet** (tracked as `trusted_time-g36`); the overnight soak
  above showed 10/10 natural fires from a release build, so the earlier
  suppression was likely an artefact of the debug-build/tethered setup.
  Forced fires remain the fast way to exercise the path on demand.
- **iOS natural dispatch cannot be relied on** for a dev-signed,
  low-engagement app — see the soak findings. The lldb simulation hook
  is the dependable way to exercise the iOS path.
- `run-as` requires a debuggable build; on release builds the Android
  transcript is only reachable via the app's own UI (`readLatest`).
  On iOS, `devicectl device copy from` works for dev-signed release
  builds regardless.
