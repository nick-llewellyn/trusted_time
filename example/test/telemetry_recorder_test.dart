import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart';
import 'package:trusted_time/trusted_time.dart';
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

  /// Closes bead `trusted_time-zy9`: when a source throws
  /// `TransientSourceError`, the engine retries on the next cycle
  /// without exponential cooldown for that specific event. The
  /// telemetry row must surface this per-event classification with a
  /// `[transient, no cooldown]` tag, and the underlying cause must
  /// still receive the same per-phase formatting as a raw failure.
  /// (The streak guard at `TrustedTimeConfig.transientStreakThreshold`
  /// can still escalate sustained transient failures onto the regular
  /// cooldown ladder; the tag describes the classification of the
  /// individual failure event being rendered, not a permanent
  /// no-cooldown guarantee for the source.)
  group('TelemetryRecorder.onSourceFailed', () {
    test('plain non-transient error formats as "<sourceId>: <error>"', () {
      final recorder = TelemetryRecorder();
      addTearDown(recorder.dispose);

      recorder.onSourceFailed('https-google', 'connection refused');

      final detail = recorder.events.last.detail;
      expect(detail, 'https-google: connection refused');
      expect(detail, isNot(contains('[transient')));
    });

    test(
      'raw NtsErrorTimeout surfaces the per-phase tag without transient prefix',
      () {
        final recorder = TelemetryRecorder();
        addTearDown(recorder.dispose);

        recorder.onSourceFailed(
          'nts-cloudflare',
          NtsError.timeout(phase: TimeoutPhase.dnsTimeout),
        );

        final detail = recorder.events.last.detail;
        expect(detail, 'nts-cloudflare: timeout during dnsTimeout');
        expect(detail, isNot(contains('[transient')));
      },
    );

    test('TransientSourceError wrapping NtsErrorTimeout surfaces both '
        'the transient tag and the per-phase tag', () {
      final recorder = TelemetryRecorder();
      addTearDown(recorder.dispose);

      recorder.onSourceFailed(
        'nts-cloudflare',
        TransientSourceError(
          NtsError.timeout(phase: TimeoutPhase.dnsSaturation),
        ),
      );

      final detail = recorder.events.last.detail;
      expect(
        detail,
        'nts-cloudflare [transient, no cooldown]: '
        'timeout during dnsSaturation',
      );
    });

    test('TransientSourceError wrapping a non-NTS cause surfaces the '
        'transient tag and unwraps the cause', () {
      final recorder = TelemetryRecorder();
      addTearDown(recorder.dispose);

      recorder.onSourceFailed(
        'http-time',
        const TransientSourceError('socket exhausted'),
      );

      final detail = recorder.events.last.detail;
      expect(detail, 'http-time [transient, no cooldown]: socket exhausted');
    });
  });

  group('TelemetryRecorder.reset preserves elapsed-time origin', () {
    test('event recorded after reset has elapsedMs greater than event '
        'recorded before reset (trusted_time-0hc)', () async {
      // Regression: reset() previously called `_start..reset()..start()`
      // along with clearing the event buffer. Calling Clear in the
      // UI mid-sync-cycle would rewind the elapsed-time origin, so
      // the remaining callbacks for the in-flight cycle (sample,
      // sourceFailed, consensus, metrics) would record `elapsedMs`
      // values starting near zero even though chronologically they
      // were many hundreds of milliseconds into a cycle that began
      // before the reset. The on-screen terminal would surface the
      // rewound ordering and BenchmarkLogger would persist it to
      // disk.
      final recorder = TelemetryRecorder();
      addTearDown(recorder.dispose);

      recorder.onSyncStarted();
      final beforeReset = recorder.events.last.elapsedMs;

      // Sleep long enough for the elapsed-time origin difference to
      // be observable above scheduler jitter on slow CI.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      recorder.reset();

      recorder.onSyncStarted();
      final afterReset = recorder.events.last.elapsedMs;

      expect(
        afterReset,
        greaterThan(beforeReset),
        reason:
            'reset() must preserve the elapsed-time origin; '
            'resetting it mid-cycle would misorder events from any '
            'in-flight sync cycle in the persisted session log.',
      );
    });
  });
}
