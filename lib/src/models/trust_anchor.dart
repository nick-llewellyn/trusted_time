import 'package:flutter/foundation.dart';

import '../exceptions.dart';
import '../sources/nts_auth_level.dart';
import 'confidence_level.dart';
import 'trust_anchor_contributor.dart';

@immutable
/// A hardware-anchored snapshot representing a verified network consensus.
///
/// This model acts as the "source of truth" for the engine. It links the
/// network-verified UTC time to the device's hardware monotonic clock at a
/// specific moment in time.
final class TrustAnchor {
  /// Creates a new [TrustAnchor] from network-verified time and monotonic clock measurements.
  const TrustAnchor({
    required this.networkUtcMs,
    required this.uptimeMs,
    required this.wallMs,
    required this.uncertaintyMs,
    this.authLevel = NtsAuthLevel.none,
    this.confidence = ConfidenceLevel.low,
    this.bootId,
    this.contributors = const [],
  });

  /// Deserializes a [TrustAnchor] from a JSON map with rigorous bounds checking.
  factory TrustAnchor.fromJson(Map<String, dynamic> json) {
    try {
      final confIdx = json['confidence'] as int? ?? 0;

      // CRITICAL-6: Prevent RangeError or malformed state during deserialization.
      //
      // authLevel is serialized by name (current format), a self-describing
      // encoding that survives enum changes: a verified anchor round-trips back
      // to verified rather than colliding with a legacy ordinal. Legacy v2.0.x
      // persisted it as a 3-variant ordinal (none=0, advisory=1, verified=2);
      // those int values are still decoded, with the removed advisory (1)
      // degrading to none so stale anchors never misidentify as verified.
      final rawAuth = json['authLevel'];
      final NtsAuthLevel authLevel;
      if (rawAuth is String) {
        authLevel = NtsAuthLevel.values.firstWhere(
          (v) => v.name == rawAuth,
          orElse: () => NtsAuthLevel.none,
        );
      } else if (rawAuth is int) {
        final remappedAuthIdx = rawAuth == 2 ? 1 : (rawAuth == 1 ? 0 : rawAuth);
        authLevel =
            (remappedAuthIdx >= 0 &&
                remappedAuthIdx < NtsAuthLevel.values.length)
            ? NtsAuthLevel.values[remappedAuthIdx]
            : NtsAuthLevel.none;
      } else {
        authLevel = NtsAuthLevel.none;
      }

      final confidence =
          (confIdx >= 0 && confIdx < ConfidenceLevel.values.length)
          ? ConfidenceLevel.values[confIdx]
          : ConfidenceLevel.none;

      // Contributor telemetry is diagnostic, never trust-critical: a
      // missing key (anchors persisted before the field existed) or a
      // malformed entry degrades to fewer/no contributors rather than
      // failing the whole anchor, which would discard a valid trust
      // reference over cosmetic metadata.
      final rawContributors = json['contributors'];
      var contributors = const <TrustAnchorContributor>[];
      if (rawContributors is List) {
        contributors = [
          for (final entry in rawContributors)
            if (entry is Map<String, dynamic>)
              ?TrustAnchorContributor.tryFromJson(entry),
        ];
      }

      return TrustAnchor(
        networkUtcMs: json['networkUtcMs'] as int,
        uptimeMs: json['uptimeMs'] as int,
        wallMs: json['wallMs'] as int,
        uncertaintyMs: json['uncertaintyMs'] as int,
        authLevel: authLevel,
        confidence: confidence,
        bootId: json['bootId'] as String?,
        contributors: contributors,
      );
    } catch (e) {
      throw TrustedTimePersistenceException('Malformed TrustAnchor JSON: $e');
    }
  }

  /// The UTC timestamp established by the network consensus (milliseconds).
  final int networkUtcMs;

  /// The device's monotonic uptime at the moment the consensus was reached.
  final int uptimeMs;

  /// The device's system wall-clock time at the moment the consensus was reached.
  final int wallMs;

  /// The calculated precision of the consensus (half-width of the intersection).
  final int uncertaintyMs;

  /// The common authentication level achieved by the quorum participants.
  final NtsAuthLevel authLevel;

  /// The qualitative grade of this anchor (none, low, medium, or high).
  final ConfidenceLevel confidence;

  /// Opaque identifier of the boot session this anchor was captured in,
  /// or `null` when the platform provides none.
  ///
  /// On warm restore the anchor is only honoured when this matches the
  /// device's current boot ID — identity comparison, not the uptime
  /// inequality, is what defeats the wait-out attack (reboot, then leave
  /// the device on until uptime exceeds the recorded value). Anchors
  /// without a boot ID fail closed: they are treated as rebooted.
  final String? bootId;

  /// Per-source telemetry for every sample that entered the consensus
  /// this anchor was minted from — winners and losers alike.
  ///
  /// Purely diagnostic: nothing in the trust chain reads it. It exists
  /// so an anchor documents *who* produced it (which servers, at what
  /// RTT/jitter/stratum, and whether each one's interval made the
  /// winning set), feeding source-quality refinement and the example
  /// app's telemetry views. Empty for anchors persisted before the
  /// field existed and for synthetic anchors (e.g. the background-sync
  /// probe path).
  final List<TrustAnchorContributor> contributors;

  /// Alias for [networkUtcMs].
  int get trustedUtcMs => networkUtcMs;

  /// A normalized score (0.0 to 1.0) representing the reliability of this anchor.
  double get confidenceScore {
    switch (confidence) {
      case ConfidenceLevel.none:
        return 0.0;
      case ConfidenceLevel.low:
        return 0.3;
      case ConfidenceLevel.medium:
        return 0.7;
      case ConfidenceLevel.high:
        return 1.0;
    }
  }

  /// Serializes the anchor for secure local storage.
  Map<String, dynamic> toJson() => {
    'networkUtcMs': networkUtcMs,
    'uptimeMs': uptimeMs,
    'wallMs': wallMs,
    'uncertaintyMs': uncertaintyMs,
    'authLevel': authLevel.name,
    'confidence': confidence.index,
    if (bootId != null) 'bootId': bootId,
    if (contributors.isNotEmpty)
      'contributors': [for (final c in contributors) c.toJson()],
  };
}
