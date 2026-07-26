// Deliberately Flutter-free (dart:io + dart:typed_data only) so the
// `bin/ntp_cli.dart` probe tool can run this resolver on the
// standalone Dart VM. The production rootBundle loader lives in
// `asn_bundle_loader.dart`; Flutter callers (NtpSource) inject it.
import 'dart:io' show InternetAddress, InternetAddressType, gzip;
import 'dart:typed_data';

/// Loads the raw bytes of a bundled asset. Injectable so unit tests can
/// supply an in-memory table, and so non-Flutter callers (the CLI probe
/// tool) can read the snapshot from disk instead of the asset bundle.
typedef AssetByteLoader = Future<Uint8List> Function(String key);

/// Offline IP-to-ASN resolver backed by the bundled iptoasn.com snapshot
/// (`assets/asn/*.bin.gz`, PDDL public-domain).
///
/// Each family's table is decompressed and cached on first use; lookups
/// are a binary search over sorted `[start, end] -> asn` ranges. Every
/// failure mode (missing asset, decode error, unknown IP) resolves to
/// `null` so callers can fall back gracefully — no exception escapes
/// [lookup].
final class AsnResolver {
  /// Creates a resolver reading table bytes through [loader] — the
  /// `rootBundle`-backed `rootBundleAssetLoader` in production Flutter
  /// use, an in-memory table in unit tests, or a filesystem reader on
  /// the plain Dart VM.
  AsnResolver({required AssetByteLoader loader}) : _load = loader;

  /// Asset key for the IPv4 table.
  static const String keyV4 =
      'packages/trusted_time/assets/asn/ip2asn-v4.bin.gz';

  /// Asset key for the IPv6 table.
  static const String keyV6 =
      'packages/trusted_time/assets/asn/ip2asn-v6.bin.gz';

  final AssetByteLoader _load;

  // Memoise the in-flight load per family so concurrent first-use
  // lookups share a single decompress + parse. A failed build resolves
  // to a cached `null`-completing future, so failures are not retried.
  Future<_Table?>? _v4;
  Future<_Table?>? _v6;

  /// Returns the ASN owning [ip], or `null` when the address is unknown,
  /// the table is unavailable, or the asset cannot be decoded.
  Future<int?> lookup(InternetAddress ip) async {
    final isV6 = ip.type == InternetAddressType.IPv6;
    final table = await _table(isV6);
    if (table == null) return null;
    return table.search(Uint8List.fromList(ip.rawAddress));
  }

  Future<_Table?> _table(bool isV6) {
    if (isV6) return _v6 ??= _build(keyV6, 6);
    return _v4 ??= _build(keyV4, 4);
  }

  Future<_Table?> _build(String key, int kind) async {
    try {
      final gz = await _load(key);
      final bytes = Uint8List.fromList(gzip.decode(gz));
      return _Table.parse(bytes, kind);
    } catch (_) {
      return null;
    }
  }
}

/// In-memory view over a decoded ASN table (see `tool/generate_asn_db.dart`
/// for the on-disk layout).
final class _Table {
  _Table._(this._bytes, this._bd, this._width, this._count)
    : _recSize = 2 * _width + 4;

  final Uint8List _bytes;
  final ByteData _bd;
  final int _width;
  final int _count;
  final int _recSize;

  static const int _headerSize = 12;

  static _Table? parse(Uint8List bytes, int kind) {
    if (bytes.length < _headerSize) return null;
    final okMagic =
        bytes[0] == 0x41 &&
        bytes[1] == 0x53 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x31;
    if (!okMagic || bytes[4] != 1 || bytes[5] != kind) return null;
    final width = kind == 4 ? 4 : 16;
    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint32(8);
    if (bytes.length < _headerSize + count * (2 * width + 4)) return null;
    return _Table._(bytes, bd, width, count);
  }

  /// Greatest record whose start <= [ip]; returns its ASN when [ip] also
  /// falls within that record's end, else `null`.
  int? search(Uint8List ip) {
    if (ip.length != _width) return null;
    var lo = 0;
    var hi = _count - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final off = _headerSize + mid * _recSize;
      if (_cmp(ip, off) >= 0) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (ans < 0) return null;
    final off = _headerSize + ans * _recSize;
    if (_cmp(ip, off + _width) <= 0) {
      return _bd.getUint32(off + 2 * _width);
    }
    return null;
  }

  /// Compares [ip] against the [_width]-byte value at [off] (big-endian).
  int _cmp(Uint8List ip, int off) {
    for (var i = 0; i < _width; i++) {
      final d = ip[i] - _bytes[off + i];
      if (d != 0) return d;
    }
    return 0;
  }
}
