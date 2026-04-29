@TestOn('vm')
@Tags(['network'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/sources/nts_source_io.dart';

/// Live NTS integration test. Tagged `network`; skipped by default
/// because it requires outbound TCP/4460 + UDP/123 connectivity and the
/// `package:nts` native bridge.
///
/// To run locally:
/// ```
/// fvm flutter test --tags network test/integration/nts_live_test.dart
/// ```
void main() {
  group('NtsSource (live)', () {
    test(
      'returns an authenticated sample from time.cloudflare.com',
      () async {
        final source = NtsSource('time.cloudflare.com');
        final sample = await source.fetch();

        expect(sample.source.authenticated, isTrue);
        expect(sample.source.kind, TimeSourceKind.nts);
        expect(sample.source.host, 'time.cloudflare.com');
        expect(sample.networkUtc.isAfter(DateTime.utc(2025)), isTrue);
        expect(sample.roundTripTime.inSeconds, lessThan(5));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'returns an authenticated sample from nts.netnod.se',
      () async {
        final source = NtsSource('nts.netnod.se');
        final sample = await source.fetch();

        expect(sample.source.authenticated, isTrue);
        expect(sample.source.kind, TimeSourceKind.nts);
        expect(sample.networkUtc.isAfter(DateTime.utc(2025)), isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
