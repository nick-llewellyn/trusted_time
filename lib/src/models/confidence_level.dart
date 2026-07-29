/// Qualitative grades of consensus integrity.
///
/// These levels represent the engine's confidence in the accuracy of the current
/// [TrustAnchor] based on population depth, provider diversity, and variance.
enum ConfidenceLevel {
  /// The engine has not yet reached a stable quorum, or the current state
  /// has been explicitly invalidated (e.g., after an integrity violation).
  none,

  /// A consensus has been achieved, but the population depth or provider
  /// diversity is minimal (e.g., only two sources from the same network group).
  low,

  /// A stable quorum has been reached with adequate provider diversity
  /// (multiple administrative groups/protocols).
  medium,

  /// A high-integrity quorum has been reached with broad diversity across
  /// protocols (NTP, NTS) and extremely low population variance.
  high,
}
