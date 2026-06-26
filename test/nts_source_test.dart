import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/sources/nts_auth_level.dart';
import 'package:trusted_time/src/sources/nts_source.dart';

void main() {
  group('authLevelForTrustBackend mapping table', () {
    // Each row pins one TrustBackend value (plus the defensive null
    // case) to the NtsAuthLevel the engine must record. `verified` is
    // reserved for library-controlled trust stores (bundled webpki
    // roots, caller-supplied custom roots); platform-mediated paths
    // degrade to `none` because a corporate-injected or MDM-installed
    // CA can reach them. See tiered-trust-implementation.md §3.2.
    const cases = <(nts.TrustBackend?, NtsAuthLevel)>[
      (nts.TrustBackend.webpkiRoots, NtsAuthLevel.verified),
      (nts.TrustBackend.custom, NtsAuthLevel.verified),
      (nts.TrustBackend.platform, NtsAuthLevel.none),
      (nts.TrustBackend.platformWithHybridFallback, NtsAuthLevel.none),
      (null, NtsAuthLevel.none),
    ];

    for (final (backend, expected) in cases) {
      test('${backend?.name ?? 'null'} -> ${expected.name}', () {
        expect(authLevelForTrustBackend(backend), expected);
      });
    }

    test('covers every TrustBackend variant (exhaustiveness guard)', () {
      // The switch in authLevelForTrustBackend is compile-time
      // exhaustive, but the five rows above are this test's source of
      // truth. If package:nts adds a TrustBackend variant, this fails
      // until that variant is added to `cases` with an explicit
      // expectation, forcing a conscious classification decision.
      final unmapped = {for (final b in nts.TrustBackend.values) b}
        ..removeAll(cases.map((c) => c.$1).whereType<nts.TrustBackend>());
      expect(
        unmapped,
        isEmpty,
        reason: 'unmapped TrustBackend variants: $unmapped',
      );
    });

    test('only bundled/custom roots map to verified', () {
      for (final backend in nts.TrustBackend.values) {
        final isLibraryControlled =
            backend == nts.TrustBackend.webpkiRoots ||
            backend == nts.TrustBackend.custom;
        expect(
          authLevelForTrustBackend(backend) == NtsAuthLevel.verified,
          isLibraryControlled,
          reason:
              '${backend.name} should '
              '${isLibraryControlled ? '' : 'not '}map to verified',
        );
      }
    });
  });
}
