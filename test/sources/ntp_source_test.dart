import 'dart:io' show InternetAddress, gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/asn_resolver.dart';
import 'package:trusted_time/src/sources/ntp_source_io.dart';

/// Single-range IPv4 table in the format `AsnResolver` reads.
Uint8List singleV4(String start, String end, int asn) {
  final body = Uint8List(12 + 12);
  final bd = ByteData.sublistView(body);
  body
    ..[0] = 0x41
    ..[1] = 0x53
    ..[2] = 0x4E
    ..[3] = 0x31
    ..[4] = 1
    ..[5] = 4;
  bd.setUint32(8, 1);
  body.setRange(12, 16, InternetAddress(start).rawAddress);
  body.setRange(16, 20, InternetAddress(end).rawAddress);
  bd.setUint32(20, asn);
  return Uint8List.fromList(gzip.encode(body));
}

AsnResolver resolverFor(Uint8List table) =>
    AsnResolver(loader: (key) async => table);

void main() {
  group('NtpSource.groupId host heuristic (fallback)', () {
    // Documents the existing (untouched) heuristic: drop the TLD and keep
    // the two labels below it.
    test('keeps the two labels below the TLD for a pool host', () {
      expect(NtpSource('0.pool.ntp.org').groupId, 'pool.ntp');
    });

    test('keeps the two labels below the TLD otherwise', () {
      expect(NtpSource('time.google.com').groupId, 'time.google');
    });
  });

  group('NtpSource.resolveGroupId ASN derivation', () {
    test('uses as<asn> when DNS + ASN both resolve', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('1.2.3.4')],
      );
      expect(await source.resolveGroupId(), 'as13335');
    });

    test('falls back to the heuristic when DNS throws', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => throw Exception('no DNS'),
      );
      expect(await source.resolveGroupId(), 'time.cloudflare');
    });

    test('falls back when DNS returns no addresses', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => const [],
      );
      expect(await source.resolveGroupId(), 'time.cloudflare');
    });

    test('falls back when the IP is outside every known range', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('9.9.9.9')],
      );
      expect(await source.resolveGroupId(), 'time.cloudflare');
    });

    test('falls back to the host heuristic for an unknown pool IP', () async {
      final source = NtpSource(
        '0.pool.ntp.org',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('9.9.9.9')],
      );
      expect(await source.resolveGroupId(), 'pool.ntp');
    });
  });
}
