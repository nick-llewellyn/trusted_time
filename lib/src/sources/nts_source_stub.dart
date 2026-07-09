import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../domain/time_source.dart';

/// Collapses the successful samples of one [NtsSource] query burst —
/// signature mirror of the implementation in `nts_source.dart`.
typedef NtsBurstReducer = TimeSample Function(List<TimeSample> samples);

/// Stub mirror of `lowestRttReducer` in `nts_source.dart`.
TimeSample lowestRttReducer(List<TimeSample> samples) =>
    throw UnimplementedError('NTS requires dart:io');

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
    int burstCount = 1,
    NtsBurstReducer reducer = lowestRttReducer,
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
