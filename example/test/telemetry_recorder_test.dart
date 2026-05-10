import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time_example/sync_telemetry.dart';

/// Regression tests for `TelemetryRecorder` event fan-out.
///
/// Closes bead `trusted_time-dmc`: an event listener that synchronously
/// invokes its own disposer must not throw `ConcurrentModificationError`,
/// and other listeners registered in the same fan-out cycle must still
/// receive the event from the snapshot the recorder iterates over.
void main() {
  group('TelemetryRecorder._add fan-out', () {
    test(
      'self-disposing listener does not crash and peers still receive event',
      () {
        final recorder = TelemetryRecorder();
        addTearDown(recorder.dispose);

        final aReceived = <TelemetryEvent>[];
        final bReceived = <TelemetryEvent>[];
        final cReceived = <TelemetryEvent>[];

        recorder.addEventListener(aReceived.add);

        // B disposes itself the first time it fires. With the snapshot
        // fix in place, the iteration walks a copy so removing the
        // entry from `_listeners` mid-fanout neither throws nor skips
        // the listener registered after it.
        late final void Function() disposeB;
        disposeB = recorder.addEventListener((event) {
          bReceived.add(event);
          disposeB();
        });

        recorder.addEventListener(cReceived.add);

        // Drive `_add` via the public SyncObserver surface; any kind
        // would do, syncStarted is the cheapest.
        expect(recorder.onSyncStarted, returnsNormally);

        expect(aReceived, hasLength(1));
        expect(bReceived, hasLength(1));
        expect(cReceived, hasLength(1));

        // Second cycle: B must be gone, A and C must still fire. This
        // also confirms the disposer actually mutated `_listeners`
        // rather than just acting on a stale reference.
        recorder.onSyncStarted();

        expect(aReceived, hasLength(2));
        expect(bReceived, hasLength(1));
        expect(cReceived, hasLength(2));
      },
    );

    test(
      'manual disposer call from outside the callback still removes the listener',
      () {
        final recorder = TelemetryRecorder();
        addTearDown(recorder.dispose);

        final received = <TelemetryEvent>[];
        final dispose = recorder.addEventListener(received.add);

        recorder.onSyncStarted();
        expect(received, hasLength(1));

        dispose();
        recorder.onSyncStarted();
        expect(received, hasLength(1));
      },
    );
  });
}
