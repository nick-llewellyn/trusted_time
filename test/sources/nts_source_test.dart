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

void main() {
  group('NtsSource', () {
    test('id is namespaced by host', () {
      final source = NtsSource(
        'time.cloudflare.com',
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async => _sample(),
      );
      expect(source.id, 'nts:time.cloudflare.com');
    });

    test('successful sample is marked authenticated and carries stratum',
        () async {
      final clock = _FakeMonotonicClock(123456);
      final source = NtsSource(
        'time.cloudflare.com',
        clock: clock,
        query: ({required spec, required timeoutMs}) async => _sample(
          utcUnixMicros: 1700000000123456,
          roundTripMicros: 12000,
          serverStratum: 3,
        ),
      );

      final sample = await source.fetch();

      expect(sample.source.authenticated, isTrue);
      expect(sample.source.kind, TimeSourceKind.nts);
      expect(sample.source.id, 'nts:time.cloudflare.com');
      expect(sample.source.host, 'time.cloudflare.com');
      expect(sample.source.stratum, 3);
      expect(sample.networkUtc,
          DateTime.fromMicrosecondsSinceEpoch(1700000000123456, isUtc: true));
      expect(sample.roundTripTime, const Duration(microseconds: 12000));
      expect(sample.uncertainty, const Duration(microseconds: 6000));
    });

    test('captures monotonic uptime exactly once after the response',
        () async {
      final clock = _FakeMonotonicClock(987654);
      final source = NtsSource(
        'nts.netnod.se',
        clock: clock,
        query: ({required spec, required timeoutMs}) async => _sample(),
      );

      final sample = await source.fetch();

      expect(clock.callCount, 1);
      expect(sample.capturedMonotonicMs, 987654);
    });

    test('forwards configured host, port, and timeout to the query function',
        () async {
      NtsServerSpec? receivedSpec;
      int? receivedTimeoutMs;
      final source = NtsSource(
        'nts.example.org',
        port: 4461,
        timeout: const Duration(milliseconds: 1500),
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async {
          receivedSpec = spec;
          receivedTimeoutMs = timeoutMs;
          return _sample();
        },
      );

      await source.fetch();

      expect(receivedSpec?.host, 'nts.example.org');
      expect(receivedSpec?.port, 4461);
      expect(receivedTimeoutMs, 1500);
    });

    test('default port is the IANA NTS-KE port (4460)', () async {
      NtsServerSpec? receivedSpec;
      final source = NtsSource(
        'nts.example.org',
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async {
          receivedSpec = spec;
          return _sample();
        },
      );

      await source.fetch();

      expect(receivedSpec?.port, 4460);
    });

    test('propagates errors thrown by the query function', () async {
      final source = NtsSource(
        'broken.example.org',
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async =>
            throw const NtsError.network('connection refused'),
      );

      await expectLater(source.fetch(), throwsA(isA<NtsError>()));
    });

    test('propagates timeout errors from the query function', () async {
      final source = NtsSource(
        'slow.example.org',
        clock: _FakeMonotonicClock(0),
        query: ({required spec, required timeoutMs}) async =>
            throw const NtsError.timeout(),
      );

      await expectLater(source.fetch(), throwsA(isA<NtsError>()));
    });
  });
}
