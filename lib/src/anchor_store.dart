import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'domain/explorer_shuffle.dart';
import 'domain/vantage_baseline.dart';
import 'drift_history.dart';
import 'models.dart';
import 'source_quality_tracker.dart';

/// Persistence contract for the engine's trust anchor and per-boot drift
/// history.
///
/// Production uses [AnchorStore] (encrypted secure storage). Unit tests
/// inject [InMemoryAnchorStorage] to exercise persistence-dependent paths
/// without touching platform channels.
abstract interface class AnchorStorage {
  /// Loads the persisted [TrustAnchor], or `null` if none is stored.
  Future<TrustAnchor?> load();

  /// Persists [anchor].
  Future<void> save(TrustAnchor anchor);

  /// Loads the persisted per-boot drift history, oldest → newest.
  ///
  /// Returns an empty list when nothing is stored or the stored data is
  /// corrupt (corruption is treated as absence — history is pure
  /// diagnostics, never worth failing a bootstrap over).
  Future<List<DriftBootRecord>> loadDriftHistory();

  /// Persists the full per-boot drift history, replacing any prior value.
  Future<void> saveDriftHistory(List<DriftBootRecord> records);

  /// Loads the persisted per-source quality stats keyed by source id.
  ///
  /// Returns an empty map when nothing is stored or the stored data is
  /// corrupt (corruption is treated as absence — stats are a ranking
  /// optimization, never worth failing a bootstrap over).
  Future<Map<String, SourceQualityStats>> loadSourceStats();

  /// Persists the per-source quality stats, replacing any prior value.
  Future<void> saveSourceStats(Map<String, SourceQualityStats> stats);

  /// Loads the persisted per-install explorer shuffle seed, or `null`
  /// when none is stored or the stored value is corrupt. A seed outside
  /// the range `ExplorerShuffle` generates counts as corrupt.
  ///
  /// A null return means "generate a fresh one", so corruption costs an
  /// install its accumulated walk order but never fails a bootstrap.
  Future<int?> loadExplorerSeed();

  /// Persists the per-install explorer shuffle seed.
  ///
  /// [seed] must satisfy `ExplorerShuffle.isValidSeed`. Implementations
  /// assert this rather than coercing: [loadExplorerSeed] rejects an
  /// out-of-range seed, so a write outside the range is a value the
  /// store would silently discard on the next read, and the caller
  /// would see a walk order that resets on every launch with nothing
  /// having failed. `ExplorerShuffle.generate` only ever produces
  /// in-range seeds, so a violation is a caller bug.
  ///
  /// Written once, at first init. Rewriting it on every launch would
  /// defeat the point: the walk order must be stable across process
  /// death, or every restart re-anchors to the same permutation prefix.
  Future<void> saveExplorerSeed(int seed);

  /// Loads how many front-loaded foreground cycles this install has
  /// left, or `null` when none is stored or the stored value is corrupt
  /// (anything that is not a non-negative integer).
  ///
  /// A null return means "arm a fresh boost", not "boost exhausted" —
  /// an exhausted boost is a stored `0`. An install upgrading from a
  /// version before the counter existed therefore gets one front-load,
  /// which is the same posture as a fresh install and costs a handful
  /// of extra explorer probes over the following cycles.
  Future<int?> loadExplorerBoostRemaining();

  /// Persists how many front-loaded foreground cycles remain.
  ///
  /// [remaining] must be non-negative; [loadExplorerBoostRemaining]
  /// treats a negative value as corrupt, so writing one would silently
  /// re-arm the boost on the next launch. Implementations enforce this
  /// with a [RangeError] in all build modes.
  ///
  /// Written only on the cycles where the count actually changes — so
  /// it stops being written entirely once the boost is spent, and a
  /// headless cycle (which never arms a front-load at start, and so
  /// holds zero unless a vantage change arms one) cannot overwrite a
  /// foreground install's remaining boost with its own zero.
  Future<void> saveExplorerBoostRemaining(int remaining);

  /// Loads the persisted anycast RTT baseline, or `null` when none is
  /// stored or the stored data is corrupt.
  ///
  /// A null return means "re-warm from cold", which costs an install
  /// the detector's warmup cycles but never fails a bootstrap. See
  /// [VantageBaseline.fromJson] for which payloads count as corrupt and
  /// why the bar is deliberately low.
  Future<VantageBaseline?> loadVantageBaseline();

  /// Persists the anycast RTT baseline, replacing any prior value.
  ///
  /// Written only on the cycles where the baseline actually moves, so
  /// an unobservable cycle — one where too few anycast hosts
  /// answered — costs no write.
  Future<void> saveVantageBaseline(VantageBaseline baseline);

  /// Wipes all persisted temporal data.
  Future<void> clear();
}

/// Encrypted persistence layer for trust anchors.
///
/// Uses [FlutterSecureStorage] (backed by Keychain on iOS, EncryptedSharedPreferences
/// on Android) to persist the [TrustAnchor] across app restarts. This allows
/// the engine to resume trusted time without a network sync after a non-reboot
/// restart.
///
/// The values stored are:
/// - The full anchor JSON (for warm-start restoration)
/// - The per-boot drift history JSON (diagnostics across boots)
/// - The per-source quality stats JSON (durable server ranking)
/// - The explorer walk seed and remaining front-load (exploration)
/// - The anycast RTT baseline JSON (vantage-change detection)
final class AnchorStore implements AnchorStorage {
  /// Hardware-backed secure storage with platform-appropriate configuration.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    wOptions: WindowsOptions(),
  );

  static const _keyAnchor = 'tt_anchor_v2';
  static const _keyDriftHistory = 'tt_drift_history_v1';
  static const _keySourceStats = 'tt_source_stats_v1';
  static const _keyExplorerSeed = 'tt_explorer_seed_v1';
  static const _keyExplorerBoost = 'tt_explorer_boost_v1';
  static const _keyVantageBaseline = 'tt_vantage_baseline_v1';

  // Legacy offline-estimation keys (removed feature). Never written or
  // read anymore; still deleted by [clear] so installs upgrading from
  // older versions don't strand stale ciphertext in secure storage.
  static const _keyLegacyLastTrustedUtcMs = 'tt_last_trusted_utc_ms';
  static const _keyLegacyLastAnchorWallMs = 'tt_last_anchor_wall_ms';

  /// Loads and decodes the persisted trust anchor, if available.
  ///
  /// Returns `null` if no anchor has been saved or if the stored data
  /// is corrupted (in which case the corrupt entry is automatically
  /// cleared).
  @override
  Future<TrustAnchor?> load() async {
    try {
      final raw = await _storage.read(key: _keyAnchor);
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return TrustAnchor.fromJson(json);
    } catch (_) {
      await _bestEffortDelete(_keyAnchor);
      return null;
    }
  }

  /// Persists the anchor JSON for warm-start restoration.
  @override
  Future<void> save(TrustAnchor anchor) async {
    final raw = jsonEncode(anchor.toJson());
    await _storage.write(key: _keyAnchor, value: raw);
  }

  /// Loads and decodes the persisted drift history, if available.
  ///
  /// Corruption is treated as absence: the corrupt entry is deleted and
  /// an empty list is returned, so a bad payload can never fail a
  /// bootstrap over pure diagnostics.
  @override
  Future<List<DriftBootRecord>> loadDriftHistory() async {
    try {
      final raw = await _storage.read(key: _keyDriftHistory);
      if (raw == null) return const [];
      final json = jsonDecode(raw) as List<dynamic>;
      return json
          .map((e) => DriftBootRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      await _bestEffortDelete(_keyDriftHistory);
      return const [];
    }
  }

  /// Deletes [key], swallowing any failure.
  ///
  /// Used to clear corrupt entries from the load paths, where corruption
  /// is treated as absence: if the cleanup delete itself throws (e.g. a
  /// [PlatformException] from secure storage), the corrupt payload just
  /// stays put until the next successful write or delete — that must not
  /// escalate into a bootstrap failure.
  static Future<void> _bestEffortDelete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Best-effort cleanup only; the caller already treats the entry
      // as absent.
    }
  }

  /// Persists the drift history as a JSON array, replacing prior data.
  @override
  Future<void> saveDriftHistory(List<DriftBootRecord> records) async {
    final raw = jsonEncode([for (final r in records) r.toJson()]);
    await _storage.write(key: _keyDriftHistory, value: raw);
  }

  /// Loads and decodes the persisted source quality stats, if available.
  ///
  /// Corruption is treated as absence: a corrupt payload is deleted and
  /// an empty map is returned. Individual malformed entries are skipped
  /// (see [SourceQualityStats.fromJson]) so one bad record costs one
  /// source's stats, not the whole map.
  @override
  Future<Map<String, SourceQualityStats>> loadSourceStats() async {
    try {
      final raw = await _storage.read(key: _keySourceStats);
      if (raw == null) return const {};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in json.entries)
          key: ?SourceQualityStats.fromJson(value),
      };
    } catch (_) {
      await _bestEffortDelete(_keySourceStats);
      return const {};
    }
  }

  /// Persists the source stats as a JSON object, replacing prior data.
  @override
  Future<void> saveSourceStats(Map<String, SourceQualityStats> stats) async {
    final raw = jsonEncode({
      for (final MapEntry(:key, :value) in stats.entries) key: value.toJson(),
    });
    await _storage.write(key: _keySourceStats, value: raw);
  }

  /// Loads the explorer shuffle seed, if available.
  ///
  /// Corruption (a non-integer payload, or a read failure) is treated as
  /// absence: the entry is deleted and `null` returned, so the caller
  /// mints a fresh seed rather than failing a bootstrap over a walk
  /// order.
  @override
  Future<int?> loadExplorerSeed() async {
    try {
      final raw = await _storage.read(key: _keyExplorerSeed);
      if (raw == null) return null;
      final seed = int.tryParse(raw);
      // Out of range counts as corrupt: Random does not specify how it
      // reduces a seed outside the generated range, so accepting one
      // would make the walk order platform-dependent.
      if (seed == null || !ExplorerShuffle.isValidSeed(seed)) {
        await _bestEffortDelete(_keyExplorerSeed);
        return null;
      }
      return seed;
    } catch (_) {
      await _bestEffortDelete(_keyExplorerSeed);
      return null;
    }
  }

  /// Persists the explorer shuffle seed.
  @override
  Future<void> saveExplorerSeed(int seed) async {
    assert(
      ExplorerShuffle.isValidSeed(seed),
      'seed $seed is outside the range loadExplorerSeed accepts',
    );
    await _storage.write(key: _keyExplorerSeed, value: '$seed');
  }

  /// Loads the remaining front-loaded foreground cycle count.
  ///
  /// Corruption (a non-integer or negative payload, or a read failure)
  /// is treated as absence: the entry is deleted and `null` returned,
  /// so the caller arms a fresh boost rather than failing a bootstrap
  /// over an exploration schedule.
  @override
  Future<int?> loadExplorerBoostRemaining() async {
    try {
      final raw = await _storage.read(key: _keyExplorerBoost);
      if (raw == null) return null;
      final remaining = int.tryParse(raw);
      if (remaining == null || remaining < 0) {
        await _bestEffortDelete(_keyExplorerBoost);
        return null;
      }
      return remaining;
    } catch (_) {
      await _bestEffortDelete(_keyExplorerBoost);
      return null;
    }
  }

  /// Persists the remaining front-loaded foreground cycle count.
  @override
  Future<void> saveExplorerBoostRemaining(int remaining) async {
    RangeError.checkNotNegative(remaining, 'remaining');
    await _storage.write(key: _keyExplorerBoost, value: '$remaining');
  }

  /// Loads the anycast RTT baseline, if available.
  ///
  /// Corruption is treated as absence: the entry is deleted and `null`
  /// returned, so the detector re-warms rather than seeding itself with
  /// a number that would make every subsequent cycle look like a shift.
  @override
  Future<VantageBaseline?> loadVantageBaseline() async {
    try {
      final raw = await _storage.read(key: _keyVantageBaseline);
      if (raw == null) return null;
      final baseline = VantageBaseline.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (baseline == null) {
        await _bestEffortDelete(_keyVantageBaseline);
        return null;
      }
      return baseline;
    } catch (_) {
      await _bestEffortDelete(_keyVantageBaseline);
      return null;
    }
  }

  /// Persists the anycast RTT baseline as JSON, replacing prior data.
  @override
  Future<void> saveVantageBaseline(VantageBaseline baseline) async {
    await _storage.write(
      key: _keyVantageBaseline,
      value: jsonEncode(baseline.toJson()),
    );
  }

  /// Wipes all persisted temporal data from secure storage.
  @override
  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _keyAnchor),
      _storage.delete(key: _keyDriftHistory),
      _storage.delete(key: _keySourceStats),
      _storage.delete(key: _keyExplorerSeed),
      _storage.delete(key: _keyExplorerBoost),
      _storage.delete(key: _keyVantageBaseline),
      _storage.delete(key: _keyLegacyLastTrustedUtcMs),
      _storage.delete(key: _keyLegacyLastAnchorWallMs),
    ]);
  }
}

/// In-memory [AnchorStorage] for tests.
///
/// Holds the anchor and drift history in plain fields so unit tests can
/// exercise persistence-dependent paths (warm restore, background sync,
/// drift-history round-trips) without platform channels or secure
/// storage.
final class InMemoryAnchorStorage implements AnchorStorage {
  TrustAnchor? _anchor;
  List<DriftBootRecord> _driftHistory = const [];
  Map<String, SourceQualityStats> _sourceStats = const {};
  int? _explorerSeed;
  int? _explorerBoostRemaining;
  VantageBaseline? _vantageBaseline;

  @override
  Future<TrustAnchor?> load() async => _anchor;

  @override
  Future<void> save(TrustAnchor anchor) async {
    _anchor = anchor;
  }

  @override
  Future<List<DriftBootRecord>> loadDriftHistory() async =>
      List.unmodifiable(_driftHistory);

  @override
  Future<void> saveDriftHistory(List<DriftBootRecord> records) async {
    _driftHistory = List.of(records);
  }

  @override
  Future<Map<String, SourceQualityStats>> loadSourceStats() async =>
      Map.unmodifiable(_sourceStats);

  @override
  Future<void> saveSourceStats(Map<String, SourceQualityStats> stats) async {
    _sourceStats = Map.of(stats);
  }

  @override
  Future<int?> loadExplorerSeed() async {
    final seed = _explorerSeed;
    // Mirrors AnchorStore: an out-of-range seed is corrupt, so it is
    // dropped rather than handed back. Without this the test double
    // would accept values production silently discards.
    if (seed == null || !ExplorerShuffle.isValidSeed(seed)) {
      _explorerSeed = null;
      return null;
    }
    return seed;
  }

  @override
  Future<void> saveExplorerSeed(int seed) async {
    assert(
      ExplorerShuffle.isValidSeed(seed),
      'seed $seed is outside the range loadExplorerSeed accepts',
    );
    _explorerSeed = seed;
  }

  // No corruption branch, unlike [loadExplorerSeed]: the write side
  // rejects a negative count at runtime, so the field can only ever
  // hold a value AnchorStore would also hand back.
  @override
  Future<int?> loadExplorerBoostRemaining() async => _explorerBoostRemaining;

  @override
  Future<void> saveExplorerBoostRemaining(int remaining) async {
    _explorerBoostRemaining = RangeError.checkNotNegative(
      remaining,
      'remaining',
    );
  }

  // No corruption branch either: VantageBaseline is immutable and its
  // constructor asserts the same invariants fromJson enforces, so a
  // held instance is one AnchorStore would also hand back.
  @override
  Future<VantageBaseline?> loadVantageBaseline() async => _vantageBaseline;

  @override
  Future<void> saveVantageBaseline(VantageBaseline baseline) async {
    _vantageBaseline = baseline;
  }

  @override
  Future<void> clear() async {
    _anchor = null;
    _driftHistory = const [];
    _sourceStats = const {};
    _explorerSeed = null;
    _explorerBoostRemaining = null;
    _vantageBaseline = null;
  }
}
