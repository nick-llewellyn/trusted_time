import '../models.dart';
import '../monotonic_clock.dart';

/// Web/stub NTP source — NTP (UDP) is unavailable on this platform.
///
/// The [SyncEngine._querySafe] catch clause handles the thrown error
/// gracefully, so the engine will simply rely on HTTPS sources on web.
final class NtpSource implements TrustedTimeSource {
  NtpSource(this._host, {MonotonicClock? clock});

  final String _host;

  @override
  String get id => 'ntp:$_host';

  @override
  Future<TimeSample> fetch() async {
    throw UnsupportedError('NTP (UDP) is not available on this platform.');
  }
}
