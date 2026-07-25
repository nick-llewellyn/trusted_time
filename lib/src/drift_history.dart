/// Maximum number of boot sessions retained in the drift history ring
/// buffer. Oldest records are evicted first.
const int kMaxDriftHistoryBoots = 10;

/// A per-boot summary of observed oscillator drift.
///
/// Each record pairs the first and latest trust anchor captured within a
/// single boot session (identified by [bootId]), so the drift of the
/// device's monotonic uptime relative to network UTC can be measured
/// over the observed span. Records are pure diagnostics: they are
/// collected passively and persisted across boots so real oscillator
/// behaviour can be observed in the field.
final class DriftBootRecord {
  /// Creates an immutable per-boot drift record.
  const DriftBootRecord({
    required this.bootId,
    required this.firstUptimeMs,
    required this.firstNetworkUtcMs,
    required this.lastUptimeMs,
    required this.lastNetworkUtcMs,
    required this.anchorCount,
  });

  /// Deserializes a record from its JSON map (see [toJson]).
  ///
  /// Throws [FormatException] on missing or mistyped fields; callers
  /// that read persisted data treat that as corruption (discard).
  factory DriftBootRecord.fromJson(Map<String, dynamic> json) {
    final bootId = json['bootId'];
    final firstUptimeMs = json['firstUptimeMs'];
    final firstNetworkUtcMs = json['firstNetworkUtcMs'];
    final lastUptimeMs = json['lastUptimeMs'];
    final lastNetworkUtcMs = json['lastNetworkUtcMs'];
    final anchorCount = json['anchorCount'];
    if (bootId is! String ||
        firstUptimeMs is! int ||
        firstNetworkUtcMs is! int ||
        lastUptimeMs is! int ||
        lastNetworkUtcMs is! int ||
        anchorCount is! int) {
      throw const FormatException('Malformed DriftBootRecord JSON');
    }
    return DriftBootRecord(
      bootId: bootId,
      firstUptimeMs: firstUptimeMs,
      firstNetworkUtcMs: firstNetworkUtcMs,
      lastUptimeMs: lastUptimeMs,
      lastNetworkUtcMs: lastNetworkUtcMs,
      anchorCount: anchorCount,
    );
  }

  /// Opaque identifier of the boot session the record describes.
  final String bootId;

  /// Kernel uptime (ms) at the first anchor of this boot session.
  final int firstUptimeMs;

  /// Network-consensus UTC (ms) at the first anchor of this boot session.
  final int firstNetworkUtcMs;

  /// Kernel uptime (ms) at the latest anchor of this boot session.
  final int lastUptimeMs;

  /// Network-consensus UTC (ms) at the latest anchor of this boot session.
  final int lastNetworkUtcMs;

  /// Number of anchors recorded in this boot session (deduplicated:
  /// re-records of an identical latest pair do not count).
  final int anchorCount;

  /// Observed span between the first and latest anchor, measured on the
  /// network-UTC timeline.
  ///
  /// Clamped to [Duration.zero] when the latest observation does not
  /// sit after the first (a semantically-corrupt persisted record, or
  /// consensus UTC stepping backwards): a negative duration would
  /// contradict the "span" semantics. [observedDriftRate] already
  /// treats such non-positive deltas as unavailable.
  Duration get span {
    final deltaMs = lastNetworkUtcMs - firstNetworkUtcMs;
    return deltaMs <= 0 ? Duration.zero : Duration(milliseconds: deltaMs);
  }

  /// The signed drift rate observed over [span]:
  /// `(dUptime - dNetworkUtc) / dNetworkUtc`.
  ///
  /// Positive means the device's uptime clock runs fast relative to
  /// network UTC; negative means it runs slow. `null` when the span is
  /// not positive (fewer than two distinct anchors in this boot).
  double? get observedDriftRate {
    final dNetworkUtc = lastNetworkUtcMs - firstNetworkUtcMs;
    if (dNetworkUtc <= 0) return null;
    final dUptime = lastUptimeMs - firstUptimeMs;
    return (dUptime - dNetworkUtc) / dNetworkUtc;
  }

  /// Serializes the record for persistence. Keys mirror the field
  /// names one-to-one.
  Map<String, dynamic> toJson() => {
    'bootId': bootId,
    'firstUptimeMs': firstUptimeMs,
    'firstNetworkUtcMs': firstNetworkUtcMs,
    'lastUptimeMs': lastUptimeMs,
    'lastNetworkUtcMs': lastNetworkUtcMs,
    'anchorCount': anchorCount,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DriftBootRecord &&
        other.bootId == bootId &&
        other.firstUptimeMs == firstUptimeMs &&
        other.firstNetworkUtcMs == firstNetworkUtcMs &&
        other.lastUptimeMs == lastUptimeMs &&
        other.lastNetworkUtcMs == lastNetworkUtcMs &&
        other.anchorCount == anchorCount;
  }

  @override
  int get hashCode => Object.hash(
    bootId,
    firstUptimeMs,
    firstNetworkUtcMs,
    lastUptimeMs,
    lastNetworkUtcMs,
    anchorCount,
  );

  @override
  String toString() =>
      'DriftBootRecord(bootId: $bootId, '
      'first: ($firstUptimeMs, $firstNetworkUtcMs), '
      'last: ($lastUptimeMs, $lastNetworkUtcMs), '
      'anchorCount: $anchorCount)';
}

/// Accumulates [DriftBootRecord]s from applied trust anchors.
///
/// Pure in-memory and synchronous — persistence is driven by the engine
/// through its store. Keeps at most [kMaxDriftHistoryBoots] boot
/// sessions, evicting the oldest.
final class DriftHistoryRecorder {
  final _records = <DriftBootRecord>[];

  /// The recorded boot sessions, oldest → newest. Unmodifiable view.
  List<DriftBootRecord> get records => List.unmodifiable(_records);

  /// Records an applied anchor's `(uptimeMs, networkUtcMs)` reading.
  ///
  /// Returns `true` when the history changed, so the caller can skip
  /// redundant persistence writes. A `null` [bootId] records nothing
  /// (no session to key on — fail closed). An anchor whose reading is
  /// identical to the newest record's latest pair is deduped (warm
  /// restores re-apply the persisted anchor).
  bool recordAnchor({
    required int uptimeMs,
    required int networkUtcMs,
    required String? bootId,
  }) {
    if (bootId == null) return false;
    final newest = _records.isEmpty ? null : _records.last;
    if (newest != null && newest.bootId == bootId) {
      if (newest.lastUptimeMs == uptimeMs &&
          newest.lastNetworkUtcMs == networkUtcMs) {
        return false;
      }
      _records[_records.length - 1] = DriftBootRecord(
        bootId: newest.bootId,
        firstUptimeMs: newest.firstUptimeMs,
        firstNetworkUtcMs: newest.firstNetworkUtcMs,
        lastUptimeMs: uptimeMs,
        lastNetworkUtcMs: networkUtcMs,
        anchorCount: newest.anchorCount + 1,
      );
      return true;
    }
    _records.add(
      DriftBootRecord(
        bootId: bootId,
        firstUptimeMs: uptimeMs,
        firstNetworkUtcMs: networkUtcMs,
        lastUptimeMs: uptimeMs,
        lastNetworkUtcMs: networkUtcMs,
        anchorCount: 1,
      ),
    );
    while (_records.length > kMaxDriftHistoryBoots) {
      _records.removeAt(0);
    }
    return true;
  }

  /// Replaces the in-memory history with [records] (bootstrap load).
  ///
  /// Trims to the newest [kMaxDriftHistoryBoots] entries.
  void restore(List<DriftBootRecord> records) {
    _records
      ..clear()
      ..addAll(
        records.length > kMaxDriftHistoryBoots
            ? records.sublist(records.length - kMaxDriftHistoryBoots)
            : records,
      );
  }
}
