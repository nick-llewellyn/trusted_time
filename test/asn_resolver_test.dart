import 'dart:io' show InternetAddress, gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/asn_resolver.dart';

/// Encodes ranges into the on-disk table layout (see
/// `tool/generate_asn_db.dart`) and gzips them, mirroring the asset the
/// generator produces so the reader is exercised end-to-end.
Uint8List buildTable(int kind, List<(String, String, int)> ranges) {
  final w = kind == 4 ? 4 : 16;
  final body = Uint8List(12 + ranges.length * (2 * w + 4));
  final bd = ByteData.sublistView(body);
  body
    ..[0] = 0x41
    ..[1] = 0x53
    ..[2] = 0x4E
    ..[3] = 0x31
    ..[4] = 1
    ..[5] = kind;
  bd.setUint32(8, ranges.length);
  var o = 12;
  for (final (start, end, asn) in ranges) {
    body.setRange(o, o + w, InternetAddress(start).rawAddress);
    o += w;
    body.setRange(o, o + w, InternetAddress(end).rawAddress);
    o += w;
    bd.setUint32(o, asn);
    o += 4;
  }
  return Uint8List.fromList(gzip.encode(body));
}

void main() {
  group('AsnResolver IPv4', () {
    late AsnResolver resolver;
    setUp(() {
      final table = buildTable(4, const [
        ('1.2.3.0', '1.2.3.255', 13335),
        ('8.8.8.0', '8.8.8.255', 15169),
        ('203.0.113.0', '203.0.113.127', 64500),
      ]);
      resolver = AsnResolver(loader: (key) async => table);
    });

    test('resolves an address inside a range', () async {
      expect(await resolver.lookup(InternetAddress('1.2.3.4')), 13335);
      expect(await resolver.lookup(InternetAddress('8.8.8.8')), 15169);
    });

    test('matches inclusive range boundaries', () async {
      expect(await resolver.lookup(InternetAddress('1.2.3.0')), 13335);
      expect(await resolver.lookup(InternetAddress('1.2.3.255')), 13335);
      expect(await resolver.lookup(InternetAddress('203.0.113.127')), 64500);
    });

    test('returns null in a gap and past the last range', () async {
      expect(await resolver.lookup(InternetAddress('9.9.9.9')), isNull);
      expect(await resolver.lookup(InternetAddress('203.0.113.200')), isNull);
    });

    test('returns null below the first range', () async {
      expect(await resolver.lookup(InternetAddress('0.0.0.1')), isNull);
    });
  });

  group('AsnResolver IPv6', () {
    test('resolves an address inside a v6 range', () async {
      final table = buildTable(6, const [
        ('2001:4860::', '2001:4860:ffff:ffff:ffff:ffff:ffff:ffff', 15169),
        ('2606:4700::', '2606:4700:ffff:ffff:ffff:ffff:ffff:ffff', 13335),
      ]);
      final resolver = AsnResolver(loader: (key) async => table);
      expect(
        await resolver.lookup(InternetAddress('2001:4860:4860::8888')),
        15169,
      );
      expect(
        await resolver.lookup(InternetAddress('2606:4700:4700::1111')),
        13335,
      );
      expect(await resolver.lookup(InternetAddress('2a00::1')), isNull);
    });
  });

  group('AsnResolver graceful failure', () {
    test('returns null when the asset cannot be loaded', () async {
      final resolver = AsnResolver(
        loader: (key) async => throw Exception('missing asset'),
      );
      expect(await resolver.lookup(InternetAddress('8.8.8.8')), isNull);
    });

    test('returns null on a malformed (bad magic) table', () async {
      final bad = Uint8List.fromList(gzip.encode(Uint8List(12)));
      final resolver = AsnResolver(loader: (key) async => bad);
      expect(await resolver.lookup(InternetAddress('8.8.8.8')), isNull);
    });

    test('caches a load failure instead of retrying every lookup', () async {
      var calls = 0;
      final resolver = AsnResolver(
        loader: (key) async {
          calls++;
          throw Exception('boom');
        },
      );
      await resolver.lookup(InternetAddress('8.8.8.8'));
      await resolver.lookup(InternetAddress('1.1.1.1'));
      expect(calls, 1);
    });
  });

  group('AsnResolver concurrency', () {
    test('concurrent first-use lookups load the table only once', () async {
      var calls = 0;
      final table = buildTable(4, const [('1.2.3.0', '1.2.3.255', 13335)]);
      final resolver = AsnResolver(
        loader: (key) async {
          calls++;
          return table;
        },
      );
      final results = await Future.wait([
        resolver.lookup(InternetAddress('1.2.3.4')),
        resolver.lookup(InternetAddress('1.2.3.4')),
        resolver.lookup(InternetAddress('1.2.3.4')),
      ]);
      expect(results, [13335, 13335, 13335]);
      expect(calls, 1);
    });
  });
}
