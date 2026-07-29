import '../drift_history.dart';

/// Minimum observed span (on the network-UTC timeline) before the
/// current boot's drift rate is trusted for correction: shorter
/// windows are dominated by per-anchor consensus noise rather than
/// genuine oscillator drift.
const kMinDriftCorrectionSpan = Duration(hours: 1);

/// Largest drift-rate magnitude accepted for correction: 200 ppm.
/// Real oscillators sit around 5–50 ppm, so anything beyond this
/// bound indicates corrupt or semantically-implausible persisted
/// history rather than genuine drift — and rates near or below -1
/// would make the `elapsed / (1 + rate)` projection blow up.
const kMaxDriftRateMagnitude = 0.0002;

/// Resolves the drift rate usable for correcting a projection anchored
/// in the boot session [anchorBootId], or `null` when none qualifies.
///
/// Returns the newest record's observed rate iff that record belongs to
/// [anchorBootId], its observed span crosses [kMinDriftCorrectionSpan],
/// and the rate is finite with magnitude within
/// [kMaxDriftRateMagnitude] — persisted history is only syntactically
/// validated, so a semantically-corrupt record must not reach the
/// projection. Prior boots' rates are diagnostics only, never applied
/// across a reboot, hence the boot-identity check rather than a search
/// for the newest qualifying record.
///
/// A `null` [anchorBootId] yields `null`: without a session to key on
/// there is no way to tell a same-boot record from a stale one, so the
/// correction fails closed.
///
/// [records] is expected oldest → newest, as
/// [DriftHistoryRecorder.records] supplies it; only the last entry is
/// examined.
double? currentBootDriftRate({
  required String? anchorBootId,
  required List<DriftBootRecord> records,
}) {
  if (anchorBootId == null) return null;
  if (records.isEmpty) return null;
  final newest = records.last;
  if (newest.bootId != anchorBootId) return null;
  if (newest.span < kMinDriftCorrectionSpan) return null;
  final rate = newest.observedDriftRate;
  if (rate == null || !rate.isFinite) return null;
  if (rate.abs() > kMaxDriftRateMagnitude) return null;
  return rate;
}
