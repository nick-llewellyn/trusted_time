import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../domain/time_source.dart';

/// NTS time source stub — actual implementation in `nts_source.dart`.
final class NtsSource implements TimeSource {
  /// Documented.
  NtsSource(
    this._host, {
    int port = 4460,
    int dnsConcurrencyCap = nts.kDefaultDnsConcurrencyCap,
    Duration maxLatency = const Duration(seconds: 5),
    nts.TrustMode trustMode = nts.TrustMode.platformWithFallback,
    List<int>? customRoots,
    void Function(int)? onStratumObserved,
  });

  final String _host;

  @override
  String get id => 'nts:$_host';

  @override
  String get groupId => _host;

  @override
  Future<TimeSample> getTime() =>
      throw UnimplementedError('NTS requires dart:io');
}
