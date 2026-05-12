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
  ///   authenticated end-to-end. Loses visibility into MDM/user
  ///   roots; this is the silent-fallback path that
  ///   [TrustedTimeConfig.ntsTrustMode] = `platformOnly` refuses.
  ///
  /// Per-sample observability is the read-only counterpart to
  /// `ntsTrustMode`: `ntsTrustMode` lets a deployment make the
  /// silent fallback a hard error; `trustBackend` lets a deployment
  /// see the silent fallback after the fact even when it is
  /// permitted.
  final nts.TrustBackend? trustBackend;

  /// Helper to get the UTC time (midpoint of the interval).
  DateTime get utc =>
      DateTime.fromMillisecondsSinceEpoch(interval.midpoint, isUtc: true);

  /// Helper to get the uncertainty in milliseconds.
  int get uncertaintyMs => interval.width ~/ 2;

  @override
  String toString() {
    final backend = trustBackend == null
        ? ''
        : ', backend: ${trustBackend!.name}';
    return 'TimeSample(interval: $interval, from: $sourceId, group: $groupId$backend)';
  }
}
