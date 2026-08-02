import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/sync_engine.dart';

import 'support/fake_clocks.dart';
import 'support/fake_sources.dart';

/// Fake NTS-prefixed source scripting the cold-start clock-skew
/// deadlock: a [getTime] call made *without* a rescue verification
/// instant armed on the [engine] fails with a certificate
/// validity-window error, while a call made while the instant is
/// armed succeeds (unless [healAfterRescue] is false — modelling a
/// server whose certificate is genuinely broken).
///
/// The fake mirrors a real [NtsSource]'s wiring by reading the
/// engine's rescue state at each call via
/// [SyncEngine.debugRescueVerificationTime], recording what would
/// have been forwarded to `package:nts` in
/// [observedVerificationTimes]. The [engine] reference is set by the
/// test after construction (the engine needs the source list at
/// construction time, so the reference is circular by necessity).
class RescuableNtsSource implements TimeSource {
  RescuableNtsSource(
    this.id, {
    required this.utcMs,
    this.error = const nts.NtsErrorKeProtocol(
      message: 'invalid peer certificate: Expired',
    ),
    this.healAfterRescue = true,
    this.succeedFirstCall = false,
  });

  @override
  final String id;

  @override
  String get groupId => 'g-nts';

  /// Midpoint reported when the source succeeds.
  final int utcMs;

  /// Error thrown while the deadlock holds.
  final Object error;

  /// Whether an armed rescue instant heals the source.
  final bool healAfterRescue;

  /// Whether the very first call succeeds unconditionally (used to
  /// anchor an engine before scripting failures).
  final bool succeedFirstCall;

  /// Engine whose rescue state this fake consults.
  SyncEngine? engine;

  var _calls = 0;

  /// Verification instants observed at each [getTime] call (null when
  /// no rescue was armed).
  final observedVerificationTimes = <DateTime?>[];

  @override
  Future<TimeSample> getTime() async {
    _calls++;
    final armed = engine?.debugRescueVerificationTime;
    observedVerificationTimes.add(armed);
    final healed = armed != null && healAfterRescue;
    final firstFreebie = succeedFirstCall && _calls == 1;
    if (!healed && !firstFreebie) {
      throw error;
    }
    return TimeSample(
      interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
      sourceId: id,
      groupId: groupId,
    );
  }
}

void main() {
  group('SyncEngine fail-closed trust resolution', () {
    late FakeMonotonicClock clock;

    setUp(() {
      clock = FakeMonotonicClock();
    });

    test(
      'invalid trust config fails closed even when ntsServers is empty',
      () async {
        // Regression: effectiveTrustMode used to be resolved only inside
        // the ntsServers comprehension, so an invalid config
        // (usePlatformTrust: true + non-empty customRootCerts) with an
        // empty ntsServers list skipped the ArgumentError entirely and
        // still built NTP/additional sources — bypassing the
        // "fail closed before any source is built" guarantee asserted in
        // the Secure Time Contract. The resolver is now read once up
        // front in _buildSources, so source construction fails closed
        // regardless of whether any NTS server is configured.
        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            disableNtpForTesting: true,
            disableNts: true,
            usePlatformTrust: true,
            customRootCerts: [1, 2, 3],
          ),
          clock: clock,
        );

        // _sources is late-built on first access; warmAllSources is the
        // public trigger that reaches it, surfacing the ArgumentError on
        // the returned Future.
        await expectLater(engine.warmAllSources(), throwsArgumentError);
      },
    );

    test(
      'valid config with empty ntsServers builds without over-rejecting',
      () async {
        // Positive control: the up-front resolution must not reject a
        // valid config. bundledOnly (the effective default) is valid, so
        // source construction succeeds even with no NTS servers present.
        final engine = SyncEngine(
          config: const TrustedTimeConfig(
            disableNtpForTesting: true,
            disableNts: true,
          ),
          clock: clock,
        );

        await expectLater(engine.warmAllSources(), completes);
      },
    );
  });

  group('SyncEngine.isCertValidityFailure classification', () {
    // Strong signal: rustls diagnostics naming the validity window.
    const positives = <Object>[
      nts.NtsErrorKeProtocol(message: 'invalid peer certificate: Expired'),
      nts.NtsErrorKeProtocol(message: 'invalid peer certificate: NotValidYet'),
      nts.NtsErrorKeProtocol(message: 'certificate not valid yet'),
      // Weak signal: TLS-phase timeout (middlebox killed the handshake).
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.tls),
    ];
    for (final e in positives) {
      test('accepts $e', () {
        expect(SyncEngine.isCertValidityFailure(e), isTrue);
      });
    }

    const negatives = <Object>[
      nts.NtsErrorKeProtocol(message: 'unexpected KE record type 42'),
      // Shares rustls's generic `invalid peer certificate` prefix but
      // is not a validity-window problem: must not arm the rescue.
      nts.NtsErrorKeProtocol(
        message: 'invalid peer certificate: UnknownIssuer',
      ),
      nts.NtsErrorKeProtocol(message: 'invalid peer certificate: BadSignature'),
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.connect),
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.dnsTimeout),
      nts.NtsErrorTimeout(phase: nts.TimeoutPhase.ntp),
      nts.NtsErrorAuthentication(message: 'AEAD open failed'),
      FormatException('not an nts error at all'),
    ];
    for (final e in negatives) {
      test('rejects $e', () {
        expect(SyncEngine.isCertValidityFailure(e), isFalse);
      });
    }
  });

  group('SyncEngine pre-sync rescue orchestration', () {
    late FakeMonotonicClock clock;

    /// Coarse instant far above the plausibility floor.
    final plausibleCoarse = DateTime.utc(2026, 7, 20, 12);

    setUp(() {
      clock = FakeMonotonicClock();
    });

    SyncEngine buildEngine(List<TimeSource> sources, {int minimumQuorum = 1}) =>
        SyncEngine(
          config: TrustedTimeConfig(
            disableNtpForTesting: true,
            disableNts: true,
            minimumQuorum: minimumQuorum,
            minGroupCount: 1,
            additionalSources: sources,
            maxLatency: const Duration(milliseconds: 500),
          ),
          clock: clock,
        );

    TimeSample probeSample(DateTime instant) => TimeSample(
      interval: TimeInterval(
        startMs: instant.millisecondsSinceEpoch - 50,
        endMs: instant.millisecondsSinceEpoch + 50,
      ),
      sourceId: 'ntp:probe.example',
      groupId: 'probe',
    );

    test(
      'cold-start cert failure arms rescue, retry succeeds, state clears',
      () async {
        // Two sources: Marzullo consensus needs at least two samples.
        final a = RescuableNtsSource('nts:skewed-a.example', utcMs: 1000000);
        final b = RescuableNtsSource('nts:skewed-b.example', utcMs: 1000000);
        final engine = buildEngine([a, b]);
        a.engine = engine;
        b.engine = engine;
        engine.rescueProbeOverride = () async => probeSample(plausibleCoarse);

        final anchor = await engine.sync();

        expect(anchor.networkUtcMs, inInclusiveRange(999990, 1000010));
        // First attempt ran unarmed (null); the retry ran with the
        // coarse instant (the probe interval midpoint) pinned.
        for (final s in [a, b]) {
          expect(
            s.observedVerificationTimes.whereType<DateTime>().single,
            plausibleCoarse,
          );
        }
        // Rescue instant is cleared once the retry cycle settles.
        expect(engine.debugRescueVerificationTime, isNull);
        expect(engine.rescueAttempted, isTrue);
      },
    );

    test('rescue prefers NTP samples already collected this cycle', () async {
      final ntsSource = RescuableNtsSource(
        'nts:skewed.example',
        utcMs: plausibleCoarse.millisecondsSinceEpoch,
      );
      // An NTP-prefixed sibling that succeeds during the failing
      // cycle; its sample's midpoint is the expected coarse estimate.
      // Quorum 2 forces the first cycle to fail even though the
      // sibling produced a sample.
      final ntpSibling = RaceConditionSource(
        '${TimeSource.prefixNtp}sibling.example',
        const Duration(milliseconds: 5),
        plausibleCoarse.millisecondsSinceEpoch,
        'g-ntp',
      );
      final engine = buildEngine([ntsSource, ntpSibling], minimumQuorum: 2);
      ntsSource.engine = engine;
      var probeCalled = false;
      engine.rescueProbeOverride = () async {
        probeCalled = true;
        throw StateError('probe must not run when cycle samples exist');
      };

      final anchor = await engine.sync();
      expect(probeCalled, isFalse);
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>().single,
        plausibleCoarse,
      );
      expect(
        anchor.networkUtcMs,
        inInclusiveRange(
          plausibleCoarse.millisecondsSinceEpoch - 20,
          plausibleCoarse.millisecondsSinceEpoch + 20,
        ),
      );
    });

    test('rescue is one-shot: second cert failure does not re-arm', () async {
      final ntsSource = RescuableNtsSource(
        'nts:skewed.example',
        utcMs: 1000000,
        healAfterRescue: false,
      );
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      var probeCalls = 0;
      engine.rescueProbeOverride = () async {
        probeCalls++;
        return probeSample(plausibleCoarse);
      };

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(probeCalls, 1);
      expect(engine.rescueAttempted, isTrue);
      expect(engine.debugRescueVerificationTime, isNull);

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      // No second probe: the one-shot latch held.
      expect(probeCalls, 1);
    });

    test('no rescue without a coarse estimate (empty ntpServers, no '
        'cycle samples): original error propagates', () async {
      final ntsSource = RescuableNtsSource('nts:skewed.example', utcMs: 0);
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      // No probe override and no ntpServers: rescue unavailable.

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(engine.rescueAttempted, isTrue);
      // The NTS source only ever saw null verification times — the
      // rescue was never armed.
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>(),
        isEmpty,
      );
    });

    test('coarse estimate below the plausibility floor is rejected', () async {
      final ntsSource = RescuableNtsSource('nts:skewed.example', utcMs: 0);
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      final backdated = SyncEngine.rescueFloorUtc.subtract(
        const Duration(days: 365),
      );
      engine.rescueProbeOverride = () async => probeSample(backdated);

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>(),
        isEmpty,
      );
    });

    test('a backdated cycle sample is skipped, not allowed to poison '
        'the rescue while a plausible sibling exists', () async {
      // Two NTP siblings succeed during the failing cycle: a backdated
      // one (broken server / replayed old time) that completes first,
      // and a plausible one. The plausibility floor must act as a
      // per-candidate filter inside acquisition — skipping the poison
      // and arming from the plausible sibling — rather than a single
      // post-selection gate that would reject the whole rescue because
      // best-candidate selection happened to pick the poison.
      final backdatedMs = SyncEngine.rescueFloorUtc
          .subtract(const Duration(days: 365))
          .millisecondsSinceEpoch;
      final ntsSource = RescuableNtsSource(
        'nts:skewed.example',
        utcMs: plausibleCoarse.millisecondsSinceEpoch,
      );
      final poisonedSibling = RaceConditionSource(
        '${TimeSource.prefixNtp}poisoned.example',
        const Duration(milliseconds: 5),
        backdatedMs,
        'g-ntp-poison',
      );
      final plausibleSibling = RaceConditionSource(
        '${TimeSource.prefixNtp}plausible.example',
        const Duration(milliseconds: 10),
        plausibleCoarse.millisecondsSinceEpoch,
        'g-ntp-ok',
      );
      // The two NTP intervals are disjoint, so the first cycle cannot
      // reach quorum 2 without the (cert-failing) NTS source.
      final engine = buildEngine([
        ntsSource,
        poisonedSibling,
        plausibleSibling,
      ], minimumQuorum: 2);
      ntsSource.engine = engine;
      var probeCalled = false;
      engine.rescueProbeOverride = () async {
        probeCalled = true;
        throw StateError('probe must not run when cycle samples exist');
      };

      final anchor = await engine.sync();
      expect(probeCalled, isFalse);
      expect(
        ntsSource.observedVerificationTimes.whereType<DateTime>().single,
        plausibleCoarse,
      );
      expect(
        anchor.networkUtcMs,
        inInclusiveRange(
          plausibleCoarse.millisecondsSinceEpoch - 20,
          plausibleCoarse.millisecondsSinceEpoch + 20,
        ),
      );
    });

    test('no rescue once an anchor exists (warm engine)', () async {
      // Both succeed on the first cycle (anchoring the engine), then
      // fail every subsequent cycle with a cert-validity signature.
      final a = RescuableNtsSource(
        'nts:flaky-a.example',
        utcMs: 1000000,
        succeedFirstCall: true,
        healAfterRescue: false,
      );
      final b = RescuableNtsSource(
        'nts:flaky-b.example',
        utcMs: 1000000,
        succeedFirstCall: true,
        healAfterRescue: false,
      );
      final engine = buildEngine([a, b]);
      a.engine = engine;
      b.engine = engine;
      var probeCalls = 0;
      engine.rescueProbeOverride = () async {
        probeCalls++;
        throw StateError('unreachable');
      };

      await engine.sync();

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(probeCalls, 0);
      expect(engine.rescueAttempted, isFalse);
    });

    test('non-cert NTS failure does not trigger the rescue', () async {
      final ntsSource = RescuableNtsSource(
        'nts:down.example',
        utcMs: 0,
        error: const nts.NtsErrorTimeout(phase: nts.TimeoutPhase.connect),
        healAfterRescue: false,
      );
      final engine = buildEngine([ntsSource]);
      ntsSource.engine = engine;
      var probeCalls = 0;
      engine.rescueProbeOverride = () async {
        probeCalls++;
        throw StateError('unreachable');
      };

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
      expect(probeCalls, 0);
      expect(engine.rescueAttempted, isFalse);
    });
  });
}
