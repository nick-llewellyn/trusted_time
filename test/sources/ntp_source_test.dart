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
  group('NtpSource.groupId sentinel', () {
    // The synchronous getter no longer guesses a group from the hostname:
    // absent a resolved IP it reports the shared asn-unknown sentinel so a
    // missing ASN attribution can never be mistaken for provider diversity.
    test('is the asn-unknown sentinel for a pool host', () {
      expect(NtpSource('0.pool.ntp.org').groupId, 'asn-unknown');
    });

    test('is the asn-unknown sentinel for any host', () {
      expect(NtpSource('time.google.com').groupId, 'asn-unknown');
    });

    test('default constructor is const', () {
      const a = NtpSource('time.google.com');
      const b = NtpSource('time.google.com');
      expect(identical(a, b), isTrue);
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

    test('falls back to the sentinel when DNS throws', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => throw Exception('no DNS'),
      );
      expect(await source.resolveGroupId(), 'asn-unknown');
    });

    test('falls back to the sentinel when DNS returns no addresses', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => const [],
      );
      expect(await source.resolveGroupId(), 'asn-unknown');
    });

    test('falls back to the sentinel when the IP is outside every '
        'known range', () async {
      final source = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('9.9.9.9')],
      );
      expect(await source.resolveGroupId(), 'asn-unknown');
    });

    test('collapses two unknown hosts into the shared sentinel', () async {
      final pool = NtpSource(
        '0.pool.ntp.org',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('9.9.9.9')],
      );
      final other = NtpSource(
        'time.cloudflare.com',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('8.8.8.8')],
      );
      // Two distinct hosts that both miss the ASN table land in one group,
      // so a table miss can never inflate the consensus diversity count.
      expect(await pool.resolveGroupId(), 'asn-unknown');
      expect(await other.resolveGroupId(), 'asn-unknown');
    });
  });

  group('NtpSource.getTime IP/ASN consistency', () {
    test('hands the resolved literal IP to the NTP exchange', () async {
      String? seen;
      final source = NtpSource(
        '0.pool.ntp.org',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => [InternetAddress('1.2.3.4')],
        offsetFetcher: (lookUpAddress) async {
          seen = lookUpAddress;
          return 0;
        },
      );
      final sample = await source.getTime();
      // The exchange measures the same IP the ASN was derived from,
      // not the round-robin hostname.
      expect(seen, '1.2.3.4');
      expect(sample.groupId, 'as13335');
    });

    test('falls back to the bare host when resolution fails', () async {
      String? seen;
      final source = NtpSource(
        '0.pool.ntp.org',
        asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
        hostResolver: (host) async => throw Exception('no DNS'),
        offsetFetcher: (lookUpAddress) async {
          seen = lookUpAddress;
          return 0;
        },
      );
      final sample = await source.getTime();
      // Time success must not depend on ASN resolution: the ntp
      // package still gets the host to resolve itself.
      expect(seen, '0.pool.ntp.org');
      expect(sample.groupId, 'asn-unknown');
    });
  });
}
