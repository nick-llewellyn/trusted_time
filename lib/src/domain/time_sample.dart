import 'package:flutter/foundation.dart';
import 'package:nts/nts.dart' as nts;
import '../../trusted_time.dart';

/// Represents a single time measurement from a remote authority.
/// Combines the mathematical [interval] with telemetry [sourceId] and [groupId].
@immutable
final class TimeSample {
  /// Creates a new [TimeSample] with the provided interval and source metadata.
  const TimeSample({
    required this.interval,
    required this.sourceId,
    required this.groupId,
    this.authLevel = NtsAuthLevel.none,
    this.trustBackend,
    this.delayMs,
    this.dispersionMs = 0,
  });

  /// The mathematical time interval.
  final TimeInterval interval;

  /// Unique identifier of the source (e.g., 'ntp:time.google.com').
  final String sourceId;

  /// Group identifier to detect correlated sources (e.g., ASN, provider, or region).
  final String groupId;

  /// The authentication level achieved for this specific sample.
  final NtsAuthLevel authLevel;

  /// Trust-anchor backend that authenticated the TLS chain for this
  /// sample, if applicable.
  ///
  /// Always `null` for non-NTS samples (NTP, HTTPS) — they do not run
  /// `rustls-platform-verifier` and have no equivalent concept. For
  /// NTS samples this is the value `package:nts` returned on
  /// `NtsTimeSample.trustBackend` for the handshake that produced the
  /// sample, surfaced unchanged so telemetry consumers
  /// ([SyncObserver.onSampleReceived], the example app's terminal
  /// log, BenchmarkLogger session rows) can distinguish:
  ///
  /// - [nts.TrustBackend.platform] — `rustls-platform-verifier`
  ///   against the OS trust store. The only path that honours
  ///   pinned corporate CAs and MDM/user-installed roots.
  /// - [nts.TrustBackend.platformWithHybridFallback] — Android-only;
  ///   the platform verifier ran but its result was overridden by
  ///   the bundled `webpki-roots` static bundle for one of the
  ///   curated platform-failure shapes (e.g. missing-OCSP-AIA
  ///   chains such as Let's Encrypt R12).
  /// - [nts.TrustBackend.webpkiRoots] — the static bundle
  ///   authenticated end-to-end. This is the backend the default
  ///   [nts.TrustMode.bundledOnly] posture produces; it has no
  ///   visibility into MDM/user-installed roots by design.
  /// - [nts.TrustBackend.custom] — a caller-supplied root from
  ///   [TrustedTimeConfig.customRootCerts] authenticated the chain
  ///   ([nts.TrustMode.custom]). The anchor set is fully
  ///   caller-controlled — no platform-store or bundled-roots
  ///   consultation — so it is the on-premise / private-CA
  ///   counterpart to `webpkiRoots`.
  ///
  /// Per-sample observability is the read-only counterpart to the
  /// [TrustedTimeConfig] trust policy: [TrustedTimeConfig.usePlatformTrust]
  /// and [TrustedTimeConfig.customRootCerts] choose which backend the
  /// engine is willing to use up front; `trustBackend` reports which
  /// one each individual handshake actually resolved to.
  final nts.TrustBackend? trustBackend;

  /// The round-trip delay `δ` for this sample, in milliseconds — the
  /// whole measured RTT, not the half-width. Null when the source did
  /// not measure a round trip, in which case [rootDistanceMs] falls
  /// back to the interval half-width for the `δ/2` term.
  final int? delayMs;

  /// The dispersion `E` for this sample, in milliseconds — accumulated
  /// or estimated error contributed independently of the round trip.
  /// Defaults to `0` when a source has no dispersion estimate, so
  /// legacy callers and test fixtures are unaffected.
  final int dispersionMs;

  /// Helper to get the UTC time (midpoint of the interval).
  DateTime get utc =>
      DateTime.fromMillisecondsSinceEpoch(interval.midpoint, isUtc: true);

  /// Helper to get the uncertainty in milliseconds.
  int get uncertaintyMs => interval.width ~/ 2;

  /// NTPv4 root distance: `Λ = E + δ/2` (dispersion plus half the
  /// round-trip delay). Lower is better.
  ///
  /// Falls back to the interval half-width for the `δ/2` term when
  /// [delayMs] is unset, so the metric is always defined — including
  /// for fixtures that only specify an interval.
  int get rootDistanceMs =>
      dispersionMs + (delayMs == null ? interval.width ~/ 2 : delayMs! ~/ 2);

  @override
  String toString() {
    final backend = trustBackend == null
        ? ''
        : ', backend: ${trustBackend!.name}';
    return 'TimeSample(interval: $interval, from: $sourceId, group: $groupId$backend)';
  }
}
