import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/anchor_store.dart';
import 'package:trusted_time/src/models.dart';

void main() {
  group('InMemoryAnchorStorage', () {
    late InMemoryAnchorStorage storage;

    setUp(() => storage = InMemoryAnchorStorage());

    test('load returns null when nothing has been saved', () async {
      expect(await storage.load(), isNull);
      expect(await storage.loadLastKnown(), isNull);
    });

    test('save then load returns the same anchor', () async {
      const anchor = TrustAnchor(
        networkUtcMs: 1700000000000,
        uptimeMs: 50000,
        wallMs: 1700000000123,
        uncertaintyMs: 25,
      );
      await storage.save(anchor);
      expect(await storage.load(), equals(anchor));
    });

    test('save populates loadLastKnown timestamps', () async {
      const anchor = TrustAnchor(
        networkUtcMs: 100,
        uptimeMs: 200,
        wallMs: 300,
        uncertaintyMs: 5,
      );
      await storage.save(anchor);
      final last = await storage.loadLastKnown();
      expect(last, isNotNull);
      expect(last!.trustedUtcMs, 100);
      expect(last.wallMs, 300);
    });

    test('clear wipes anchor and last-known timestamps', () async {
      const anchor = TrustAnchor(
        networkUtcMs: 1, uptimeMs: 2, wallMs: 3, uncertaintyMs: 0,
      );
      await storage.save(anchor);
      await storage.clear();
      expect(await storage.load(), isNull);
      expect(await storage.loadLastKnown(), isNull);
    });

    test('successive saves overwrite earlier state', () async {
      const a = TrustAnchor(
        networkUtcMs: 100, uptimeMs: 1, wallMs: 200, uncertaintyMs: 5,
      );
      const b = TrustAnchor(
        networkUtcMs: 999, uptimeMs: 2, wallMs: 888, uncertaintyMs: 7,
      );
      await storage.save(a);
      await storage.save(b);
      expect(await storage.load(), equals(b));
      final last = await storage.loadLastKnown();
      expect(last!.trustedUtcMs, 999);
      expect(last.wallMs, 888);
    });
  });
}
