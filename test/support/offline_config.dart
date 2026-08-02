import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/models.dart';

/// Builds a network-free config whose only sources are the injected fakes.
///
/// NTS is disabled by default so the config stays fully offline. The y81
/// regression tests pass [ntsInventory] to exercise the NTS bootstrap gate;
/// the injected fakes still supply quorum, and any real [NtsSource] built
/// from the substitute inventory is caught per-source by the engine (it
/// throws "not initialised") without aborting the cycle.
TrustedTimeConfig offlineConfig({
  required List<TimeSource> sources,
  bool persistState = true,
  List<NtsServerInfo>? ntsInventory,
}) => TrustedTimeConfig(
  disableNtpForTesting: true,
  disableNts: ntsInventory == null,
  ntsInventoryForTesting: ntsInventory,
  minimumQuorum: 2,
  persistState: persistState,
  additionalSources: sources,
);

/// A single-host substitute inventory for the NTS bootstrap-gate tests.
///
/// The host is never reached: the gate under test runs before any source
/// query, and an uninitialised [NtsSource] throws per-source.
const fakeNtsInventory = [
  NtsServerInfo(
    host: 'nts.example.test',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
];
