import 'package:flutter/foundation.dart';

import '../sources/nts_auth_level.dart';

@immutable
/// One time source's performance in the sync cycle that minted a
/// [TrustAnchor] — the per-server line item behind the anchor's
/// consensus.
///
/// Recorded for every sample that reached the consensus engine, not
/// just the winning set: a source whose interval was excluded from the
/// intersection ([wonConsensus] false) is exactly the signal
/// source-quality refinement needs. Purely diagnostic — nothing in the
/// trust chain reads these fields.
final class TrustAnchorContributor {
  /// Creates a contributor record from one cycle's telemetry.
  const TrustAnchorContributor({
    required this.sourceId,
    required this.groupId,
    required this.rttMs,
    required this.dispersionMs,
    required this.authLevel,
    required this.wonConsensus,
    this.stratum,
    this.jitterMs,
  });

  /// Deserializes a contributor, or returns null when required fields
  /// are missing or mistyped.
  ///
  /// Null rather than throw: contributor telemetry is diagnostic, so a
  /// corrupt entry must cost only itself, never the anchor it rides in
  /// (see [TrustAnchor.fromJson]).
  static TrustAnchorContributor? tryFromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId'];
    final groupId = json['groupId'];
    final rttMs = json['rttMs'];
    final dispersionMs = json['dispersionMs'];
    final wonConsensus = json['wonConsensus'];
    final stratum = json['stratum'];
    final jitterMs = json['jitterMs'];
    if (sourceId is! String ||
        groupId is! String ||
        rttMs is! int ||
        dispersionMs is! int ||
        wonConsensus is! bool ||
        stratum is! int? ||
        jitterMs is! int?) {
      return null;
    }
    // authLevel shares TrustAnchor's by-name encoding; an unknown name
    // degrades to none, matching the anchor-level policy.
    final rawAuth = json['authLevel'];
    final authLevel = rawAuth is String
        ? NtsAuthLevel.values.firstWhere(
            (v) => v.name == rawAuth,
            orElse: () => NtsAuthLevel.none,
          )
        : NtsAuthLevel.none;
    return TrustAnchorContributor(
      sourceId: sourceId,
      groupId: groupId,
      rttMs: rttMs,
      dispersionMs: dispersionMs,
      authLevel: authLevel,
      wonConsensus: wonConsensus,
      stratum: stratum,
      jitterMs: jitterMs,
    );
  }

  /// Stable source identifier (e.g. `ntp:pool.ntp.org`,
  /// `nts:time.cloudflare.com`).
  final String sourceId;

  /// Administrative group of the source in this cycle — ASN-derived
  /// for NTP, registrable domain for NTS (see ADR 0007).
  final String groupId;

  /// Network delay δ of the winning burst attempt, in milliseconds —
  /// peer delay when the clock-filter fields were available, else the
  /// whole round trip ([TimeSample.delayMs]). When the sample carried
  /// no measured delay (custom sources, legacy fixtures), this is
  /// `2 × uncertaintyMs` (≈ RTT) instead — the same fallback key the
  /// burst reduction selects on.
  final int rttMs;

  /// Server-side error budget E = rootDelay/2 + rootDispersion, in
  /// milliseconds (the same value as [TimeSample.dispersionMs]).
  final int dispersionMs;

  /// Authentication level of the sample this source contributed.
  final NtsAuthLevel authLevel;

  /// Whether this source's interval was part of the winning
  /// intersection the anchor's UTC was derived from. False means the
  /// source answered but its interval fell outside the consensus.
  final bool wonConsensus;

  /// NTP stratum the server reported (1–15), or null when the source
  /// surfaces none.
  final int? stratum;

  /// In-cycle burst jitter (max − min network delay across the burst's
  /// successful attempts), in milliseconds; null when the burst had
  /// fewer than two successes or the source has no burst concept.
  final int? jitterMs;

  /// Serializes this contributor for storage inside
  /// [TrustAnchor.toJson].
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'groupId': groupId,
    'rttMs': rttMs,
    'dispersionMs': dispersionMs,
    'authLevel': authLevel.name,
    'wonConsensus': wonConsensus,
    if (stratum != null) 'stratum': stratum,
    if (jitterMs != null) 'jitterMs': jitterMs,
  };
}
