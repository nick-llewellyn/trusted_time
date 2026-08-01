import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/vantage_baseline.dart';

/// Folds [cycles] identical observations of [rttMs] into [start].
VantageBaseline settle(
  VantageBaseline start,
  int rttMs, {
  int cycles = 6,
  int responders = 5,
}) {
  var b = start;
  for (var i = 0; i < cycles; i++) {
    b = b.observe(List.filled(responders, rttMs));
  }
  return b;
}

void main() {
  group('observability gate', () {
    test('a cycle below the responder floor is not evidence', () {
      // Two survivors of a partial outage measure whichever hosts
      // happened to answer, not the vantage.
      const fresh = VantageBaseline();
      expect(fresh.observe([20, 22]), fresh);
      expect(fresh.observe(const <int>[]), fresh);
    });

    test('negative round trips are discarded before the floor applies', () {
      // A negative delay is not a fast host; dropping it can take the
      // cycle below the floor, which is the correct outcome.
      const fresh = VantageBaseline();
      expect(fresh.observe([-1, -1, 20]), fresh);
    });

    test('the first observable cycle seeds the baseline at its median', () {
      final b = const VantageBaseline().observe([10, 20, 30, 500, 500]);
      // Median, not mean: two badly-routed hosts do not move it.
      expect(b.ewmaRttMs, 30);
      expect(b.observationCount, 1);
      expect(b.epoch, 0);
    });

    test('an even sample count averages the middle pair', () {
      final b = const VantageBaseline().observe([10, 20, 30, 40]);
      expect(b.ewmaRttMs, 25);
    });
  });

  group('warmup', () {
    test('a cold baseline cannot report a shift', () {
      // One observation is a baseline of itself. Without the warmup
      // gate the second cycle would compare against an unsmoothed
      // single sample and fire on ordinary variance.
      var b = const VantageBaseline().observe([20, 20, 20]);
      expect(b.isWarm, isFalse);
      b = b.observe([400, 400, 400]);
      b = b.observe([400, 400, 400]);
      expect(b.epoch, 0, reason: 'shift suppressed until warm');
    });

    test('warmth is reached after the third observation', () {
      var b = const VantageBaseline();
      for (var i = 0; i < 3; i++) {
        b = b.observe([20, 20, 20]);
      }
      expect(b.isWarm, isTrue);
    });
  });

  group('shift detection', () {
    test('a sustained latency jump opens a new epoch', () {
      final home = settle(const VantageBaseline(), 25);
      expect(home.epoch, 0);

      // First out-of-band cycle debounces rather than firing.
      final pending = home.observe([180, 180, 180, 180]);
      expect(pending.epoch, 0);
      expect(pending.pendingShiftCount, 1);
      expect(
        pending.ewmaRttMs,
        home.ewmaRttMs,
        reason:
            'a suspected shift must not drag the baseline it is '
            'being measured against',
      );

      final moved = pending.observe([180, 180, 180, 180]);
      expect(moved.epoch, 1);
      expect(
        moved.ewmaRttMs,
        180,
        reason:
            'epoch boundary replaces, not '
            'smooths',
      );
      expect(moved.observationCount, 1, reason: 'warmup restarts');
      expect(moved.pendingShiftCount, 0);
    });

    test('a single congested cycle is weather, not a move', () {
      final home = settle(const VantageBaseline(), 25);
      final spike = home.observe([180, 180, 180, 180]);
      expect(spike.pendingShiftCount, 1);

      final recovered = spike.observe([26, 26, 26, 26]);
      expect(recovered.epoch, 0);
      expect(recovered.pendingShiftCount, 0, reason: 'debounce resets');
      expect(recovered.ewmaRttMs, closeTo(25.2, 0.5));
    });

    test('an unobservable cycle neither advances nor resets the debounce', () {
      // Consecutiveness is counted over observations, not over cycles.
      // A partial outage is silence, and silence is not evidence
      // against a move — it is frequently the move itself, since the
      // handover that changed the vantage is what suppressed the
      // quorum.
      final home = settle(const VantageBaseline(), 25);
      final pending = home.observe([180, 180, 180, 180]);
      expect(pending.pendingShiftCount, 1);

      final gap = pending.observe([180, 180]);
      expect(gap, pending, reason: 'an unobservable cycle changes nothing');

      final moved = gap.observe([180, 180, 180, 180]);
      expect(moved.epoch, 1, reason: 'the gap did not break the run');
    });

    test('an in-band cycle across a gap still breaks the run', () {
      // The reset is the in-band observation's job, and it keeps doing
      // it regardless of what unobservable cycles sit either side.
      final home = settle(const VantageBaseline(), 25);
      var b = home.observe([180, 180, 180, 180]);
      b = b.observe([180, 180]);
      b = b.observe([26, 26, 26, 26]);
      expect(b.pendingShiftCount, 0);

      b = b.observe([180, 180, 180, 180]);
      expect(b.epoch, 0, reason: 'the run restarted at one');
      expect(b.pendingShiftCount, 1);
    });

    test('a move toward the network fires on the same evidence', () {
      // Symmetric by construction: leaving a high-latency vantage
      // invalidates the rankings exactly as much as entering one.
      final far = settle(const VantageBaseline(), 200);
      final near = settle(far, 20, cycles: 2);
      expect(near.epoch, 1);
      expect(near.ewmaRttMs, 20);
    });

    test('ordinary drift never fires, however far it accumulates', () {
      // The baseline follows a slow walk, so a vantage that degrades
      // gradually is tracked rather than treated as a move.
      var b = settle(const VantageBaseline(), 25);
      for (var rtt = 25; rtt <= 200; rtt += 5) {
        b = b.observe(List.filled(4, rtt));
      }
      expect(b.epoch, 0);
      expect(b.ewmaRttMs, greaterThan(150));
    });

    test('the absolute floor suppresses ratio shifts at the fast end', () {
      // 10ms -> 25ms clears the 1.8x ratio and is unremarkable.
      final b = settle(const VantageBaseline(), 10);
      final after = settle(b, 25, cycles: 2);
      expect(after.epoch, 0);
    });

    test('the ratio suppresses absolute shifts at the slow end', () {
      // 300ms -> 345ms clears the 40ms floor but is a 1.15x change.
      final b = settle(const VantageBaseline(), 300);
      final after = settle(b, 345, cycles: 2);
      expect(after.epoch, 0);
    });

    test('epochs accumulate across successive moves', () {
      var b = settle(const VantageBaseline(), 25);
      b = settle(b, 200, cycles: 2);
      expect(b.epoch, 1);
      b = settle(b, 25, cycles: 5);
      expect(b.epoch, 2);
    });
  });

  group('serialization', () {
    test('a mid-debounce baseline survives a round trip intact', () {
      // The pending count has to persist or a process restart would
      // silently reset the debounce, and a device that moved while
      // backgrounded would need to re-earn a run it had already half
      // completed.
      final source = settle(
        const VantageBaseline(),
        25,
      ).observe([180, 180, 180, 180]);
      expect(source.pendingShiftCount, 1);

      final restored = VantageBaseline.fromJson(
        jsonDecode(jsonEncode(source.toJson())),
      );
      expect(restored, source);
    });

    test('a null baseline round trips as null rather than zero', () {
      // Omitted, not encoded as 0.0 — a zero baseline would read as a
      // warm vantage at 0 ms and make the first real cycle a shift.
      const fresh = VantageBaseline();
      expect(fresh.toJson().containsKey('ewmaRttMs'), isFalse);

      final restored = VantageBaseline.fromJson(
        jsonDecode(jsonEncode(fresh.toJson())),
      );
      expect(restored, fresh);
      expect(restored?.ewmaRttMs, isNull);
    });

    test('a malformed payload degrades to no baseline', () {
      // Null rather than a partially-populated record: losing the
      // warmup costs three cycles, whereas seeding the detector with a
      // salvaged number makes every subsequent cycle look like a
      // shift.
      expect(VantageBaseline.fromJson(null), isNull);
      expect(VantageBaseline.fromJson('nonsense'), isNull);
      expect(VantageBaseline.fromJson(const <String, dynamic>{}), isNull);
    });

    test('an out-of-range field rejects the whole record', () {
      Map<String, dynamic> payload({
        Object? rtt = 25.0,
        Object? observations = 4,
        Object? pending = 0,
        Object? epoch = 1,
      }) => {
        'ewmaRttMs': rtt,
        'observationCount': observations,
        'pendingShiftCount': pending,
        'epoch': epoch,
      };

      expect(VantageBaseline.fromJson(payload()), isNotNull);
      expect(VantageBaseline.fromJson(payload(rtt: -1)), isNull);
      expect(VantageBaseline.fromJson(payload(rtt: 'fast')), isNull);
      expect(VantageBaseline.fromJson(payload(observations: -1)), isNull);
      expect(VantageBaseline.fromJson(payload(observations: 1.5)), isNull);
      expect(VantageBaseline.fromJson(payload(pending: -1)), isNull);
      expect(VantageBaseline.fromJson(payload(epoch: -1)), isNull);
      expect(VantageBaseline.fromJson(payload(epoch: null)), isNull);
    });

    test('a non-finite round trip time rejects the record', () {
      // NaN is the one seed that never heals. Every comparison against
      // it is false, so it can neither register a shift nor open the
      // epoch that would replace it, and the EWMA carries it forward
      // untouched — a detector that is silently dead forever.
      expect(
        VantageBaseline.fromJson(const <String, dynamic>{
          'ewmaRttMs': double.nan,
          'observationCount': 4,
          'pendingShiftCount': 0,
          'epoch': 1,
        }),
        isNull,
      );
      expect(
        VantageBaseline.fromJson(const <String, dynamic>{
          'ewmaRttMs': double.infinity,
          'observationCount': 4,
          'pendingShiftCount': 0,
          'epoch': 1,
        }),
        isNull,
      );
    });

    test('the constructor rejects the same values fromJson does', () {
      // fromJson returns null on a bad payload because untrusted input
      // is an expected condition. In code the same value is a mistake,
      // so it asserts instead — but the boundary must agree, or the
      // debug build permits a state the persistence layer refuses.
      expect(() => VantageBaseline(ewmaRttMs: double.nan), throwsA(anything));
      expect(
        () => VantageBaseline(ewmaRttMs: double.infinity),
        throwsA(anything),
      );
      expect(() => VantageBaseline(ewmaRttMs: -1), throwsA(anything));
      expect(() => const VantageBaseline(ewmaRttMs: 25), returnsNormally);
      expect(() => const VantageBaseline(), returnsNormally);
    });

    test('a baseline no observation could produce is restored anyway', () {
      // Cross-field consistency is deliberately not enforced. Each of
      // these is unreachable through observe, and each is also erased
      // by the very next observation — while rejecting the record
      // would throw away an epoch that is still perfectly good.
      const noRttButCounted = VantageBaseline(
        observationCount: 4,
        pendingShiftCount: 1,
        epoch: 2,
      );
      final restored = VantageBaseline.fromJson(noRttButCounted.toJson());
      expect(restored, noRttButCounted);

      // The null EWMA branch of observe ignores both counts outright.
      final settled = restored!.observe([25, 25, 25, 25]);
      expect(settled.ewmaRttMs, 25.0);
      expect(settled.observationCount, 1);
      expect(settled.pendingShiftCount, 0);
      expect(settled.epoch, 2, reason: 'the epoch is what survives');
    });

    test('an over-large pending count fires once and then clears', () {
      // pendingShiftCount past the debounce is unreachable through
      // observe, but it costs at most one early epoch: the shift path
      // replaces the record wholesale, and an in-band cycle clears it
      // without firing at all.
      const overrun = VantageBaseline(
        ewmaRttMs: 25,
        observationCount: 4,
        pendingShiftCount: 9,
        epoch: 0,
      );
      final inBand = overrun.observe([25, 25, 25, 25]);
      expect(inBand.pendingShiftCount, 0);
      expect(inBand.epoch, 0, reason: 'an in-band cycle just clears it');

      final outOfBand = overrun.observe([180, 180, 180, 180]);
      expect(outOfBand.epoch, 1);
      expect(outOfBand.pendingShiftCount, 0, reason: 'the epoch resets it');
    });

    test('an integral round trip time decodes as a double', () {
      // jsonEncode collapses 25.0 to `25`, so the decode has to widen
      // it back or an equality check against the pre-save value fails.
      final restored = VantageBaseline.fromJson(
        jsonDecode(
          '{"ewmaRttMs":25,"observationCount":4,'
          '"pendingShiftCount":0,"epoch":1}',
        ),
      );
      expect(restored?.ewmaRttMs, 25.0);
    });
  });

  group('value semantics', () {
    const base = VantageBaseline(
      ewmaRttMs: 25,
      observationCount: 4,
      pendingShiftCount: 1,
      epoch: 2,
    );

    test('equality covers every field', () {
      expect(
        base,
        const VantageBaseline(
          ewmaRttMs: 25,
          observationCount: 4,
          pendingShiftCount: 1,
          epoch: 2,
        ),
      );
      expect(
        base.hashCode,
        const VantageBaseline(
          ewmaRttMs: 25,
          observationCount: 4,
          pendingShiftCount: 1,
          epoch: 2,
        ).hashCode,
      );

      expect(
        base,
        isNot(
          const VantageBaseline(
            observationCount: 4,
            pendingShiftCount: 1,
            epoch: 2,
          ),
        ),
      );
      expect(
        base,
        isNot(
          const VantageBaseline(
            ewmaRttMs: 25,
            observationCount: 5,
            pendingShiftCount: 1,
            epoch: 2,
          ),
        ),
      );
      expect(
        base,
        isNot(
          const VantageBaseline(ewmaRttMs: 25, observationCount: 4, epoch: 2),
        ),
      );
      expect(
        base,
        isNot(
          const VantageBaseline(
            ewmaRttMs: 25,
            observationCount: 4,
            pendingShiftCount: 1,
          ),
        ),
      );
      expect(base, isNot('not a baseline'));
    });

    test('toString names the epoch and the pending run', () {
      // Diagnostic only, but these two fields are what a log reader
      // needs to tell a settled vantage from one mid-debounce.
      expect(base.toString(), contains('epoch: 2'));
      expect(base.toString(), contains('pending: 1'));
    });
  });
}
