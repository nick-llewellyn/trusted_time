# On-device harness: forcing and observing background sync fires

Practical runbook for exercising the headless background anchor refresh
(ADR 0002) on a real Android device and reading back what happened. Written
for future AI/agent sessions as much as for humans — every command below has
been verified on the reference device.

## Reference device

- Pixel Tablet, serial `3704105H809EVQ`, Android 16 (API 36).
- Substitute your own serial in the `adb -s` flags below
  (`adb devices` to list).

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

Read it back (works even with no process alive):

```bash
adb -s <serial> shell run-as com.example.trusted_time_example \
  tail -30 app_flutter/logs/nts_bg_syncs.log
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

## Known limitations

- **Debug builds only** for `FIRE DEBUG` lines: both the library's
  diagnostics and the tee are `kDebugMode`-gated. Release builds still
  write `BEGIN`/`STOPINFO`/`SUCCESS`/`FAILURE` lines.
- **Organic periodic dispatch is unreliable on the reference tablet** —
  the device appears to suppress unattended periodic WorkManager runs
  (tracked as `trusted_time-g36`). Forced fires are the dependable way
  to exercise the path.
- `run-as` requires a debuggable build; on release builds the transcript
  is only reachable via the app's own UI (`readLatest`) or backup
  extraction.
