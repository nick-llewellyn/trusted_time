import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Seconds between the NTP epoch (1900-01-01) and the Unix epoch.
const int _ntpToUnixSeconds = 2208988800;

/// One completed SNTP client/server exchange, reduced to the RFC 5905
/// quantities [NtpSource] needs to build a `TimeSample`.
///
/// All durations are in microseconds. The four exchange timestamps are
/// already folded into [offsetMicros] (θ) and [delayMicros] (δ); the
/// remaining fields carry the server-side error budget and quality
/// telemetry verbatim from the reply header.
final class NtpExchangeResult {
  /// Documented on each field.
  const NtpExchangeResult({
    required this.offsetMicros,
    required this.delayMicros,
    required this.destinationUtcMicros,
    required this.stratum,
    required this.rootDelayMicros,
    required this.rootDispersionMicros,
  });

  /// Clock offset θ = ((T2−T1) + (T3−T4)) / 2: how far the local wall
  /// clock lags (positive) or leads (negative) the server's.
  final int offsetMicros;

  /// Network delay δ = RTT − (T3−T2): the measured round trip minus
  /// the server's processing time, the RFC 5905 peer delay. Never
  /// negative; when the server interval is implausible (negative or
  /// exceeding the RTT) the whole RTT is reported instead.
  final int delayMicros;

  /// Local wall-clock reading at T4 (reply receipt), in microseconds
  /// since the Unix epoch. `destinationUtcMicros + offsetMicros` is
  /// the server's clock at the instant the reply arrived — the same
  /// midpoint shape as `T3 + δ/2`.
  final int destinationUtcMicros;

  /// Server stratum from the reply header (1..15; 0 and >15 are
  /// rejected during parsing).
  final int stratum;

  /// Total round-trip delay to the reference clock, from the reply
  /// header's 16.16 fixed-point seconds field.
  final int rootDelayMicros;

  /// Total dispersion to the reference clock, from the reply header's
  /// 16.16 fixed-point seconds field.
  final int rootDispersionMicros;
}

/// Performs one SNTP exchange against [address] (an IP literal or
/// hostname). Injectable so tests can script exchanges without UDP.
typedef NtpExchange =
    Future<NtpExchangeResult> Function(String address, {Duration timeout});

/// Reply-header failures that abort an exchange: wrong mode, KoD
/// (stratum 0), unsynchronized server (LI = 3), or a transmit-nonce
/// echo mismatch (off-path spoofing defence).
final class NtpProtocolException implements Exception {
  /// Documented.
  const NtpProtocolException(this.message);

  /// Human-readable reason the reply was rejected.
  final String message;

  @override
  String toString() => 'NtpProtocolException: $message';
}

/// Default [NtpExchange]: one UDP mode-3 query against `address:port`
/// (123 unless overridden, which only tests running a loopback server
/// on an unprivileged port need to do).
///
/// [timeout] is a single wall-clock budget for the whole exchange:
/// when [address] is a hostname, DNS resolution and the reply wait
/// share it rather than each receiving it in full, so a slow lookup
/// shrinks the reply window and the exchange as a whole never runs
/// past ~one budget. This keeps the caller's shrinking-deadline
/// arithmetic honest even on the fallback path where [NtpSource]
/// hands over the bare host after its own resolve step failed.
///
/// The transmit-timestamp field carries 8 random bytes rather than the
/// local clock: the server echoes it back verbatim in the originate
/// field, so it doubles as an unpredictable nonce that an off-path
/// attacker cannot forge — and it avoids leaking the local clock on
/// the wire. T1/T4 for θ are read from the local wall clock around the
/// exchange; the round trip for δ is measured on a monotonic
/// [Stopwatch] so a wall-clock step mid-exchange (exactly the
/// manipulation this library defends against) cannot corrupt the
/// delay measurement.
Future<NtpExchangeResult> defaultNtpExchange(
  String address, {
  Duration timeout = const Duration(seconds: 5),
  int port = 123,
}) async {
  final budget = Stopwatch()..start();
  final addr =
      InternetAddress.tryParse(address) ??
      (await InternetAddress.lookup(address).timeout(timeout)).first;
  final remaining = timeout - budget.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException('NTP exchange budget exhausted by DNS', timeout);
  }
  final socket = await RawDatagramSocket.bind(
    addr.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4,
    0,
  );
  try {
    final nonce = Uint8List(8);
    final random = Random.secure();
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = random.nextInt(256);
    }
    final packet = Uint8List(48);
    packet[0] = 0x23; // LI = 0, VN = 4, Mode = 3 (client).
    packet.setRange(40, 48, nonce);

    final reply = Completer<Datagram>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      // Accept only a datagram from the queried server; anything else
      // (multicast noise, a second reply) is ignored rather than
      // failing the exchange.
      if (d == null || reply.isCompleted || d.address != addr) return;
      reply.complete(d);
    });

    final rtt = Stopwatch()..start();
    final t1Micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    if (socket.send(packet, addr, port) != packet.length) {
      throw const SocketException('NTP request was not sent in full');
    }
    final Datagram datagram;
    try {
      datagram = await reply.future.timeout(remaining);
    } finally {
      await sub.cancel();
    }
    final t4Micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    rtt.stop();
    return parseNtpReply(
      datagram.data,
      nonce: nonce,
      t1Micros: t1Micros,
      t4Micros: t4Micros,
      rttMicros: rtt.elapsedMicroseconds,
    );
  } finally {
    socket.close();
  }
}

/// Reads the 64-bit NTP timestamp at [offset] as microseconds since
/// the Unix epoch. The fraction field counts 1/2^32 seconds; the
/// era-0 wrap (2036) is out of scope for a library whose whole point
/// is agreeing with the present-day network consensus.
int _timestampMicros(ByteData bd, int offset) {
  final seconds = bd.getUint32(offset);
  final fraction = bd.getUint32(offset + 4);
  return (seconds - _ntpToUnixSeconds) * 1000000 + ((fraction * 1000000) >> 32);
}

/// Reads the 32-bit NTP short format (16.16 fixed-point seconds) at
/// [offset] as microseconds.
int _shortMicros(ByteData bd, int offset) =>
    (bd.getUint32(offset) * 1000000) >> 16;

/// Validates and reduces a raw mode-4 NTP reply to an
/// [NtpExchangeResult], applying RFC 5905's on-wire arithmetic.
///
/// [nonce] is the 8-byte value the request carried in its transmit
/// field; the reply's originate field must echo it exactly, or the
/// datagram is treated as forged/mismatched and rejected. [t1Micros]
/// and [t4Micros] are the local wall readings around the exchange
/// (they anchor θ), while [rttMicros] is the monotonic round-trip
/// measurement that anchors δ — kept separate so a wall step
/// mid-exchange corrupts neither.
///
/// θ folds the wall-based server intervals; δ subtracts the server
/// processing interval (T3−T2) from the monotonic RTT. A server
/// interval outside `[0, rtt]` is implausible (clock step or broken
/// server) and falls back to the whole RTT — the same plausibility
/// guard the NTS path applies to its clock-filter fields.
///
/// Throws [NtpProtocolException] on structural failures: short
/// packet, non-server mode, unsynchronized leap indicator, kiss-o'-
/// death (stratum 0), out-of-range stratum, or nonce mismatch.
@visibleForTesting
NtpExchangeResult parseNtpReply(
  Uint8List data, {
  required Uint8List nonce,
  required int t1Micros,
  required int t4Micros,
  required int rttMicros,
}) {
  if (data.length < 48) {
    throw NtpProtocolException(
      'reply too short: ${data.length} bytes (need 48)',
    );
  }
  final bd = ByteData.sublistView(data);

  final leap = (data[0] >> 6) & 0x3;
  final mode = data[0] & 0x7;
  final stratum = data[1];
  if (mode != 4) {
    throw NtpProtocolException('unexpected mode $mode (want 4/server)');
  }
  if (leap == 3) {
    throw const NtpProtocolException('server unsynchronized (LI = 3)');
  }
  if (stratum == 0) {
    // Kiss-o'-Death: the reference-id field carries an ASCII code
    // (e.g. RATE, DENY) telling the client to back off.
    final code = String.fromCharCodes(
      data.sublist(12, 16).where((b) => b >= 0x20 && b < 0x7f),
    );
    throw NtpProtocolException('kiss-o\'-death from server (code "$code")');
  }
  if (stratum > 15) {
    throw NtpProtocolException('invalid stratum $stratum (want 1..15)');
  }
  for (var i = 0; i < 8; i++) {
    if (data[24 + i] != nonce[i]) {
      throw const NtpProtocolException(
        'originate timestamp does not echo the request nonce '
        '(mismatched or forged reply)',
      );
    }
  }

  final t2Micros = _timestampMicros(bd, 32); // Server receive.
  final t3Micros = _timestampMicros(bd, 40); // Server transmit.

  // θ = ((T2−T1) + (T3−T4)) / 2 — RFC 5905 §8. Wall-based throughout:
  // a wall step mid-exchange corrupts θ, but the sample it produces
  // is exactly what consensus cross-checking exists to reject.
  final offsetMicros = ((t2Micros - t1Micros) + (t3Micros - t4Micros)) ~/ 2;

  // δ = (T4−T1) − (T3−T2), with (T4−T1) measured monotonically.
  final serverIntervalMicros = t3Micros - t2Micros;
  final plausible =
      serverIntervalMicros >= 0 && serverIntervalMicros <= rttMicros;
  final delayMicros = plausible ? rttMicros - serverIntervalMicros : rttMicros;

  return NtpExchangeResult(
    offsetMicros: offsetMicros,
    delayMicros: delayMicros,
    destinationUtcMicros: t4Micros,
    stratum: stratum,
    rootDelayMicros: _shortMicros(bd, 4),
    rootDispersionMicros: _shortMicros(bd, 8),
  );
}
