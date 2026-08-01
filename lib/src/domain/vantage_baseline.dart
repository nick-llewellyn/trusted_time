import 'package:flutter/foundation.dart';

/// EWMA smoothing factor for the anycast RTT baseline.
///
/// Deliberately slower than the per-source tracker's 0.3. A baseline
/// exists to be the thing a shift is measured *against*, so it should
/// lag: adapting quickly would let a genuine move drag the baseline
/// along behind it and never register as a shift at all.
const double _kBaselineAlpha = 0.2;

/// Cycles of anycast observations required before a shift can fire.
///
/// One observation is a baseline of itself and can never differ from
/// it; three gives the EWMA enough to have smoothed something.
const int _kWarmupCycles = 3;

/// Anycast hosts that must have answered for a cycle to be observable.
///
/// The quorum is ten hosts. A cycle where only one or two answered is
/// measuring whichever happened to survive, not the vantage — and a
/// partial outage that systematically drops the near hosts would read
/// as a latency jump.
const int _kMinResponders = 3;

/// Consecutive out-of-band cycles required to open a new epoch.
///
/// A single congested cycle is weather. Debouncing costs one cycle of
/// detection latency and buys immunity to the transient spike, which
/// is the trade to make when the false-positive cost is a full
/// re-exploration sweep.
const int _kShiftDebounceCycles = 2;

/// Ratio between an observation and the baseline that counts as a
/// shift, applied symmetrically so a move toward the network fires on
/// the same evidence as a move away.
const double _kShiftRatio = 1.8;

/// Absolute floor, in milliseconds, on a shift.
///
/// The ratio test alone is hair-triggered at the fast end: on a 10 ms
/// baseline, an 18 ms cycle is a 1.8x "shift" and also completely
/// unremarkable. Both tests must pass.
const double _kShiftFloorMs = 40.0;

/// The smoothed anycast round-trip baseline for one vantage.
///
/// Anycast and DNS-steered hosts resolve to whatever instance is
/// nearest the caller, so the round trip to them measures the caller's
/// position in the network rather than any property of a server. When
/// that number moves sharply the device moved: intercontinental
/// travel, a VPN toggled, Wi-Fi handed over to cellular. The three are
/// indistinguishable from here and equally invalidating, so one
/// heuristic covers all of them.
///
/// RTT is used rather than a geographic signal because geography lies
/// under a VPN and lags under travel, while the round trip is measured
/// rather than asserted.
///
/// Immutable: [observe] returns the next baseline instead of mutating,
/// so the detector is a pure function of (state, observation) and the
/// caller decides whether to adopt the result.
@immutable
final class VantageBaseline {
  /// Creates a baseline; normally obtained from [observe] or
  /// [fromJson] rather than directly.
  const VantageBaseline({
    this.ewmaRttMs,
    this.observationCount = 0,
    this.pendingShiftCount = 0,
    this.epoch = 0,
  }) : assert(observationCount >= 0, 'observationCount must be non-negative'),
       assert(pendingShiftCount >= 0, 'pendingShiftCount must be non-negative'),
       assert(epoch >= 0, 'epoch must be non-negative');

  /// EWMA of the per-cycle median anycast round trip, in milliseconds,
  /// or null before the first observation.
  final double? ewmaRttMs;

  /// Observations folded in since the current epoch opened.
  final int observationCount;

  /// Consecutive observations that fell outside the shift band.
  ///
  /// Reset to zero by any in-band observation, so only a sustained
  /// departure reaches [_kShiftDebounceCycles].
  final int pendingShiftCount;

  /// How many times a vantage change has been detected on this install.
  ///
  /// Advisory and monotonic. Its only load-bearing use is inequality:
  /// a consumer comparing epochs across cycles learns that the vantage
  /// changed in between.
  final int epoch;

  /// Whether enough observations have accumulated for [observe] to be
  /// able to report a shift.
  bool get isWarm => observationCount >= _kWarmupCycles;

  /// Folds one cycle's anycast round trips into the baseline.
  ///
  /// [rttSamplesMs] is every measured round trip the quorum returned
  /// this cycle, in any order. The median is taken rather than the
  /// mean: one anycast host routed badly (or answering from an
  /// unexpectedly distant instance) should not move a ten-host
  /// reading, and the median is what makes that true without special
  /// cases.
  ///
  /// Returns the baseline unchanged when fewer than [_kMinResponders]
  /// hosts answered — an unobservable cycle must not be recorded as
  /// evidence of anything.
  ///
  /// A returned baseline whose [epoch] exceeds this one's is the
  /// vantage-change signal.
  VantageBaseline observe(Iterable<int> rttSamplesMs) {
    final samples = rttSamplesMs.where((ms) => ms >= 0).toList()..sort();
    if (samples.length < _kMinResponders) return this;
    final median = samples.length.isOdd
        ? samples[samples.length ~/ 2].toDouble()
        : (samples[samples.length ~/ 2 - 1] + samples[samples.length ~/ 2]) / 2;

    final previous = ewmaRttMs;
    if (previous == null) {
      return VantageBaseline(
        ewmaRttMs: median,
        observationCount: 1,
        epoch: epoch,
      );
    }

    if (isWarm && _isShift(previous, median)) {
      final pending = pendingShiftCount + 1;
      if (pending >= _kShiftDebounceCycles) {
        // New epoch: the old baseline described a vantage the device
        // has left, so it is replaced outright rather than smoothed
        // toward. Smoothing across the boundary would leave the
        // baseline reading a place that no longer exists for however
        // many cycles the EWMA takes to catch up, and every one of
        // those cycles would look like a further shift.
        return VantageBaseline(
          ewmaRttMs: median,
          observationCount: 1,
          epoch: epoch + 1,
        );
      }
      return VantageBaseline(
        ewmaRttMs: previous,
        observationCount: observationCount,
        pendingShiftCount: pending,
        epoch: epoch,
      );
    }

    return VantageBaseline(
      ewmaRttMs: previous * (1 - _kBaselineAlpha) + median * _kBaselineAlpha,
      observationCount: observationCount + 1,
      epoch: epoch,
    );
  }

  static bool _isShift(double baseline, double observed) {
    final hi = baseline > observed ? baseline : observed;
    final lo = baseline > observed ? observed : baseline;
    if (hi - lo < _kShiftFloorMs) return false;
    if (lo <= 0) return true;
    return hi / lo >= _kShiftRatio;
  }

  /// Serializes to a JSON-compatible map. Null fields are omitted.
  Map<String, Object?> toJson() => {
    if (ewmaRttMs != null) 'ewmaRttMs': ewmaRttMs,
    'observationCount': observationCount,
    'pendingShiftCount': pendingShiftCount,
    'epoch': epoch,
  };

  /// Deserializes a baseline, returning null when [json] is not a
  /// well-formed record.
  ///
  /// A malformed or out-of-range payload degrades to "no baseline",
  /// which costs one install its warmup rather than seeding the
  /// detector with a number that would make every subsequent cycle
  /// look like a shift.
  static VantageBaseline? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final ewmaRttMs = json['ewmaRttMs'];
    final observationCount = json['observationCount'];
    final pendingShiftCount = json['pendingShiftCount'];
    final epoch = json['epoch'];
    if (observationCount is! int || observationCount < 0) return null;
    if (pendingShiftCount is! int || pendingShiftCount < 0) return null;
    if (epoch is! int || epoch < 0) return null;
    if (ewmaRttMs != null && (ewmaRttMs is! num || ewmaRttMs < 0)) return null;
    return VantageBaseline(
      ewmaRttMs: ewmaRttMs is num ? ewmaRttMs.toDouble() : null,
      observationCount: observationCount,
      pendingShiftCount: pendingShiftCount,
      epoch: epoch,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VantageBaseline &&
          other.ewmaRttMs == ewmaRttMs &&
          other.observationCount == observationCount &&
          other.pendingShiftCount == pendingShiftCount &&
          other.epoch == epoch;

  @override
  int get hashCode =>
      Object.hash(ewmaRttMs, observationCount, pendingShiftCount, epoch);

  @override
  String toString() =>
      'VantageBaseline(rtt: $ewmaRttMs, n: $observationCount, '
      'pending: $pendingShiftCount, epoch: $epoch)';
}
