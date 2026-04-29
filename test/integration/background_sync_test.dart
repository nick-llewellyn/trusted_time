@TestOn('vm')
@Tags(['background'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/background_sync.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

/// Integration-style verification of the headless background-sync
/// unit-of-work, exercising the internal [runBackgroundSync] function
/// (from `package:trusted_time/src/background_sync.dart`) against a
/// pre-seeded stale anchor with an injected fixed clock and store.
///
/// **Scope**: this test pins the contract that the unit-of-work
/// advances [TrustAnchor.networkUtcMs] in the persisted store. It does
/// **not** drive the real OS scheduler because that requires a device
/// and is platform-specific. Public-API coverage of
/// [TrustedTime.runBackgroundSync] (including the
/// `notifyBackgroundComplete` channel call) lives in
/// `test/background_sync_test.dart`.
///
/// To exercise the real OS scheduler manually:
///
/// - Android: `adb shell cmd jobscheduler run -f`
///   `[package] [jobId]` against a debug-built host app, then inspect
///   logs for the `notifyBackgroundComplete` channel call.
/// - iOS: in Xcode with the simulator paused, run
///   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
///   _simulateLaunchForTaskWithIdentifier:@"com.trustedtime.backgroundsync"]`
///   and observe the headless engine spinning up.
///
/// The unit-of-work boundary proven here is what those manual steps
/// would invoke; full end-to-end coverage is the manual step.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runBackgroundSync (integration)', () {
    final consensusUtc = DateTime.utc(2026, 6, 1, 12);
    final staleUtc = DateTime.utc(2026, 1, 1, 0);

    test('advances persisted anchor.networkUtcMs from a stale baseline',
        () async {
      final store = InMemoryAnchorStorage();

      // Seed a stale anchor mimicking what TrustedTimeImpl.init would
      // have written during a previous foreground session.
      final stale = TrustAnchor(
        networkUtcMs: staleUtc.millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: staleUtc.millisecondsSinceEpoch,
        uncertaintyMs: 50,
      );
      await store.save(stale);

      final result = await runBackgroundSync(
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          additionalSources: [
            _StubSource(idValue: 'stub-a', utc: consensusUtc),
            _StubSource(
              idValue: 'stub-b',
              utc: consensusUtc.add(const Duration(milliseconds: 8)),
            ),
          ],
        ),
        store: store,
        clock: _StubClock(7000),
      );

      expect(result, isA<BackgroundSyncSuccess>());
      final after = await store.load();
      expect(after, isNotNull);
      expect(
        after!.networkUtcMs,
        greaterThan(stale.networkUtcMs),
        reason: 'Background sync did not advance the persisted anchor.',
      );
      expect(
        after.networkUtcMs,
        closeTo(consensusUtc.millisecondsSinceEpoch, 100),
      );
    });

    test('leaves persisted anchor untouched when sync fails', () async {
      final store = InMemoryAnchorStorage();
      final original = TrustAnchor(
        networkUtcMs: staleUtc.millisecondsSinceEpoch,
        uptimeMs: 2000,
        wallMs: staleUtc.millisecondsSinceEpoch,
        uncertaintyMs: 100,
      );
      await store.save(original);

      final result = await runBackgroundSync(
        config: TrustedTimeConfig(
          ntpServers: const [],
          httpsSources: const [],
          ntsServers: const [],
          minimumQuorum: 2,
          additionalSources: [
            _StubSource(idValue: 'a', utc: consensusUtc, fail: true),
            _StubSource(idValue: 'b', utc: consensusUtc, fail: true),
          ],
        ),
        store: store,
        clock: _StubClock(7000),
      );

      expect(result, isA<BackgroundSyncFailure>());
      expect(await store.load(), original);
    });
  });
}

class _StubClock implements MonotonicClock {
  _StubClock(this.value);
  final int value;
  @override
  Future<int> uptimeMs() async => value;
}

class _StubSource implements TrustedTimeSource {
  _StubSource({required this.idValue, required this.utc, this.fail = false});
  final String idValue;
  final DateTime utc;
  final bool fail;

  @override
  String get id => idValue;

  @override
  Future<TimeSample> fetch() async {
    if (fail) throw Exception('stub failure');
    return TimeSample(
      networkUtc: utc,
      roundTripTime: const Duration(milliseconds: 25),
      uncertainty: const Duration(milliseconds: 12),
      capturedMonotonicMs: 7000,
      source: TimeSourceMetadata(kind: TimeSourceKind.custom, id: idValue),
      capturedAt: DateTime.now().toUtc(),
    );
  }
}
