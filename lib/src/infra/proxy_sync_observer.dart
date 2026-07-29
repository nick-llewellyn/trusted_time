import '../domain/time_sample.dart';
import '../domain/marzullo_engine.dart';
import '../models.dart';
import 'sync_observer.dart';

/// Fans every [SyncObserver] callback out to a live observer set.
///
/// The set is resolved through [_getObservers] on each callback rather
/// than captured once, so observers registered after the engine was
/// constructed still receive events.
class ProxySyncObserver implements SyncObserver {
  /// Creates a proxy that resolves its targets through [getObservers].
  ProxySyncObserver(Set<SyncObserver> Function() getObservers)
    : _getObservers = getObservers;

  final Set<SyncObserver> Function() _getObservers;

  @override
  void onSyncStarted() {
    for (final o in _getObservers()) {
      o.onSyncStarted();
    }
  }

  @override
  void onSampleReceived(TimeSample sample) {
    for (final o in _getObservers()) {
      o.onSampleReceived(sample);
    }
  }

  @override
  void onSourceFailed(String sourceId, Object error) {
    for (final o in _getObservers()) {
      o.onSourceFailed(sourceId, error);
    }
  }

  @override
  void onConsensusReached(ConsensusResult result) {
    for (final o in _getObservers()) {
      o.onConsensusReached(result);
    }
  }

  @override
  void onSyncFailed(Object error) {
    for (final o in _getObservers()) {
      o.onSyncFailed(error);
    }
  }

  @override
  void onMetricsReported(SyncMetrics metrics) {
    for (final o in _getObservers()) {
      o.onMetricsReported(metrics);
    }
  }
}
