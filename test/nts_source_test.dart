// NtsSource identity and reduction: how a trust backend maps to an auth
// level, how competing samples are reduced to one, and how a hostname
// becomes a group ID.
//
// Burst orchestration and interval shaping — the parts that drive
// queries and turn their results into a TimeSample — live in
// nts_source_burst_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/sources/nts_auth_level.dart';
import 'package:trusted_time/src/sources/nts_source.dart';

/// Fixture: a [TimeSample] with the given [delayMs] (nullable) and
/// half-width [uncertaintyMs].
TimeSample sampleWith({int? delayMs, int uncertaintyMs = 25, String? id}) {
  return TimeSample(
    interval: TimeInterval(
      startMs: 1000000 - uncertaintyMs,
      endMs: 1000000 + uncertaintyMs,
    ),
    sourceId: id ?? 'nts:test',
    groupId: 'g',
    delayMs: delayMs,
  );
}

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

  group('lowestRttReducer', () {
    test('single sample is returned unchanged (identity)', () {
      final s = sampleWith(delayMs: 40);
      expect(identical(lowestRttReducer([s]), s), isTrue);
    });

    test('picks the sample with the smallest measured delayMs', () {
      final fast = sampleWith(delayMs: 18, id: 'fast');
      final mid = sampleWith(delayMs: 42, id: 'mid');
      final slow = sampleWith(delayMs: 95, id: 'slow');
      expect(identical(lowestRttReducer([mid, slow, fast]), fast), isTrue);
    });

    test('null delayMs falls back to 2x uncertainty (RTT units)', () {
      // Unmeasured δ: key = 2×25 = 50 — worse than the measured 40,
      // better than the measured 60. The reducer must slot it between
      // them, proving the fallback key lives in RTT units.
      final measured40 = sampleWith(delayMs: 40, id: 'm40');
      final unmeasured = sampleWith(delayMs: null, uncertaintyMs: 25);
      final measured60 = sampleWith(delayMs: 60, id: 'm60');
      expect(
        identical(
          lowestRttReducer([unmeasured, measured60, measured40]),
          measured40,
        ),
        isTrue,
      );
      expect(
        identical(lowestRttReducer([unmeasured, measured60]), unmeasured),
        isTrue,
      );
    });

    test('first sample wins RTT ties (stable)', () {
      final a = sampleWith(delayMs: 30, id: 'a');
      final b = sampleWith(delayMs: 30, id: 'b');
      expect(identical(lowestRttReducer([a, b]), a), isTrue);
    });
  });

  group('NtsSource groupId (registrable-domain grouping)', () {
    // groupId counts administrative operators, not hostnames: every
    // regional endpoint of one operator must collapse to a single
    // group so minGroupCount cannot be satisfied from one operator.
    // Rows pin (host, expected groupId); the mini-PSL cases exercise
    // multi-label public suffixes where last-two-labels would merge
    // unrelated operators.
    const cases = <(String, String)>[
      // Plain registrable domains: last two labels.
      ('time.cloudflare.com', 'cloudflare.com'),
      ('nts.netnod.se', 'netnod.se'),
      ('gbg1.nts.netnod.se', 'netnod.se'),
      ('sth2.nts.netnod.se', 'netnod.se'),
      ('ptbtime1.ptb.de', 'ptb.de'),
      ('ptbtime4.ptb.de', 'ptb.de'),
      ('ohio.time.system76.com', 'system76.com'),
      ('brazil.time.system76.com', 'system76.com'),
      ('1.nts.nothingtohide.nl', 'nothingtohide.nl'),
      ('d.st1.ntp.br', 'ntp.br'),
      ('0.ntp.bksp.in', 'bksp.in'),
      // Mini-PSL multi-label suffixes: last three labels.
      ('ntp0.cam.ac.uk', 'cam.ac.uk'),
      ('ntp3.cam.ac.uk', 'cam.ac.uk'),
      ('ntp.neu.edu.cn', 'neu.edu.cn'),
      ('ntp1.neu.edu.cn', 'neu.edu.cn'),
      // Two or fewer labels pass through unchanged.
      ('example.com', 'example.com'),
      ('localhost', 'localhost'),
      // Host exactly at suffix+1 depth stays whole.
      ('cam.ac.uk', 'cam.ac.uk'),
      // Case is normalized.
      ('GBG1.NTS.NETNOD.SE', 'netnod.se'),
      // FQDN root dot and stray empty labels are dropped, so the
      // FQDN form groups with the plain form instead of minting a
      // malformed trailing-dot group.
      ('example.com.', 'example.com'),
      ('gbg1.nts.netnod.se.', 'netnod.se'),
      ('ntp0.cam.ac.uk.', 'cam.ac.uk'),
    ];

    for (final (host, expected) in cases) {
      test('$host -> $expected', () {
        expect(NtsSource(host).groupId, expected);
      });
    }

    test('one operator\'s regional endpoints share a single group', () {
      final netnodGroups = {
        for (final host in [
          'nts.netnod.se',
          'gbg1.nts.netnod.se',
          'lul2.nts.netnod.se',
          'mmo1.nts.netnod.se',
          'svl2.nts.netnod.se',
        ])
          NtsSource(host).groupId,
      };
      expect(netnodGroups, {'netnod.se'});
    });

    test('id retains the full hostname (unchanged by grouping)', () {
      final source = NtsSource('gbg1.nts.netnod.se');
      expect(source.id, 'nts:gbg1.nts.netnod.se');
      expect(source.groupId, 'netnod.se');
    });
  });
}
