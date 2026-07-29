// The reply path: how a server's answer becomes a TimeSample.
//
//   interval shaping     NtpExchangeResult → TimeSample interval
//   parseNtpReply        datagram bytes    → NtpExchangeResult
//   defaultNtpExchange   socket round trip → NtpExchangeResult
//
// The concerns above this path — group identity, ASN derivation, DNS
// budgeting, burst orchestration — live in ntp_source_test.dart.

import 'dart:async';
import 'dart:io'
    show Datagram, InternetAddress, RawDatagramSocket, RawSocketEvent;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/sources/ntp_client.dart';
import 'package:trusted_time/src/sources/ntp_source_io.dart';

void main() {
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

    test('carries the leap indicator and reference id as telemetry', () {
      const t1 = 1000000000000000;
      final result = parseNtpReply(
        reply(
          li: 1,
          t2Micros: t1 + 10000,
          t3Micros: t1 + 15000,
          referenceId: 'GPS\x00'.codeUnits,
        ),
        nonce: nonce,
        t1Micros: t1,
        t4Micros: t1 + 25000,
        rttMicros: 25000,
      );
      expect(result.leapIndicator, 1);
      // 'GPS\0' big-endian: 0x47_50_53_00.
      expect(result.referenceId, 0x47505300);
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
