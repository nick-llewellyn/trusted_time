import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'models.dart';

/// Persistence contract for the engine's trust anchor and offline-estimation
/// timestamps.
///
/// Production uses [AnchorStore] (encrypted secure storage). Unit tests
/// inject [InMemoryAnchorStorage] to exercise the engine's bootstrap and
/// warm-restore paths without touching platform channels.
abstract interface class AnchorStorage {
  /// Loads the persisted [TrustAnchor], or `null` if none is stored.
  Future<TrustAnchor?> load();

  /// Persists [anchor] alongside last-known timestamps for offline use.
  Future<void> save(TrustAnchor anchor);

  /// Loads the last-known UTC + wall-clock timestamps for offline
  /// estimation, independent of the full anchor payload.
  Future<({int trustedUtcMs, int wallMs})?> loadLastKnown();

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
/// Three values are stored:
/// - The full anchor JSON (for warm-start restoration)
/// - The last trusted UTC timestamp (for offline estimation)
/// - The last wall-clock timestamp (for offline estimation)
final class AnchorStore implements AnchorStorage {
  /// Hardware-backed secure storage with platform-appropriate configuration.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    wOptions: WindowsOptions(),
  );

  static const _keyAnchor = 'tt_anchor_v2';
  static const _keyLastTrustedUtcMs = 'tt_last_trusted_utc_ms';
  static const _keyLastAnchorWallMs = 'tt_last_anchor_wall_ms';

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
      await _storage.delete(key: _keyAnchor);
      return null;
    }
  }

  /// Persists the anchor and its tracking timestamps.
  ///
  /// All three writes are issued concurrently for speed. Note: these are
  /// not truly atomic — a crash mid-write could leave stale timestamps,
  /// but [load] and [loadLastKnown] handle missing/corrupt data gracefully.
  @override
  Future<void> save(TrustAnchor anchor) async {
    final raw = jsonEncode(anchor.toJson());
    await Future.wait([
      _storage.write(key: _keyAnchor, value: raw),
      _storage.write(
        key: _keyLastTrustedUtcMs,
        value: anchor.networkUtcMs.toString(),
      ),
      _storage.write(
        key: _keyLastAnchorWallMs,
        value: anchor.wallMs.toString(),
      ),
    ]);
  }

  /// Loads the raw millisecond timestamps for offline time estimation.
  ///
  /// Returns a record of `(trustedUtcMs, wallMs)` or `null` if either
  /// value is missing or corrupt.
  @override
  Future<({int trustedUtcMs, int wallMs})?> loadLastKnown() async {
    try {
      final results = await Future.wait([
        _storage.read(key: _keyLastTrustedUtcMs),
        _storage.read(key: _keyLastAnchorWallMs),
      ]);
      if (results[0] == null || results[1] == null) return null;
      return (
        trustedUtcMs: int.parse(results[0]!),
        wallMs: int.parse(results[1]!),
      );
    } catch (_) {
      return null;
    }
  }

  /// Wipes all persisted temporal data from secure storage.
  @override
  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _keyAnchor),
      _storage.delete(key: _keyLastTrustedUtcMs),
      _storage.delete(key: _keyLastAnchorWallMs),
    ]);
  }
}

/// Process-local [AnchorStorage] for unit tests and ephemeral environments.
///
/// State is held in plain memory — nothing is persisted across instances.
final class InMemoryAnchorStorage implements AnchorStorage {
  TrustAnchor? _anchor;
  int? _trustedUtcMs;
  int? _wallMs;

  @override
  Future<TrustAnchor?> load() async => _anchor;

  @override
  Future<void> save(TrustAnchor anchor) async {
    _anchor = anchor;
    _trustedUtcMs = anchor.networkUtcMs;
    _wallMs = anchor.wallMs;
  }

  @override
  Future<({int trustedUtcMs, int wallMs})?> loadLastKnown() async {
    if (_trustedUtcMs == null || _wallMs == null) return null;
    return (trustedUtcMs: _trustedUtcMs!, wallMs: _wallMs!);
  }

  @override
  Future<void> clear() async {
    _anchor = null;
    _trustedUtcMs = null;
    _wallMs = null;
  }
}
