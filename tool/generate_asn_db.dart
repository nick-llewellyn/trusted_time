// Developer tool — NOT shipped at runtime.
//
// Downloads the iptoasn.com `ip2asn-combined.tsv.gz` dataset (released
// into the public domain under the PDDL) and converts it into two
// compact, sorted, gzip-compressed binary assets consumed by
// `AsnResolver`:
//
//   assets/asn/ip2asn-v4.bin.gz   IPv4 ranges -> ASN
//   assets/asn/ip2asn-v6.bin.gz   IPv6 ranges -> ASN
//
// Binary layout (big-endian), per file:
//   magic   'A''S''N''1'  (4 bytes)
//   version u8            (1)
//   ipKind  u8            (4 or 6)
//   _pad    u16           (0)
//   count   u32           number of records
//   records count * (startBytes + endBytes + asn u32)
//             startBytes/endBytes = 4 for v4, 16 for v6
//
// Contiguous ranges sharing one ASN are merged; unrouted ranges
// (ASN 0) are dropped. Re-run after refreshing the snapshot:
//   dart run tool/generate_asn_db.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _source = 'https://iptoasn.com/data/ip2asn-combined.tsv.gz';
const _outDir = 'assets/asn';

Future<void> main() async {
  stdout.writeln('Downloading $_source ...');
  final raw = await _download(_source);
  stdout.writeln('  ${raw.length} bytes compressed; decompressing ...');
  final tsv = gzip.decode(raw);
  stdout.writeln('  ${tsv.length} bytes TSV; parsing ...');

  final v4 = <_Range>[];
  final v6 = <_Range>[];
  for (final line in const LineSplitter().convert(utf8.decode(tsv))) {
    if (line.isEmpty) continue;
    final cols = line.split('\t');
    if (cols.length < 3) continue;
    final asn = int.tryParse(cols[2]) ?? 0;
    if (asn == 0) continue;
    final start = InternetAddress.tryParse(cols[0]);
    final end = InternetAddress.tryParse(cols[1]);
    if (start == null || end == null) continue;
    final s = Uint8List.fromList(start.rawAddress);
    final e = Uint8List.fromList(end.rawAddress);
    (s.length == 4 ? v4 : v6).add(_Range(s, e, asn));
  }
  stdout.writeln('  parsed v4=${v4.length} v6=${v6.length} routed ranges');

  final merged4 = _merge(v4..sort(_cmp));
  final merged6 = _merge(v6..sort(_cmp));
  stdout.writeln('  merged  v4=${merged4.length} v6=${merged6.length}');

  await Directory(_outDir).create(recursive: true);
  await _write('$_outDir/ip2asn-v4.bin.gz', 4, merged4);
  await _write('$_outDir/ip2asn-v6.bin.gz', 6, merged6);
  stdout.writeln('Done.');
}

Future<Uint8List> _download(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('GET $url -> ${res.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

int _cmp(_Range a, _Range b) {
  for (var i = 0; i < a.start.length; i++) {
    final d = a.start[i] - b.start[i];
    if (d != 0) return d;
  }
  return 0;
}

/// Coalesces adjacent ranges that share an ASN (`end + 1 == nextStart`).
List<_Range> _merge(List<_Range> sorted) {
  final out = <_Range>[];
  for (final r in sorted) {
    if (out.isNotEmpty &&
        out.last.asn == r.asn &&
        _isSucc(out.last.end, r.start)) {
      out.last.end = r.end;
    } else {
      out.add(_Range(r.start, r.end, r.asn));
    }
  }
  return out;
}

/// True when [next] is exactly [prev] + 1 (big-endian, same width).
bool _isSucc(Uint8List prev, Uint8List next) {
  final inc = Uint8List.fromList(prev);
  for (var i = inc.length - 1; i >= 0; i--) {
    if (inc[i] != 0xFF) {
      inc[i]++;
      break;
    }
    inc[i] = 0;
  }
  for (var i = 0; i < inc.length; i++) {
    if (inc[i] != next[i]) return false;
  }
  return true;
}

Future<void> _write(String path, int kind, List<_Range> ranges) async {
  final w = kind == 4 ? 4 : 16;
  final body = Uint8List(12 + ranges.length * (2 * w + 4));
  final bd = ByteData.sublistView(body);
  body[0] = 0x41; // 'A'
  body[1] = 0x53; // 'S'
  body[2] = 0x4E; // 'N'
  body[3] = 0x31; // '1'
  body[4] = 1; // version
  body[5] = kind;
  bd.setUint32(8, ranges.length);
  var o = 12;
  for (final r in ranges) {
    body.setRange(o, o + w, r.start);
    o += w;
    body.setRange(o, o + w, r.end);
    o += w;
    bd.setUint32(o, r.asn);
    o += 4;
  }
  final gz = gzip.encode(body);
  await File(path).writeAsBytes(gz);
  stdout.writeln('  wrote $path  (${body.length} raw, ${gz.length} gz)');
}

class _Range {
  _Range(this.start, this.end, this.asn);
  final Uint8List start;
  Uint8List end;
  final int asn;
}
