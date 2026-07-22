import 'dart:async';
import 'dart:io'
    show Datagram, InternetAddress, RawDatagramSocket, RawSocketEvent, gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/data/asn_resolver.dart';
import 'package:trusted_time/src/infra/dns_budget.dart';
import 'package:trusted_time/src/sources/ntp_client.dart';
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

/// Fixture: one successful exchange result with tunable θ/δ.
NtpExchangeResult okResult({
  int offsetMicros = 0,
  int delayMicros = 30000,
  int stratum = 2,
  int rootDelayMicros = 0,
  int rootDispersionMicros = 0,
}) => NtpExchangeResult(
  offsetMicros: offsetMicros,
  delayMicros: delayMicros,
  destinationUtcMicros: DateTime.now().toUtc().microsecondsSinceEpoch,
  stratum: stratum,
  rootDelayMicros: rootDelayMicros,
  rootDispersionMicros: rootDispersionMicros,
);

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

    test('burstCount outside 1..8 is rejected in all build modes', () {
      expect(
        () => NtpSource('time.google.com', burstCount: 0),
        throwsRangeError,
      );
      expect(
        () => NtpSource('time.google.com', burstCount: 9),
        throwsRangeError,
      );
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

    test('picks a deterministic address for multi-record hosts', () async {
      AsnResolver table() =>
          resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335));
      // Same records in different orders (with an IPv6 mixed in) must yield
      // the same group: IPv4 is preferred and the choice is order-independent,
      // so the derived ASN stays stable across DNS record orderings.
      final forward = NtpSource(
        'time.cloudflare.com',
        asnResolver: table(),
        hostResolver: (host) async => [
          InternetAddress('2606:4700::1'),
          InternetAddress('1.2.3.9'),
          InternetAddress('1.2.3.4'),
        ],
      );
      final reversed = NtpSource(
        'time.cloudflare.com',
        asnResolver: table(),
        hostResolver: (host) async => [
          InternetAddress('1.2.3.4'),
          InternetAddress('1.2.3.9'),
          InternetAddress('2606:4700::1'),
        ],
      );
      expect(await forward.resolveGroupId(), 'as13335');
      expect(await reversed.resolveGroupId(), 'as13335');
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
        exchange: (address, {timeout = Duration.zero}) async {
          seen = address;
          return okResult();
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
        exchange: (address, {timeout = Duration.zero}) async {
          seen = address;
          return okResult();
        },
      );
      final sample = await source.getTime();
      // Time success must not depend on ASN resolution: the exchange
      // still gets the host to resolve itself.
      expect(seen, '0.pool.ntp.org');
      expect(sample.groupId, 'asn-unknown');
    });
  });

  group('NtpSource DNS budget integration (ADR 0008)', () {
    test(
      'resolves through the budget cache-first, reusing the result',
      () async {
        final budget = DnsBudget(4);
        var lookups = 0;
        String? seen;
        final source = NtpSource(
          '0.pool.ntp.org',
          dnsBudget: budget,
          asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
          hostResolver: (host) async {
            lookups++;
            return [InternetAddress('1.2.3.4')];
          },
          exchange: (address, {timeout = Duration.zero}) async {
            seen = address;
            return okResult();
          },
        );

        await source.getTime();
        expect(seen, '1.2.3.4');
        expect(lookups, 1);

        // A second query for the same host hits the budget cache, so the
        // resolver is not consulted again.
        await source.getTime();
        expect(lookups, 1);
      },
    );

    test(
      'a saturated budget drops the source (propagates saturation)',
      () async {
        final budget = DnsBudget(
          1,
          acquireTimeout: const Duration(milliseconds: 50),
        );
        // Occupy the only permit under an unrelated key so the source's own
        // lookup cannot be admitted.
        final held = Completer<List<InternetAddress>>();
        unawaited(budget.guard('other-host', () => held.future));
        await Future<void>.delayed(Duration.zero);

        final source = NtpSource(
          '0.pool.ntp.org',
          dnsBudget: budget,
          hostResolver: (host) async => [InternetAddress('1.2.3.4')],
          exchange: (address, {timeout = Duration.zero}) async => okResult(),
        );

        await expectLater(
          source.getTime(),
          throwsA(isA<DnsBudgetSaturation>()),
        );
        held.complete(const []);
      },
    );

    test(
      'clamps the resolver timeout to the budget admission window',
      () async {
        // Regression (ADR 0008): the host lookup must abort within the
        // budget's acquireTimeout, not the bare 2s default. With a 30ms
        // window and a resolver that only answers after 100ms, the lookup
        // times out and getTime falls back to the bare host. Without the
        // clamp the 2s default would let the 100ms resolver win and the
        // exchange would see the resolved literal IP instead — so the
        // permit would also stay held long past the engine's window.
        final budget = DnsBudget(
          4,
          acquireTimeout: const Duration(milliseconds: 30),
        );
        String? seen;
        final source = NtpSource(
          '0.pool.ntp.org',
          dnsBudget: budget,
          asnResolver: resolverFor(singleV4('1.2.3.0', '1.2.3.255', 13335)),
          hostResolver: (host) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return [InternetAddress('1.2.3.4')];
          },
          exchange: (address, {timeout = Duration.zero}) async {
            seen = address;
            return okResult();
          },
        );

        await source.getTime();
        expect(seen, '0.pool.ntp.org');
      },
    );
  });

  group('NtpSource sequential burst', () {
    NtpSource burstSource({
      required int burstCount,
      required NtpExchange exchange,
      Duration maxLatency = const Duration(seconds: 5),
      void Function(int)? onStratumObserved,
    }) => NtpSource(
      'time.example',
      hostResolver: (host) async => [InternetAddress('1.2.3.4')],
      exchange: exchange,
      maxLatency: maxLatency,
      burstCount: burstCount,
      onStratumObserved: onStratumObserved,
    );

    test('issues burstCount exchanges and keeps the lowest-δ sample', () async {
      final delays = [50000, 20000, 80000, 35000];
      var call = 0;
      final source = burstSource(
        burstCount: 4,
        exchange: (address, {timeout = Duration.zero}) async =>
            okResult(delayMicros: delays[call++]),
      );

      final sample = await source.getTime();
      expect(call, 4);
      expect(sample.delayMs, 20);
    });

    test('never has two exchanges in flight', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final source = burstSource(
        burstCount: 8,
        exchange: (address, {timeout = Duration.zero}) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          inFlight--;
          return okResult();
        },
      );

      await source.getTime();
      expect(
        maxInFlight,
        1,
        reason: 'sequential burst must never have two exchanges in flight',
      );
    });

    test('the burst shares one maxLatency budget as a shrinking '
        'deadline', () async {
      final budgets = <Duration>[];
      final source = burstSource(
        burstCount: 3,
        maxLatency: const Duration(milliseconds: 750),
        exchange: (address, {timeout = Duration.zero}) async {
          budgets.add(timeout);
          return okResult();
        },
      );

      await source.getTime();
      expect(budgets, hasLength(3));
      expect(budgets.first, const Duration(milliseconds: 750));
      for (final b in budgets.skip(1)) {
        expect(b, lessThanOrEqualTo(const Duration(milliseconds: 750)));
      }
    });

    test('a depleted budget skips remaining attempts instead of '
        'overrunning', () async {
      var call = 0;
      final source = burstSource(
        burstCount: 8,
        maxLatency: const Duration(milliseconds: 30),
        exchange: (address, {timeout = Duration.zero}) async {
          call++;
          // Each attempt outlives the whole budget, so only the
          // first attempt (which always dispatches) runs.
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return okResult();
        },
      );

      final sample = await source.getTime();
      expect(call, 1);
      expect(sample.delayMs, 30);
    });

    test('recovers when a failed attempt has a successful sibling', () async {
      var call = 0;
      final source = burstSource(
        burstCount: 2,
        exchange: (address, {timeout = Duration.zero}) async {
          if (call++ == 0) throw const NtpProtocolException('KoD');
          return okResult(delayMicros: 47000);
        },
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 47);
    });

    test('an all-fail burst rethrows the last underlying error', () async {
      var call = 0;
      final source = burstSource(
        burstCount: 3,
        exchange: (address, {timeout = Duration.zero}) async {
          call++;
          throw NtpProtocolException('failure $call');
        },
      );

      await expectLater(
        source.getTime(),
        throwsA(
          isA<NtpProtocolException>().having(
            (e) => e.message,
            'message',
            'failure 3',
          ),
        ),
      );
    });

    test('reports the winning exchange\'s stratum', () async {
      final samples = [
        okResult(delayMicros: 50000, stratum: 3),
        okResult(delayMicros: 20000, stratum: 1),
        okResult(delayMicros: 80000, stratum: 4),
      ];
      var call = 0;
      final observed = <int>[];
      final source = burstSource(
        burstCount: 3,
        exchange: (address, {timeout = Duration.zero}) async => samples[call++],
        onStratumObserved: observed.add,
      );

      await source.getTime();
      expect(observed, [1]);
    });
  });

  group('NtpSource interval shaping', () {
    test('midpoint is the θ-corrected receipt reading and half-width '
        'is the root distance', () async {
      final destination = DateTime.utc(2026).microsecondsSinceEpoch;
      final source = NtpSource(
        'time.example',
        hostResolver: (host) async => [InternetAddress('1.2.3.4')],
        exchange: (address, {timeout = Duration.zero}) async =>
            NtpExchangeResult(
              offsetMicros: 250000,
              delayMicros: 30000,
              destinationUtcMicros: destination,
              stratum: 2,
              rootDelayMicros: 8000,
              rootDispersionMicros: 2000,
            ),
      );

      final sample = await source.getTime();
      final midMs = (destination + 250000) ~/ 1000;
      // Λ = δ/2 + rootDelay/2 + rootDispersion
      //   = 15000 + 4000 + 2000 µs = 21 ms, of which the dispersion
      // component (rootDelay/2 + rootDispersion = 6 ms) is reported
      // separately so root distance stays reconstructible.
      expect(sample.interval.startMs, midMs - 21);
      expect(sample.interval.endMs, midMs + 21);
      expect(sample.delayMs, 30);
      expect(sample.dispersionMs, 6);
    });

    test('sub-millisecond error budgets round up, never to zero', () async {
      final destination = DateTime.utc(2026).microsecondsSinceEpoch;
      final source = NtpSource(
        'time.example',
        hostResolver: (host) async => [InternetAddress('1.2.3.4')],
        exchange: (address, {timeout = Duration.zero}) async =>
            NtpExchangeResult(
              offsetMicros: 0,
              delayMicros: 999,
              destinationUtcMicros: destination,
              stratum: 2,
              rootDelayMicros: 1,
              rootDispersionMicros: 0,
            ),
      );

      final sample = await source.getTime();
      // ceil((1+1)/2 + 0) µs → 1 ms: conversion error widens the
      // bound instead of shrinking it.
      expect(sample.dispersionMs, 1);
      // δ/2 rounds up too (ceil(999/2000 ms) → 1 ms), so the
      // half-width is 1 + 1 = 2 ms — never narrowed by truncation.
      final midMs = destination ~/ 1000;
      expect(sample.interval.startMs, midMs - 2);
      expect(sample.interval.endMs, midMs + 2);
    });
  });

  group('parseNtpReply wire validation (RFC 5905)', () {
    const ntpToUnixSeconds = 2208988800;
    final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

    /// Builds a mode-4 reply. Server timestamps are given as
    /// microseconds since the Unix epoch and converted to on-wire
    /// 64-bit NTP format.
    Uint8List reply({
      int li = 0,
      int mode = 4,
      int stratum = 2,
      int? t2Micros,
      int? t3Micros,
      int rootDelayMicros = 0,
      int rootDispersionMicros = 0,
      List<int>? originate,
      List<int>? referenceId,
    }) {
      final data = Uint8List(48);
      final bd = ByteData.sublistView(data);
      data[0] = (li << 6) | (4 << 3) | mode;
      data[1] = stratum;
      bd.setUint32(4, (rootDelayMicros << 16) ~/ 1000000);
      bd.setUint32(8, (rootDispersionMicros << 16) ~/ 1000000);
      if (referenceId != null) data.setRange(12, 16, referenceId);
      data.setRange(24, 32, originate ?? nonce);
      void stamp(int offset, int? unixMicros) {
        if (unixMicros == null) return;
        final seconds = unixMicros ~/ 1000000 + ntpToUnixSeconds;
        final fraction = ((unixMicros % 1000000) << 32) ~/ 1000000;
        bd.setUint32(offset, seconds);
        bd.setUint32(offset + 4, fraction);
      }

      stamp(32, t2Micros);
      stamp(40, t3Micros);
      return data;
    }

    test('computes θ and δ from the four exchange timestamps', () {
      // Server 1s ahead; 10ms upstream, 10ms downstream, 5ms of
      // server processing → RTT 25ms, δ 20ms.
      const t1 = 1000000000000000;
      const t2 = t1 + 1000000 + 10000;
      const t3 = t2 + 5000;
      const t4 = t1 + 25000;
      final result = parseNtpReply(
        reply(t2Micros: t2, t3Micros: t3, rootDelayMicros: 8000),
        nonce: nonce,
        t1Micros: t1,
        t4Micros: t4,
        rttMicros: 25000,
      );
      // The 2^-32 fraction field cannot represent every microsecond
      // exactly, so the round-trip may floor by 1 µs per timestamp.
      expect(result.offsetMicros, closeTo(1000000, 2));
      expect(result.delayMicros, closeTo(20000, 2));
      expect(result.destinationUtcMicros, t4);
      expect(result.stratum, 2);
      expect(result.rootDelayMicros, closeTo(8000, 20));
    });

    test('an implausible server interval falls back to the whole RTT', () {
      // T3 before T2 (server clock stepped mid-exchange): the
      // negative interval must not inflate δ below the true RTT.
      const t1 = 1000000000000000;
      final result = parseNtpReply(
        reply(t2Micros: t1 + 20000, t3Micros: t1 + 10000),
        nonce: nonce,
        t1Micros: t1,
        t4Micros: t1 + 25000,
        rttMicros: 25000,
      );
      expect(result.delayMicros, 25000);
    });

    NtpExchangeResult parse(Uint8List data) => parseNtpReply(
      data,
      nonce: nonce,
      t1Micros: 0,
      t4Micros: 25000,
      rttMicros: 25000,
    );

    test('rejects short packets', () {
      expect(() => parse(Uint8List(40)), throwsA(isA<NtpProtocolException>()));
    });

    test('rejects non-server modes', () {
      expect(
        () => parse(reply(mode: 3, t2Micros: 0, t3Micros: 0)),
        throwsA(isA<NtpProtocolException>()),
      );
    });

    test('rejects an unsynchronized server (LI = 3)', () {
      expect(
        () => parse(reply(li: 3, t2Micros: 0, t3Micros: 0)),
        throwsA(isA<NtpProtocolException>()),
      );
    });

    test('surfaces the kiss-o\'-death code on stratum 0', () {
      expect(
        () => parse(reply(stratum: 0, referenceId: 'RATE'.codeUnits)),
        throwsA(
          isA<NtpProtocolException>().having(
            (e) => e.message,
            'message',
            contains('RATE'),
          ),
        ),
      );
    });

    test('rejects stratum above 15', () {
      expect(
        () => parse(reply(stratum: 16, t2Micros: 0, t3Micros: 0)),
        throwsA(isA<NtpProtocolException>()),
      );
    });

    test('rejects a reply whose originate field is not the nonce', () {
      expect(
        () => parse(
          reply(t2Micros: 0, t3Micros: 0, originate: [9, 9, 9, 9, 9, 9, 9, 9]),
        ),
        throwsA(
          isA<NtpProtocolException>().having(
            (e) => e.message,
            'message',
            contains('nonce'),
          ),
        ),
      );
    });
  });

  group('defaultNtpExchange (loopback UDP round trip)', () {
    const ntpToUnixSeconds = 2208988800;

    /// Binds a loopback UDP server that answers the first datagram with
    /// [respond]'s bytes (or stays silent when it returns null) and
    /// records the request for wire-format assertions.
    Future<({RawDatagramSocket socket, Future<Datagram> request})> serve(
      Uint8List? Function(Datagram request) respond,
    ) async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final request = Completer<Datagram>();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d == null) return;
        if (!request.isCompleted) request.complete(d);
        final replyBytes = respond(d);
        if (replyBytes != null) socket.send(replyBytes, d.address, d.port);
      });
      return (socket: socket, request: request.future);
    }

    /// Builds a well-formed mode-4 reply to [request]: the request's
    /// transmit nonce is echoed into the originate field and T2/T3
    /// report a server clock [offsetMicros] ahead of the local one.
    Uint8List serverReply(Datagram request, {int offsetMicros = 0}) {
      final data = Uint8List(48);
      final bd = ByteData.sublistView(data);
      data[0] = (4 << 3) | 4; // LI = 0, VN = 4, Mode = 4 (server).
      data[1] = 2; // Stratum.
      data.setRange(24, 32, request.data.sublist(40, 48));
      final now = DateTime.now().toUtc().microsecondsSinceEpoch + offsetMicros;
      bd.setUint32(32, now ~/ 1000000 + ntpToUnixSeconds);
      bd.setUint32(36, ((now % 1000000) << 32) ~/ 1000000);
      bd.setUint32(40, now ~/ 1000000 + ntpToUnixSeconds);
      bd.setUint32(44, ((now % 1000000) << 32) ~/ 1000000);
      return data;
    }

    test('completes an exchange and sends a well-formed request', () async {
      final server = await serve(
        (request) => serverReply(request, offsetMicros: 1000000),
      );
      addTearDown(server.socket.close);

      final result = await defaultNtpExchange(
        '127.0.0.1',
        timeout: const Duration(seconds: 5),
        port: server.socket.port,
      );

      final request = await server.request;
      expect(request.data.length, 48);
      // LI = 0, VN = 4, Mode = 3 (client).
      expect(request.data[0], 0x23);
      // The transmit field carries a nonce rather than the local clock,
      // and every other field is zero: nothing about the local clock
      // goes on the wire.
      expect(request.data.sublist(40, 48).any((b) => b != 0), isTrue);
      expect(request.data.sublist(1, 40).any((b) => b != 0), isFalse);

      // The server reported itself 1s ahead; the loopback round trip
      // contributes at most a few ms of skew to θ.
      expect(result.offsetMicros, closeTo(1000000, 100000));
      expect(result.delayMicros, greaterThanOrEqualTo(0));
      expect(result.delayMicros, lessThan(1000000));
      expect(result.stratum, 2);
    });

    test('rejects a reply that does not echo the nonce', () async {
      final server = await serve((request) {
        final data = serverReply(request);
        data.setRange(24, 32, List.filled(8, 9));
        return data;
      });
      addTearDown(server.socket.close);

      await expectLater(
        defaultNtpExchange(
          '127.0.0.1',
          timeout: const Duration(seconds: 5),
          port: server.socket.port,
        ),
        throwsA(
          isA<NtpProtocolException>().having(
            (e) => e.message,
            'message',
            contains('nonce'),
          ),
        ),
      );
    });

    test('times out when the server never replies', () async {
      final server = await serve((_) => null);
      addTearDown(server.socket.close);

      await expectLater(
        defaultNtpExchange(
          '127.0.0.1',
          timeout: const Duration(milliseconds: 100),
          port: server.socket.port,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
