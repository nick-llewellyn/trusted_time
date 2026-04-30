@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sources/nts_source_io.dart';

class _FakeMonotonicClock implements MonotonicClock {
  _FakeMonotonicClock(this.value);
  int value;
  int callCount = 0;
  @override
  Future<int> uptimeMs() async {
    callCount++;
    return value;
  }
}

/// Monotonic clock that returns successive values from a queue and
/// records every read for ordering assertions.
class _ScriptedMonotonicClock implements MonotonicClock {
  _ScriptedMonotonicClock(this._values);
  final List<int> _values;
  int _index = 0;
  final List<int> reads = [];
  @override
  Future<int> uptimeMs() async {
    final v = _values[_index++];
    reads.add(v);
    return v;
  }
}

NtsTimeSample _sample({
  int utcUnixMicros = 1700000000000000,
  int roundTripMicros = 8000,
  int serverStratum = 2,
  int aeadId = 15,
  int freshCookies = 7,
}) => NtsTimeSample(
  utcUnixMicros: utcUnixMicros,
  roundTripMicros: roundTripMicros,
  serverStratum: serverStratum,
  aeadId: aeadId,
  freshCookies: freshCookies,
);

/// No-op cookie warmer for tests that don't care about the pre-warm.
Future<int> _noopWarm({
  required NtsServerSpec spec,
  required int timeoutMs,
}) async => 8;

void main() {
  group('NtsSource', () {
    test('id is namespaced by host', () {
      final source = NtsSource(
        'time.cloudflare.com',
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async => _sample(),
        warmCookies: _noopWarm,
      );
      expect(source.id, 'nts:time.cloudflare.com');
    });

    test(
      'selected sample is marked authenticated and carries stratum',
      () async {
        final source = NtsSource(
          'time.cloudflare.com',
          burstSize: 1,
          burstSpacing: Duration.zero,
          clock: _FakeMonotonicClock(123456),
          query: ({required spec, required timeoutMs}) async => _sample(
            utcUnixMicros: 1700000000123456,
            roundTripMicros: 12000,
            serverStratum: 3,
          ),
          warmCookies: _noopWarm,
        );

        final sample = await source.fetch();

        expect(sample.source.authenticated, isTrue);
        expect(sample.source.kind, TimeSourceKind.nts);
        expect(sample.source.id, 'nts:time.cloudflare.com');
        expect(sample.source.host, 'time.cloudflare.com');
        expect(sample.source.stratum, 3);
        // T3 (1700000000123456) + RTT/2 (6000) — symmetric-path estimator
        // for UTC at the instant of receipt.
        expect(
          sample.networkUtc,
          DateTime.fromMicrosecondsSinceEpoch(1700000000129456, isUtc: true),
        );
        expect(sample.roundTripTime, const Duration(microseconds: 12000));
        expect(sample.uncertainty, const Duration(microseconds: 6000));
      },
    );

    test(
      'forwards configured host, port, and timeout to the query function',
      () async {
        NtsServerSpec? receivedSpec;
        int? receivedTimeoutMs;
        final source = NtsSource(
          'nts.example.org',
          port: 4461,
          timeout: const Duration(milliseconds: 1500),
          burstSize: 1,
          burstSpacing: Duration.zero,
          clock: _FakeMonotonicClock(0),
          query: ({required spec, required timeoutMs}) async {
            receivedSpec = spec;
            receivedTimeoutMs = timeoutMs;
            return _sample();
          },
          warmCookies: _noopWarm,
        );

        await source.fetch();

        expect(receivedSpec?.host, 'nts.example.org');
        expect(receivedSpec?.port, 4461);
        expect(receivedTimeoutMs, 1500);
      },
    );

    test('default port is the IANA NTS-KE port (4460)', () async {
      NtsServerSpec? receivedSpec;
      final source = NtsSource(
        'nts.example.org',
        burstSize: 1,
        burstSpacing: Duration.zero,
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async {
          receivedSpec = spec;
          return _sample();
        },
        warmCookies: _noopWarm,
      );

      await source.fetch();

      expect(receivedSpec?.port, 4460);
    });

    test('clock filter selects the lowest-RTD sample from a burst', () async {
      // Burst of 4 samples with RTDs varying across an order of magnitude.
      // Sample index 2 (the 5000us one) should win.
      final rtds = [25000, 18000, 5000, 12000];
      final utcs = [
        1700000000000000,
        1700000000010000,
        1700000000020000,
        1700000000030000,
      ];
      var i = 0;
      final source = NtsSource(
        'nts.example.org',
        burstSize: 4,
        burstSpacing: Duration.zero,
        clock: _ScriptedMonotonicClock([100, 200, 300, 400]),
        query: ({required spec, required timeoutMs}) async {
          final s = _sample(
            roundTripMicros: rtds[i],
            utcUnixMicros: utcs[i],
            serverStratum: 2 + i,
          );
          i++;
          return s;
        },
        warmCookies: _noopWarm,
      );

      final sample = await source.fetch();

      expect(sample.roundTripTime, const Duration(microseconds: 5000));
      expect(sample.uncertainty, const Duration(microseconds: 2500));
      // T3 (1700000000020000) + RTT/2 (2500) for the selected sample.
      expect(
        sample.networkUtc,
        DateTime.fromMicrosecondsSinceEpoch(1700000000022500, isUtc: true),
      );
      // The selected sample's stratum (index 2) carries through.
      expect(sample.source.stratum, 4);
      expect(sample.source.authenticated, isTrue);
    });

    test(
      'captured monotonic anchor matches the selected sample, not the last',
      () async {
        // Lowest-RTD sample is index 1; its monotonic capture is 200ms.
        // Monotonic readings happen *after* each query, so the anchor
        // forwarded must be the 2nd reading, not the 4th (last).
        final rtds = [9000, 4000, 11000, 7000];
        var i = 0;
        final clock = _ScriptedMonotonicClock([100, 200, 300, 400]);
        final source = NtsSource(
          'nts.example.org',
          burstSize: 4,
          burstSpacing: Duration.zero,
          clock: clock,
          query: ({required spec, required timeoutMs}) async {
            final s = _sample(roundTripMicros: rtds[i]);
            i++;
            return s;
          },
          warmCookies: _noopWarm,
        );

        final sample = await source.fetch();

        expect(sample.capturedMonotonicMs, 200);
        // All 4 monotonic reads happened (one per successful query).
        expect(clock.reads, [100, 200, 300, 400]);
      },
    );

    test(
      'tolerates partial failures and selects best surviving sample',
      () async {
        // 4-sample burst: indices 0 and 2 fail; surviving samples are
        // index 1 (RTD 9000us) and index 3 (RTD 5000us). Index 3 wins.
        final results = <NtsTimeSample?>[
          null, // throw
          _sample(roundTripMicros: 9000, utcUnixMicros: 1700000000000001),
          null, // throw
          _sample(roundTripMicros: 5000, utcUnixMicros: 1700000000000003),
        ];
        var i = 0;
        final source = NtsSource(
          'flaky.example.org',
          burstSize: 4,
          burstSpacing: Duration.zero,
          clock: _ScriptedMonotonicClock([100, 200]),
          query: ({required spec, required timeoutMs}) async {
            final r = results[i++];
            if (r == null) throw const NtsError.timeout();
            return r;
          },
          warmCookies: _noopWarm,
        );

        final sample = await source.fetch();

        expect(sample.roundTripTime, const Duration(microseconds: 5000));
        // T3 (1700000000000003) + RTT/2 (2500) for the selected sample.
        expect(
          sample.networkUtc,
          DateTime.fromMicrosecondsSinceEpoch(1700000000002503, isUtc: true),
        );
      },
    );

    test('throws the last NtsError when every burst query fails', () async {
      var calls = 0;
      final errors = <NtsError>[
        const NtsError.network('first'),
        const NtsError.network('second'),
        const NtsError.timeout(),
      ];
      final source = NtsSource(
        'broken.example.org',
        burstSize: 3,
        burstSpacing: Duration.zero,
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async {
          throw errors[calls++];
        },
        warmCookies: _noopWarm,
      );

      await expectLater(source.fetch(), throwsA(isA<NtsError_Timeout>()));
      expect(calls, 3);
    });

    test('pre-warms cookies once before the burst begins', () async {
      var warmCalls = 0;
      var queryCalls = 0;
      final order = <String>[];
      final source = NtsSource(
        'nts.example.org',
        burstSize: 3,
        burstSpacing: Duration.zero,
        clock: _ScriptedMonotonicClock([1, 2, 3]),
        query: ({required spec, required timeoutMs}) async {
          queryCalls++;
          order.add('query');
          return _sample();
        },
        warmCookies: ({required spec, required timeoutMs}) async {
          warmCalls++;
          order.add('warm');
          return 8;
        },
      );

      await source.fetch();

      expect(warmCalls, 1);
      expect(queryCalls, 3);
      expect(order, ['warm', 'query', 'query', 'query']);
    });

    test('a failing pre-warm does not abort the burst', () async {
      var queryCalls = 0;
      final source = NtsSource(
        'nts.example.org',
        burstSize: 2,
        burstSpacing: Duration.zero,
        clock: _ScriptedMonotonicClock([1, 2]),
        query: ({required spec, required timeoutMs}) async {
          queryCalls++;
          return _sample(roundTripMicros: 6000);
        },
        warmCookies: ({required spec, required timeoutMs}) async =>
            throw const NtsError.network('warm refused'),
      );

      final sample = await source.fetch();

      expect(queryCalls, 2);
      expect(sample.source.authenticated, isTrue);
    });

    test('non-NtsError exceptions are not caught by the burst loop', () async {
      // A clock failure must surface immediately rather than being
      // silently retried — the burst loop only tolerates NtsError.
      final source = NtsSource(
        'nts.example.org',
        burstSize: 4,
        burstSpacing: Duration.zero,
        clock: _ScriptedMonotonicClock([]), // RangeError on first read
        query: ({required spec, required timeoutMs}) async => _sample(),
        warmCookies: _noopWarm,
      );

      await expectLater(source.fetch(), throwsA(isA<RangeError>()));
    });

    test('networkUtc adds half-RTT to T3 (symmetric-path estimator)', () async {
      // The Rust layer returns the raw server transmit timestamp T3 plus
      // the wall-clock RTT (T4-T1). The source must forward UTC-at-receipt
      // = T3 + RTT/2 so the engine can pin it to capturedMonotonicMs (≈T4)
      // without systematic underestimate. Integer division truncates
      // toward zero; an odd RTT loses sub-microsecond precision (well
      // below NTP's measurement floor and acceptable for a uint anchor).
      final cases = <({int t3, int rtt, int expectedUtc})>[
        (t3: 1700000000000000, rtt: 8000, expectedUtc: 1700000000004000),
        (t3: 1700000000000000, rtt: 1, expectedUtc: 1700000000000000),
        (t3: 1700000000000000, rtt: 9999, expectedUtc: 1700000000004999),
        (t3: 1700000000000000, rtt: 0, expectedUtc: 1700000000000000),
      ];
      for (final c in cases) {
        final source = NtsSource(
          'nts.example.org',
          burstSize: 1,
          burstSpacing: Duration.zero,
          clock: _FakeMonotonicClock(0),
          query: ({required spec, required timeoutMs}) async =>
              _sample(utcUnixMicros: c.t3, roundTripMicros: c.rtt),
          warmCookies: _noopWarm,
        );
        final sample = await source.fetch();
        expect(
          sample.networkUtc.microsecondsSinceEpoch,
          c.expectedUtc,
          reason: 'T3=${c.t3} RTT=${c.rtt} should yield T3 + RTT~/2',
        );
      }
    });
  });
}
