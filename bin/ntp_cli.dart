// NTP probe tool for curating the verified NTP server inventory
// (trusted_time-9hv / trusted_time-5fz). Runs on the standalone Dart
// VM — no Flutter binding — and drives the exact `defaultNtpExchange`
// and `AsnResolver` code paths that `NtpSource` consumes in
// production, so probe numbers match what the engine would see.
//
// Usage:
//   dart run bin/ntp_cli.dart [options] <host> [host ...]
//
// One line per probe. Default output is an aligned human-readable
// table; `--json` switches to NDJSON (one JSON object per line) for
// piping into `jq` or an aggregator.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:trusted_time/src/data/asn_resolver.dart';
import 'package:trusted_time/src/sources/ntp_client.dart';

/// Operators with documented leap-second smearing. Matching is by
/// host suffix on the queried name. Anything not listed is `unknown`:
/// a single probe outside a leap window cannot distinguish stepping
/// from smearing, so the verdict records documented operator policy,
/// not a live measurement.
const Map<String, String> _knownSmearerSuffixes = {
  'time.google.com': 'Google documents 24h linear smear',
  'time.aws.com': 'AWS documents 24h linear smear',
  'time.facebook.com': 'Meta documents ~17h smear',
};

/// Operators with documented stepping (never-smear) policy — the
/// project default assumption for national labs and NTP pool members
/// still needs per-host verification, so only explicit documentation
/// earns a `step` verdict here.
const Map<String, String> _knownStepperSuffixes = {
  'ptb.de': 'PTB documents UTC(PTB) stepping',
  'nts.netnod.se': 'Netnod documents stepping',
  'time.cloudflare.com': 'Cloudflare documents stepping since 2017 incident',
  'pool.ntp.org': 'pool operators must not smear per pool policy',
};

const String _usage = '''
Usage: dart run bin/ntp_cli.dart [options] <host> [host ...]

Options:
  --json               Emit NDJSON instead of the table.
  --burst, -b <n>      Exchanges per host (default 1; sequential,
                       like NtpSource bursts).
  --timeout, -t <s>    Per-exchange budget in seconds (default 5;
                       DNS + reply share it).
  --port <n>           UDP port to query (default 123).
  --exit-on-error      Exit non-zero as soon as any probe fails.
  --help, -h           Show this usage.''';

/// Parsed command line. Hand-rolled (a handful of flags) so the tool
/// needs no `package:args` dependency: `bin/` is public package code,
/// where the lint requires imports to be regular dependencies, and
/// this probe tool must not add a runtime dependency for consumers.
final class _CliArgs {
  _CliArgs({
    required this.hosts,
    required this.asJson,
    required this.exitOnError,
    required this.showHelp,
    required this.burst,
    required this.timeoutSecs,
    required this.port,
  });

  final List<String> hosts;
  final bool asJson;
  final bool exitOnError;
  final bool showHelp;
  final int burst;
  final int timeoutSecs;
  final int port;

  static _CliArgs parse(List<String> argv) {
    final hosts = <String>[];
    var asJson = false;
    var exitOnError = false;
    var showHelp = false;
    var burst = 1;
    var timeoutSecs = 5;
    var port = 123;
    int takeValue(String flag, Iterator<String> it) {
      if (!it.moveNext()) {
        throw FormatException('missing value for $flag');
      }
      final v = int.tryParse(it.current);
      if (v == null) throw FormatException('$flag needs an integer');
      return v;
    }

    final it = argv.iterator;
    while (it.moveNext()) {
      final a = it.current;
      switch (a) {
        case '--json':
          asJson = true;
        case '--exit-on-error':
          exitOnError = true;
        case '--help' || '-h':
          showHelp = true;
        case '--burst' || '-b':
          burst = takeValue(a, it);
        case '--timeout' || '-t':
          timeoutSecs = takeValue(a, it);
        case '--port':
          port = takeValue(a, it);
        default:
          if (a.startsWith('-')) throw FormatException('unknown option $a');
          hosts.add(a);
      }
    }
    if (burst < 1 || timeoutSecs < 1 || port < 1 || port > 65535) {
      throw const FormatException(
        'burst/timeout must be >= 1; port must be 1..65535',
      );
    }
    return _CliArgs(
      hosts: hosts,
      asJson: asJson,
      exitOnError: exitOnError,
      showHelp: showHelp,
      burst: burst,
      timeoutSecs: timeoutSecs,
      port: port,
    );
  }
}

Future<void> main(List<String> argv) async {
  final _CliArgs args;
  try {
    args = _CliArgs.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (args.showHelp || args.hosts.isEmpty) {
    print(_usage);
    if (args.hosts.isEmpty && !args.showHelp) exitCode = 64;
    return;
  }

  final resolver = AsnResolver(loader: _packageAssetLoader);
  var failures = 0;

  if (!args.asJson) print(_tableHeader());
  for (final host in args.hosts) {
    for (var attempt = 1; attempt <= args.burst; attempt++) {
      final probe = await _probe(
        host,
        resolver: resolver,
        timeout: Duration(seconds: args.timeoutSecs),
        port: args.port,
        attempt: attempt,
      );
      if (probe['error'] != null) failures++;
      print(args.asJson ? jsonEncode(probe) : _tableRow(probe));
      if (args.exitOnError && probe['error'] != null) {
        exitCode = 1;
        return;
      }
    }
  }
  if (failures > 0) exitCode = 1;
}

/// Runs one exchange against [host] and reduces it to the flat JSON
/// shape both output modes consume. DNS is resolved here (rather than
/// letting `defaultNtpExchange` do it) so the ASN of the *probed IP*
/// is recorded — for anycast and pool hosts the answer is
/// vantage-dependent, which is exactly what the inventory needs to
/// capture.
Future<Map<String, Object?>> _probe(
  String host, {
  required AsnResolver resolver,
  required Duration timeout,
  required int port,
  required int attempt,
}) async {
  final base = <String, Object?>{
    'host': host,
    'attempt': attempt,
    'utc': DateTime.now().toUtc().toIso8601String(),
  };
  final InternetAddress ip;
  try {
    ip =
        InternetAddress.tryParse(host) ??
        (await InternetAddress.lookup(host).timeout(timeout)).first;
  } catch (e) {
    return {...base, 'error': 'dns: $e'};
  }
  base['ip'] = ip.address;
  final asn = await resolver.lookup(ip);
  base['asn'] = asn;
  base['group'] = asn == null ? 'asn-unknown' : 'as$asn';
  final verdict = _leapPolicy(host);
  base['leapPolicy'] = verdict.$1;
  base['leapPolicyEvidence'] = verdict.$2;
  try {
    final r = await defaultNtpExchange(
      ip.address,
      timeout: timeout,
      port: port,
    );
    return {
      ...base,
      'stratum': r.stratum,
      'offsetMicros': r.offsetMicros,
      'delayMicros': r.delayMicros,
      'rootDelayMicros': r.rootDelayMicros,
      'rootDispersionMicros': r.rootDispersionMicros,
      'leapIndicator': r.leapIndicator,
      'referenceId': _formatReferenceId(r.referenceId, r.stratum),
    };
  } on Object catch (e) {
    return {...base, 'error': e.toString()};
  }
}

/// Documented leap-second policy for [host]: `smear`, `step`, or
/// `unknown`, with the evidence string. Suffix matching so regional
/// aliases (e.g. `ptbtime1.ptb.de`, `mmo1.nts.netnod.se`) inherit
/// their operator's documented policy.
(String, String?) _leapPolicy(String host) {
  final h = host.toLowerCase();
  for (final e in _knownSmearerSuffixes.entries) {
    if (h == e.key || h.endsWith('.${e.key}')) return ('smear', e.value);
  }
  for (final e in _knownStepperSuffixes.entries) {
    if (h == e.key || h.endsWith('.${e.key}')) return ('step', e.value);
  }
  return ('unknown', null);
}

/// Renders the 4-byte reference identifier: ASCII refclock code for
/// stratum 1 (e.g. `GPS`, `PPS`), dotted-quad style otherwise.
String _formatReferenceId(int refId, int stratum) {
  final bytes = [
    (refId >> 24) & 0xff,
    (refId >> 16) & 0xff,
    (refId >> 8) & 0xff,
    refId & 0xff,
  ];
  if (stratum == 1) {
    return String.fromCharCodes(bytes.where((b) => b >= 0x20 && b < 0x7f));
  }
  return bytes.join('.');
}

/// Reads the bundled ASN snapshot from the package's own `assets/`
/// directory on disk — the CLI runs from a source checkout, so the
/// Flutter asset key is mapped back to a filesystem path via
/// `package:trusted_time`'s resolved root.
Future<Uint8List> _packageAssetLoader(String key) async {
  const prefix = 'packages/trusted_time/';
  final relative = key.startsWith(prefix) ? key.substring(prefix.length) : key;
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:trusted_time/trusted_time.dart'),
  );
  if (libUri == null) throw StateError('cannot resolve package root');
  final root = File.fromUri(libUri).parent.parent.path;
  return File('$root/$relative').readAsBytes();
}

String _tableHeader() =>
    '${'HOST'.padRight(28)} ${'IP'.padRight(24)} ${'ASN'.padRight(10)} '
    '${'ST'.padRight(3)} ${'OFFSET'.padRight(12)} ${'DELAY'.padRight(10)} '
    '${'LI'.padRight(3)} ${'LEAP'.padRight(8)} REF/ERROR';

String _tableRow(Map<String, Object?> p) {
  final host = '${p['host']}'.padRight(28);
  final ip = '${p['ip'] ?? '-'}'.padRight(24);
  final group = '${p['group'] ?? '-'}'.padRight(10);
  if (p['error'] != null) {
    return '$host $ip $group ${'-'.padRight(3)} ${'-'.padRight(12)} '
        '${'-'.padRight(10)} ${'-'.padRight(3)} '
        '${(p['leapPolicy'] ?? '-').toString().padRight(8)} '
        'ERROR: ${p['error']}';
  }
  final offsetMs = ((p['offsetMicros']! as int) / 1000).toStringAsFixed(2);
  final delayMs = ((p['delayMicros']! as int) / 1000).toStringAsFixed(2);
  return '$host $ip $group ${'${p['stratum']}'.padRight(3)} '
      '${'${offsetMs}ms'.padRight(12)} ${'${delayMs}ms'.padRight(10)} '
      '${'${p['leapIndicator']}'.padRight(3)} '
      '${'${p['leapPolicy']}'.padRight(8)} ${p['referenceId']}';
}
