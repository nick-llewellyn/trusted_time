// Real-client-path coverage for NtsSource's Duration-based timeout
// handling.
//
// nts_source_test.dart scripts outcomes via debugQueryOverride, which
// bypasses nts.NtsClient entirely — leaving getTime()'s client
// minting, the maxLatency -> query(timeout:) forwarding, and the
// wrapper's FFI error conversion without unit coverage. This file
// initializes the bridge with a recording NtsRustLibApi stub so
// getTime() runs through the real nts.NtsClient wrapper down to the
// FFI boundary, where the forwarded arguments (notably the
// millisecond timeout) can be asserted.
//
// Bridge init is one-way per isolate (initMock throws on double-init,
// MonotonicClock.instance latches), and an initialized bridge pins
// the receipt timeline to this stub's frozen clock — which would
// break nts_source_test.dart's elapsed-receipt assertions — so this
// lives in its own file, the same pattern as nts_bridge_mode_test.dart.
//
// NtsRustLibApi and the FFI DTOs are intentionally not in nts's
// public barrel; stubbing them requires the implementation imports
// below — the same pattern as package:nts's own
// example/lib/src/mock_api.dart.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:nts/src/ffi/api/nts.dart' as ffi;
import 'package:nts/src/ffi/frb_generated.dart' show NtsRustLibApi;
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/sources/nts_source.dart';

/// One FFI-boundary invocation of query/warmCookies, as decoded from
/// the arguments the wrapper actually forwarded.
typedef _FfiCall = ({
  String host,
  int port,
  int timeoutMs,
  int dnsConcurrencyCap,
});

ffi.PhaseTimings _ffiTimings() => const ffi.PhaseTimings(
  dnsMicros: 0,
  connectMicros: 0,
  tlsHandshakeMicros: 0,
  keRecordIoMicros: 0,
);

/// Fixture: a raw FFI-layer query result. The wrapper converts this
/// to the public NtsTimeSample shape before NtsSource sees it.
///
/// The 7.1 clock-filter and receipt-stamp fields are pinned to `0` —
/// the documented "not available" sentinels — so the wrapper takes
/// the pre-7.1 fallback paths (round-trip delay compensation,
/// post-await anchor). This test asserts argument forwarding at the
/// FFI boundary, not delay-compensation arithmetic.
ffi.NtsTimeSample _ffiSample({
  int roundTripMicros = 30000,
  int utcUnixMicros = 1000000000000,
  int serverStratum = 2,
}) => ffi.NtsTimeSample(
  utcUnixMicros: utcUnixMicros,
  roundTripMicros: roundTripMicros,
  serverStratum: serverStratum,
  aeadId: 15,
  freshCookies: 2,
  phaseTimings: _ffiTimings(),
  trustBackend: ffi.TrustBackend.webpkiRoots,
  recvBoottimeMicros: 0,
  offsetMicros: 0,
  peerDelayMicros: 0,
  rootDelayMicros: 0,
  rootDispersionMicros: 0,
  serverPrecision: 0,
);

ffi.NtsWarmCookiesOutcome _ffiWarmOutcome() => ffi.NtsWarmCookiesOutcome(
  freshCookies: 8,
  phaseTimings: _ffiTimings(),
  trustBackend: ffi.TrustBackend.webpkiRoots,
);

/// Recording bridge API: captures the arguments query/warmCookies
/// arrive with at the FFI boundary and answers with scripted
/// behaviour. Everything unscripted throws so an unexpected FFI touch
/// fails loudly instead of silently returning garbage.
final class _RecordingNtsApi implements NtsRustLibApi {
  int clientsMinted = 0;
  final List<_FfiCall> queryCalls = [];
  final List<_FfiCall> warmCalls = [];

  /// Scripted per-attempt query behaviour; the argument is the
  /// 0-based dispatch index across the whole test.
  Future<ffi.NtsTimeSample> Function(int attempt)? onQuery;

  /// Scripted warmCookies behaviour; defaults to a successful warm.
  Future<ffi.NtsWarmCookiesOutcome> Function()? onWarm;

  void reset() {
    clientsMinted = 0;
    queryCalls.clear();
    warmCalls.clear();
    onQuery = null;
    onWarm = null;
  }

  /// Static timeline: the receipt clock in getTime() rides this stub
  /// once the bridge is initialized; no test here asserts elapsed
  /// receipt time, so a frozen origin keeps things deterministic.
  @override
  int crateApiNtsNtsBoottimeMicros() => 0;

  @override
  ffi.NtsClient crateApiNtsNtsClientNew() {
    clientsMinted++;
    return _FakeFfiNtsClient(this);
  }

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsClientQuery({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    final attempt = queryCalls.length;
    queryCalls.add((
      host: spec.host,
      port: spec.port,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    ));
    final query = onQuery;
    if (query == null) {
      throw StateError(
        '_RecordingNtsApi: query dispatched but onQuery is unset — '
        'script the attempt behaviour before calling getTime()',
      );
    }
    return query(attempt);
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> crateApiNtsNtsClientWarmCookies({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    warmCalls.add((
      host: spec.host,
      port: spec.port,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
    ));
    final warm = onWarm;
    return warm != null ? warm() : Future.value(_ffiWarmOutcome());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '_RecordingNtsApi: ${invocation.memberName} not stubbed',
  );
}

/// In-memory stand-in for the FFI-side NtsClient opaque handle. Each
/// method forwards back to the recording API so it observes the call
/// exactly as the real NtsClientImpl would have routed it — the same
/// pattern as package:nts's example mock_api.dart.
final class _FakeFfiNtsClient implements ffi.NtsClient {
  _FakeFfiNtsClient(this._api);

  final _RecordingNtsApi _api;
  bool _disposed = false;

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('_FakeFfiNtsClient: used after dispose()');
    }
  }

  @override
  Future<ffi.NtsTimeSample> query({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    _checkNotDisposed();
    return _api.crateApiNtsNtsClientQuery(
      that: this,
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
      verificationTimeMs: verificationTimeMs,
    );
  }

  @override
  Future<ffi.NtsWarmCookiesOutcome> warmCookies({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    _checkNotDisposed();
    return _api.crateApiNtsNtsClientWarmCookies(
      that: this,
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
      verificationTimeMs: verificationTimeMs,
    );
  }

  @override
  void dispose() => _disposed = true;

  @override
  bool get isDisposed => _disposed;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '_FakeFfiNtsClient: ${invocation.memberName} not stubbed',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = _RecordingNtsApi();

  setUpAll(() => nts.NtsRustLib.initMock(api: api));

  setUp(api.reset);

  group('NtsSource timeout forwarding (real client path)', () {
    test('maxLatency reaches the FFI boundary as whole milliseconds', () async {
      // Non-default port so the spec-forwarding assertion cannot be
      // satisfied by an accidentally hard-coded default.
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource(
        'time.example',
        port: 4461,
        maxLatency: const Duration(milliseconds: 1500),
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 30);
      expect(api.queryCalls, hasLength(1));
      expect(api.queryCalls.single.timeoutMs, 1500);
      expect(api.queryCalls.single.host, 'time.example');
      expect(api.queryCalls.single.port, 4461);
    });

    test('default maxLatency forwards the documented 5 s budget', () async {
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource('time.example');

      await source.getTime();
      expect(api.queryCalls.single.timeoutMs, 5000);
    });

    test('sub-millisecond remainder rounds up, never down', () async {
      // The wrapper's Duration -> ms conversion rounds up so a live
      // sub-ms budget is never truncated to a dead one. 1500µs must
      // arrive as 2ms, not 1ms.
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource(
        'time.example',
        maxLatency: const Duration(microseconds: 1500),
      );

      await source.getTime();
      expect(api.queryCalls.single.timeoutMs, 2);
    });

    test('the burst shares one maxLatency budget as a shrinking '
        'deadline', () async {
      // Attempts run sequentially against a single shared budget: the
      // first attempt carries the full maxLatency verbatim, and each
      // later attempt carries only the remaining balance.
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource(
        'time.example',
        maxLatency: const Duration(milliseconds: 750),
        burstCount: 3,
      );

      await source.getTime();
      expect(api.queryCalls, hasLength(3));
      expect(api.queryCalls.first.timeoutMs, 750);
      for (final call in api.queryCalls.skip(1)) {
        expect(call.timeoutMs, lessThanOrEqualTo(750));
        expect(call.timeoutMs, greaterThanOrEqualTo(1));
      }
    });

    test('sub-1ms zero Duration is rejected by the wrapper validator '
        'as NtsErrorInvalidSpec', () async {
      // Duration.zero is below the wrapper's 1 ms floor; the range
      // validator fires before any FFI dispatch, so the recording
      // stub must never observe a query.
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource('time.example', maxLatency: Duration.zero);

      await expectLater(
        source.getTime(),
        throwsA(isA<nts.NtsErrorInvalidSpec>()),
      );
      expect(api.queryCalls, isEmpty);
    });
  });

  group('NtsSource timeout error propagation (real client path)', () {
    test('FFI timeout surfaces as public NtsErrorTimeout with its '
        'phase intact', () async {
      // The wrapper converts the FFI-layer freezed NtsError_Timeout
      // into the public NtsErrorTimeout; NtsSource's phase-based
      // classification depends on that conversion preserving phase.
      api.onQuery = (_) async => throw const ffi.NtsError.timeout(
        phase: ffi.TimeoutPhase.connect,
        trustBackend: ffi.TrustBackend.webpkiRoots,
      );
      final source = NtsSource('time.example');

      await expectLater(
        source.getTime(),
        throwsA(
          isA<nts.NtsErrorTimeout>().having(
            (e) => e.phase,
            'phase',
            nts.TimeoutPhase.connect,
          ),
        ),
      );
    });

    test('dnsSaturation timeout from the FFI boundary is classified '
        'transient', () async {
      // End-to-end version of the debugQueryOverride-based test in
      // nts_source_test.dart: the transient classification must hold
      // when the phase arrives through the wrapper's conversion.
      api.onQuery = (_) async => throw const ffi.NtsError.timeout(
        phase: ffi.TimeoutPhase.dnsSaturation,
        trustBackend: ffi.TrustBackend.webpkiRoots,
      );
      final source = NtsSource('time.example');

      await expectLater(source.getTime(), throwsA(isA<TransientSourceError>()));
    });

    test('burst recovers when a timed-out attempt has a successful '
        'sibling', () async {
      api.onQuery = (attempt) async {
        if (attempt == 0) {
          throw const ffi.NtsError.timeout(
            phase: ffi.TimeoutPhase.ntp,
            trustBackend: ffi.TrustBackend.webpkiRoots,
          );
        }
        return _ffiSample(roundTripMicros: 47000);
      };
      final source = NtsSource('time.example', burstCount: 2);

      final sample = await source.getTime();
      expect(sample.delayMs, 47);
      expect(api.queryCalls, hasLength(2));
    });
  });

  group('NtsSource warm path (real client path)', () {
    test('warm() forwards the package-default warm timeout, not '
        'maxLatency', () async {
      // NtsSource.warm intentionally omits a timeout argument: the
      // handshake runs in the engine's warming phase outside the
      // per-query maxLatency budget, so it inherits kDefaultTimeout.
      final source = NtsSource(
        'time.example',
        maxLatency: const Duration(milliseconds: 250),
      );

      await source.warm();
      expect(api.warmCalls, hasLength(1));
      expect(
        api.warmCalls.single.timeoutMs,
        nts.kDefaultTimeout.inMilliseconds,
      );
      // warm() swallows exceptions, so an unexpected query dispatch
      // (onQuery is unset here) would be silently absorbed rather
      // than failing the test — assert none happened explicitly.
      expect(api.queryCalls, isEmpty);
    });

    test('warm failure is swallowed and getTime still queries with '
        'its own budget', () async {
      api.onWarm = () async => throw const ffi.NtsError.timeout(
        phase: ffi.TimeoutPhase.tls,
        trustBackend: ffi.TrustBackend.webpkiRoots,
      );
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource(
        'time.example',
        maxLatency: const Duration(milliseconds: 900),
      );

      final sample = await source.getTime();
      expect(sample.delayMs, 30);
      expect(api.warmCalls, hasLength(1));
      expect(api.queryCalls.single.timeoutMs, 900);
    });

    test('one client is minted per source across warm and burst', () async {
      api.onQuery = (_) async => _ffiSample();
      final source = NtsSource('time.example', burstCount: 2);

      await source.warm();
      await source.getTime();
      expect(api.clientsMinted, 1);
    });
  });
}
