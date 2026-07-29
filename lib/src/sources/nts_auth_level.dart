import 'package:nts/nts.dart' as nts;

/// Authentication levels for NTS queries.
///
/// **Migration note (v2.0.3 → v2.1.0)**: `NtsAuthLevel.advisory` has been
/// removed. It was deprecated in v2.0.3 when the implementation migrated to
/// `package:nts` (RFC 8915-compliant Rust backend). Any exhaustive `switch`
/// or `if` branch that handled `.advisory` must be deleted; the case is no
/// longer reachable. Code that previously treated `.advisory` as a weak-auth
/// signal should instead rely on [NtsAuthLevel.none] for unauthenticated
/// sources and [NtsAuthLevel.verified] for cryptographically authenticated
/// ones.
enum NtsAuthLevel {
  /// No authentication performed (plain NTP or custom sources).
  none,

  /// Full RFC 8915 cryptographic authentication via `package:nts`.
  ///
  /// Uses a Rust-based TLS 1.3 client with proper RFC 5705 keying material
  /// exporters and AES-SIV-CMAC-256 AEAD. Provides cryptographic authenticity
  /// guarantees against on-path attackers.
  verified,
}

/// Maps the trust-anchor backend that authenticated an NTS handshake to
/// the [NtsAuthLevel] recorded on the resulting `TimeSample`.
///
/// [NtsAuthLevel.verified] is reserved for library-controlled trust
/// stores — [nts.TrustBackend.webpkiRoots] (bundled roots) and
/// [nts.TrustBackend.custom] (caller-supplied roots) — where a
/// corporate-injected or MDM-installed CA cannot reach the validation
/// path. Platform-mediated paths ([nts.TrustBackend.platform] and the
/// Android-only [nts.TrustBackend.platformWithHybridFallback]) and the
/// defensive `null` case map to [NtsAuthLevel.none]: the TLS handshake
/// succeeded, but its authenticity is not end-to-end verifiable from the
/// library, so the sample must never anchor the consensus truth box.
///
/// `platformWithHybridFallback` maps to `none` even though the bundle
/// was the authoritative anchor for that particular chain — the *path*
/// still runs through platform machinery, and the contract requires the
/// conservative classification.
///
/// Lives under `lib/src/`, so it is not part of the public API; the
/// mapping table is covered directly in `test/nts_source_test.dart`.
/// See `doc/design/tiered-trust-implementation.md` section 3.2.
NtsAuthLevel authLevelForTrustBackend(nts.TrustBackend? backend) {
  switch (backend) {
    case nts.TrustBackend.webpkiRoots:
    case nts.TrustBackend.custom:
      return NtsAuthLevel.verified;
    case nts.TrustBackend.platform:
    case nts.TrustBackend.platformWithHybridFallback:
    case null:
      return NtsAuthLevel.none;
  }
}
