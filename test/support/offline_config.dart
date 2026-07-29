import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';

/// Builds a network-free config whose only sources are the injected fakes.
///
/// [ntsServers] defaults to empty so the config stays fully offline. The
/// y81 regression tests pass a non-empty list to exercise the NTS bootstrap
/// gate; the injected fakes still supply quorum, and any real [NtsSource]
/// built from [ntsServers] is caught per-source by the engine (it throws
/// "not initialised") without aborting the cycle.
TrustedTimeConfig offlineConfig({
  required List<TimeSource> sources,
  bool persistState = true,
  List<String> ntsServers = const [],
}) => TrustedTimeConfig(
  disableNtpForTesting: true,
  ntsServers: ntsServers,
  minimumQuorum: 2,
  persistState: persistState,
  additionalSources: sources,
);
