import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/infra/dns_budget.dart';

void main() {
  group('DnsBudget (ADR 0008)', () {
    test('a cache hit does not consume a permit', () async {
      final budget = DnsBudget(2);
      var calls = 0;
      Future<List<int>> resolve() async {
        calls++;
        return const [1, 2, 3];
      }

      expect(await budget.guard('h', resolve), const [1, 2, 3]);
      expect(calls, 1);
      expect(budget.availablePermits, 2);

      // A second lookup for the same key within the TTL is served from
      // cache: resolve is not re-run and no permit is taken.
      expect(await budget.guard('h', resolve), const [1, 2, 3]);
      expect(calls, 1);
      expect(budget.availablePermits, 2);
    });

    test('serialises uncached lookups beyond the cap, then releases', () async {
      final budget = DnsBudget(1);
      final gate = Completer<void>();
      var active = 0;
      var maxActive = 0;
      Future<List<int>> slow(String key) => budget.guard(key, () async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        await gate.future;
        active--;
        return const [0];
      });

      final a = slow('a');
      final b = slow('b');
      await Future<void>.delayed(Duration.zero);
      // Only one lookup may be in flight under a cap of 1.
      expect(maxActive, 1);

      gate.complete();
      await Future.wait([a, b]);
      expect(maxActive, 1);
      expect(budget.availablePermits, 1);
    });

    test(
      'throws DnsBudgetSaturation when no permit frees up in time',
      () async {
        final budget = DnsBudget(
          1,
          acquireTimeout: const Duration(milliseconds: 50),
        );
        final held = Completer<List<int>>();
        // Occupy the only permit until the test releases it.
        unawaited(budget.guard('holder', () => held.future));
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          budget.guard('blocked', () async => const [0]),
          throwsA(isA<DnsBudgetSaturation>()),
        );
        held.complete(const [0]);
      },
    );

    test('a resolution error propagates and frees the permit', () async {
      final budget = DnsBudget(1);
      await expectLater(
        budget.guard('h', () async => throw const FormatException('boom')),
        throwsA(isA<FormatException>()),
      );
      // The permit must have been released despite the failure.
      expect(budget.availablePermits, 1);
    });

    test('rejects a non-positive maxConcurrent with ArgumentError', () {
      // Runtime validation (not assert): the type is instantiable outside
      // TrustedTimeConfig, and a stripped assert in release would let
      // DnsBudget(0) construct and then deny every lookup forever.
      expect(() => DnsBudget(0), throwsArgumentError);
      expect(() => DnsBudget(-1), throwsArgumentError);
    });

    test('rejects a non-positive acquireTimeout or cacheTtl', () {
      expect(
        () => DnsBudget(1, acquireTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => DnsBudget(1, cacheTtl: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    });

    test('exposes its admission window via acquireTimeout', () {
      const window = Duration(milliseconds: 250);
      expect(DnsBudget(2, acquireTimeout: window).acquireTimeout, window);
    });
  });
}
