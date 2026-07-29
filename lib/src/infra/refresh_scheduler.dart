import 'dart:async';

/// Owns the two sync-cadence timers: the automatic refresh timer and
/// the failed-sync retry timer.
///
/// Every mutator pairs `cancel()` with `= null`, so a null timer field
/// is a reliable "nothing armed" signal at every site rather than a
/// field that may still reference a spent or cancelled [Timer].
///
/// The scheduler holds no reference to the engine: [scheduleRetry]
/// receives the backoff delay from the caller, and both timers fire
/// the `onTick` callback supplied at construction.
class RefreshScheduler {
  /// Creates a scheduler that fires [onTick] on every refresh or retry
  /// deadline, with the automatic refresh cadence starting at
  /// [initialInterval].
  RefreshScheduler({
    required Duration initialInterval,
    required void Function() onTick,
  }) : _activeInterval = initialInterval,
       _onTick = onTick;

  final void Function() _onTick;

  Timer? _refreshTimer;
  Timer? _retryTimer;

  /// Runtime-mutable refresh schedule. Distinct from the config's
  /// `refreshInterval`, which captures the at-init value and is never
  /// mutated; [_activeInterval] is what [scheduleRefresh] actually
  /// uses. [_paused] suppresses the timer entirely regardless of the
  /// interval value.
  Duration _activeInterval;
  bool _paused = false;
  bool _disposed = false;

  /// The interval the automatic refresh timer is currently armed with.
  Duration get activeInterval => _activeInterval;

  /// Whether automatic refresh is enabled.
  ///
  /// Reflects the schedule's intent — `false` after [pause] or after
  /// [setInterval] with a non-positive duration — not whether a timer
  /// is armed at this exact moment. [scheduleRefresh] is only called
  /// on cycle completion and from the explicit entry points, so this
  /// can return `true` while no timer is pending.
  bool get automaticRefreshActive =>
      !_paused && _activeInterval > Duration.zero;

  /// Whether the failed-sync retry timer is currently armed.
  bool get retryTimerActive => _retryTimer != null;

  /// Arms the automatic refresh timer one [activeInterval] from now,
  /// replacing any pending refresh.
  ///
  /// No timer is armed once disposed, while paused, or when the active
  /// interval is non-positive.
  void scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_disposed) return;
    if (_paused) return;
    if (_activeInterval <= Duration.zero) return;
    _refreshTimer = Timer(_activeInterval, _onTick);
  }

  /// Arms the retry timer [delay] from now, replacing any pending
  /// retry. A non-positive [delay] cancels without re-arming, which is
  /// how the caller signals that the backoff budget is exhausted.
  void scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_disposed) return;
    if (delay > Duration.zero) {
      _retryTimer = Timer(delay, _onTick);
    }
  }

  /// Cancels both timers at the start of a sync cycle.
  ///
  /// The retry timer may have fired into this very cycle, so clearing
  /// the field keeps it from pointing at a spent [Timer]. Cancelling
  /// the refresh timer closes a distinct gap: a refresh armed by a
  /// prior successful cycle could otherwise fire moments after this
  /// cycle completes, which the caller's in-flight guard does not
  /// catch because there is no overlap. The success path re-arms a
  /// fresh window from this cycle's completion via [scheduleRefresh].
  void cancelPending() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Cancels any pending refresh *without* pausing the schedule, so
  /// [automaticRefreshActive] stays true.
  void cancelRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Pauses automatic refresh.
  ///
  /// Cancels any pending refresh and prevents [scheduleRefresh] from
  /// re-arming. Idempotent. Does not affect the retry timer.
  void pause() {
    _paused = true;
    cancelRefreshTimer();
  }

  /// Clears the pause flag and arms a refresh one [activeInterval]
  /// from the time of this call.
  ///
  /// If the active interval is non-positive, clearing the flag has no
  /// observable effect until [setInterval] is called with a positive
  /// duration.
  void resume() {
    _paused = false;
    scheduleRefresh();
  }

  /// Replaces the active refresh interval and arms a fresh timer.
  ///
  /// A non-positive [interval] is equivalent to [pause] and leaves
  /// [activeInterval] untouched, so a later [resume] re-arms with the
  /// most recent positive interval.
  void setInterval(Duration interval) {
    if (interval <= Duration.zero) {
      pause();
      return;
    }
    _activeInterval = interval;
    _paused = false;
    scheduleRefresh();
  }

  /// Cancels both timers and blocks any further arming.
  void dispose() {
    _disposed = true;
    cancelPending();
  }
}
