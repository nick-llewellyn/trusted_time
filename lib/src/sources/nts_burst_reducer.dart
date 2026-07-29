import '../domain/time_sample.dart';

/// Collapses the successful samples of one `NtsSource` query burst
/// into the single sample handed to the consensus.
///
/// Invoked with a non-empty list; every sample comes from the same
/// host within one `NtsSource.getTime` call, so cross-source
/// comparability is not a concern. The returned sample **must be one
/// of the input instances** (an element of `samples`, compared by
/// identity): `NtsSource` maps the winner back to its raw attempt to
/// attribute the server stratum, and a copied or derived instance
/// breaks that mapping — stratum reporting is then skipped for the
/// burst (asserted in debug builds).
typedef NtsBurstReducer = TimeSample Function(List<TimeSample> samples);

/// Default [NtsBurstReducer]: keeps the sample with the smallest
/// measured delay ([TimeSample.delayMs] — the network-only peer delay
/// δ for samples carrying the 7.1 clock-filter fields, else the whole
/// round trip).
///
/// The minimum measured delay is the tightest, least path-asymmetric
/// estimate in the burst — the burst-and-pick-min strategy
/// `package:nts` documents. Every sync cycle relies on this reduction:
/// each `NtsSource.getTime` call collapses its burst through it before
/// the sample reaches the consensus.
/// The comparison key is [TimeSample.delayMs] when measured, else
/// `2 × uncertaintyMs` (the interval half-width is ≈ δ/2, so doubling
/// keeps the key in delay units). For NTS samples carrying the 7.1
/// clock-filter fields, [TimeSample.delayMs] is the RFC 5905 peer
/// delay δ (round trip minus server processing time), so the key
/// excludes server-side latency and selects on pure network delay;
/// pre-7.1 samples carry the whole RTT there and reduce exactly as
/// before. All samples in a burst come from one source, so the key is
/// internally consistent even when δ is unmeasured.
TimeSample lowestRttReducer(List<TimeSample> samples) {
  assert(samples.isNotEmpty, 'reducer requires at least one sample');
  var best = samples.first;
  for (final s in samples.skip(1)) {
    if (_rttKey(s) < _rttKey(best)) best = s;
  }
  return best;
}

int _rttKey(TimeSample sample) => sample.delayMs ?? (2 * sample.uncertaintyMs);

/// Spread (max − min) of [TimeSample.delayMs] across the burst's
/// successful attempts, or null when fewer than two attempts carry a
/// measured delay.
int? burstJitterMs(List<TimeSample> samples) {
  int? minDelay;
  int? maxDelay;
  var measured = 0;
  for (final s in samples) {
    final d = s.delayMs;
    if (d == null) continue;
    measured++;
    if (minDelay == null || d < minDelay) minDelay = d;
    if (maxDelay == null || d > maxDelay) maxDelay = d;
  }
  if (measured < 2) return null;
  return maxDelay! - minDelay!;
}
