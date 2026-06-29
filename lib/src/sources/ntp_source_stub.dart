import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../infra/dns_budget.dart';

/// NTP time source stub — actual implementation in `ntp_source_io.dart`.
final class NtpSource implements TimeSource {
  /// Stub constructor. [dnsBudget] is accepted for signature parity with
  /// the IO implementation and ignored — Web configurations carry no NTP
  /// sources, so this constructor is never reached at runtime.
  const NtpSource(this._host, {DnsBudget? dnsBudget});

  final String _host;

  @override
  String get id => 'ntp:$_host';

  @override
  String get groupId => _host;

  @override
  Future<TimeSample> getTime() =>
      throw UnimplementedError('NTP requires dart:io');
}
