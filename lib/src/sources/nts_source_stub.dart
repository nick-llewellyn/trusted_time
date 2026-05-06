import 'package:flutter/foundation.dart';
import '../models.dart';
import '../monotonic_clock.dart';

/// Web/stub NTS source — RFC 8915 requires raw TCP (NTS-KE) and raw UDP
/// (NTPv4) sockets, neither of which is reachable from a browser tab.
///
/// `SyncEngine._querySafe`'s catch clause swallows the thrown error, so
/// the engine simply falls through to its remaining sources (typically
/// `HttpsSource`) on web.
final class NtsSource implements TrustedTimeSource {
  NtsSource(
    this._host, {
    int port = 4460,
    Duration timeout = const Duration(seconds: 5),
    MonotonicClock? clock,
  }) : _timeout = timeout {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'must be a positive Duration; mirrors the io implementation '
            'so a non-positive value is rejected uniformly across '
            'platforms even though this stub never consumes the '
            'value at fetch() time.',
      );
    }
  }

  final String _host;
  final Duration _timeout;

  /// Test seam matching the io implementation so the
  /// `TrustedTimeConfig.ntsRequestTimeout` plumbing regression compiles
  /// and runs identically on web.
  @visibleForTesting
  Duration get requestTimeoutForTesting => _timeout;

  @override
  String get id => 'nts:$_host';

  @override
  Future<TimeSample> fetch() async {
    throw UnsupportedError('NTS is not available on this platform.');
  }
}
