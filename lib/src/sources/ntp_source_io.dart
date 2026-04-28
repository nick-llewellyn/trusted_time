import 'package:ntp/ntp.dart';
import '../models.dart';
import '../monotonic_clock.dart';

/// NTP time source — IO-only (uses UDP sockets via `dart:io`).
final class NtpSource implements TrustedTimeSource {
  NtpSource(this._host, {MonotonicClock? clock})
    : _clock = clock ?? PlatformMonotonicClock();

  final String _host;
  final MonotonicClock _clock;

  @override
  String get id => 'ntp:$_host';

  @override
  Future<TimeSample> fetch() async {
    final sw = Stopwatch()..start();
    final offset = await NTP.getNtpOffset(
      lookUpAddress: _host,
      timeout: const Duration(seconds: 10),
    );
    sw.stop();
    // Capture monotonic reference immediately on response receipt, before
    // any further aggregation work in the sync engine.
    final capturedMonotonicMs = await _clock.uptimeMs();
    final capturedAt = DateTime.now().toUtc();
    final networkUtc = capturedAt.add(Duration(milliseconds: offset));
    final rtt = sw.elapsed;
    return TimeSample(
      networkUtc: networkUtc,
      roundTripTime: rtt,
      uncertainty: Duration(milliseconds: rtt.inMilliseconds ~/ 2),
      capturedMonotonicMs: capturedMonotonicMs,
      source: TimeSourceMetadata(
        kind: TimeSourceKind.ntp,
        id: id,
        host: _host,
      ),
      capturedAt: capturedAt,
    );
  }
}
