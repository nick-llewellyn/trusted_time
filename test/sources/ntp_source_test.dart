import 'dart:async';
import 'dart:io' show InternetAddress, gzip;
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
      // The deadline starts before host resolution, so even the first
      // attempt sees only the remaining balance.
      var previous = const Duration(milliseconds: 750);
      for (final b in budgets) {
        expect(b, lessThanOrEqualTo(previous));
        previous = b;
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
          // first attempt runs.
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return okResult();
        },
      );

      final sample = await source.getTime();
      expect(call, 1);
      expect(sample.delayMs, 30);
    });

    test('slow host resolution depletes the burst budget', () async {
      // The deadline starts before host resolution, so a slow lookup
      // is charged against the same maxLatency the burst shares. Here
      // resolution outlives the whole budget: attempt 0 is never
      // dispatched and the call fails with a concrete TimeoutException
      // instead of silently exceeding maxLatency.
      var call = 0;
      final source = NtpSource(
        'time.example',
        hostResolver: (host) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return [InternetAddress('1.2.3.4')];
        },
        exchange: (address, {timeout = Duration.zero}) async {
          call++;
          return okResult();
        },
        maxLatency: const Duration(milliseconds: 20),
        burstCount: 4,
      );

      await expectLater(source.getTime(), throwsA(isA<TimeoutException>()));
      expect(call, 0);
    });

    test('host resolution time shrinks the first attempt\'s budget', () async {
      final budgets = <Duration>[];
      final source = NtpSource(
        'time.example',
        hostResolver: (host) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return [InternetAddress('1.2.3.4')];
        },
        exchange: (address, {timeout = Duration.zero}) async {
          budgets.add(timeout);
          return okResult();
        },
        maxLatency: const Duration(milliseconds: 500),
        burstCount: 1,
      );

      await source.getTime();
      expect(budgets, hasLength(1));
      expect(
        budgets.first,
        lessThanOrEqualTo(const Duration(milliseconds: 450)),
      );
      expect(budgets.first, greaterThan(Duration.zero));
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

    test('sample carries the winner\'s stratum and the burst delay '
        'spread as jitter', () async {
      // Delays 50/20/80 ms → winner δ=20ms stratum 1, spread 60ms.
      final results = [
        okResult(delayMicros: 50000, stratum: 3),
        okResult(delayMicros: 20000, stratum: 1),
        okResult(delayMicros: 80000, stratum: 4),
      ];
      var call = 0;
      final source = burstSource(
        burstCount: 3,
        exchange: (address, {timeout = Duration.zero}) async => results[call++],
      );

      final sample = await source.getTime();
      expect(sample.stratum, 1);
      expect(sample.jitterMs, 60);
    });

    test('jitter matches the spread of the truncated per-attempt delayMs '
        'values', () async {
      // Delays 20.9ms and 80.1ms truncate to delayMs 20 and 80, so the
      // reported jitter must be 60 — not the 59 that truncating the µs
      // difference (80100 − 20900 = 59200µs) would produce. Jitter and
      // delayMs must describe the same ms-scale metric.
      final results = [
        okResult(delayMicros: 20900, stratum: 2),
        okResult(delayMicros: 80100, stratum: 3),
      ];
      var call = 0;
      final source = burstSource(
        burstCount: 2,
        exchange: (address, {timeout = Duration.zero}) async => results[call++],
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 20);
      expect(sample.jitterMs, 60);
    });

    test('a single-success burst has null jitter, not zero', () async {
      // One observation has no spread; reporting 0 would fake a
      // perfectly stable path.
      final source = burstSource(
        burstCount: 1,
        exchange: (address, {timeout = Duration.zero}) async =>
            okResult(delayMicros: 20000, stratum: 2),
      );

      final sample = await source.getTime();
      expect(sample.jitterMs, isNull);
      expect(sample.stratum, 2);
    });
  });
}
