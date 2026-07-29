import 'package:trusted_time/src/domain/marzullo_engine.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/infra/sync_observer.dart';
import 'package:trusted_time/src/models.dart';

/// [SyncObserver] that records consensus results, per-source failures,
/// reported metrics, and how many cycles started.
///
/// `onSampleReceived` and `onSyncFailed` are deliberately dropped:
/// per-sample capture belongs to [SampleCountingObserver], whose
/// doc comment carries the drop-semantics caveat that makes the tally
/// meaningful, and no caller asserts on the sync-failure callback.
class RecordingObserver implements SyncObserver {
  final List<({String sourceId, Object error})> sourceFailures = [];
  final List<ConsensusResult> consensusReached = [];
  final List<SyncMetrics> metricsReported = [];
  int syncStartedCount = 0;

  @override
  void onSourceFailed(String sourceId, Object error) {
    sourceFailures.add((sourceId: sourceId, error: error));
  }

  @override
  void onSyncStarted() {
    syncStartedCount++;
  }

  @override
  void onSampleReceived(TimeSample sample) {}

  @override
  void onConsensusReached(ConsensusResult result) {
    consensusReached.add(result);
  }

  @override
  void onSyncFailed(Object error) {}

  @override
  void onMetricsReported(SyncMetrics metrics) {
    metricsReported.add(metrics);
  }
}

/// Records every sample handed to the engine's stream listener so
/// stability-guard tests can assert how many samples the engine
/// consumed before early-exit fired.
///
/// Two engine paths drop samples after the completer resolves:
///   * the per-source fan-out loop in `SyncEngine.sync` guards every
///     `sampleController.add(sample)` with
///     `if (!streamClosed && !sampleController.isClosed)`, and the
///     `finally` block sets `streamClosed = true` and closes the
///     controller as soon as the completer resolves -- so a source
///     whose `getTime()` future resolves after completion has its
///     sample silently discarded before it ever reaches the listener;
///   * if a sample is already queued on the stream when the completer
///     completes, the listener's `if (completer.isCompleted) return;`
///     guard at the top short-circuits before invoking the observer.
///
/// The combined effect is that a sample is recorded by this observer
/// only if it reaches the listener before the completer resolves. The
/// "no recorded sample after early-exit" guarantee therefore relies
/// on the test pool's source delays leaving a comfortable wall-clock
/// margin between the last "expected" arrival and the first "should
/// be dropped" arrival -- the stability-guard tests pin that margin at
/// 300 ms (last expected at 100 ms, first dropped at 400 ms), which is
/// large compared to the few microtasks the engine needs between
/// firing early-exit and the completer resolving.
class SampleCountingObserver implements SyncObserver {
  final List<TimeSample> samplesReceived = [];

  @override
  void onSampleReceived(TimeSample sample) {
    samplesReceived.add(sample);
  }

  @override
  void onSourceFailed(String sourceId, Object error) {}
  @override
  void onSyncStarted() {}
  @override
  void onConsensusReached(ConsensusResult result) {}
  @override
  void onSyncFailed(Object error) {}
  @override
  void onMetricsReported(SyncMetrics metrics) {}
}

/// Minimal [SyncObserver] that just counts onSyncStarted invocations,
/// used to verify the proxy observer fan-out works on the first init.
class SyncStartedProbe implements SyncObserver {
  int startCount = 0;

  @override
  void onSyncStarted() => startCount++;

  @override
  void onSampleReceived(TimeSample sample) {}

  @override
  void onSourceFailed(String sourceId, Object error) {}

  @override
  void onConsensusReached(ConsensusResult result) {}

  @override
  void onMetricsReported(SyncMetrics metrics) {}

  @override
  void onSyncFailed(Object error) {}
}
