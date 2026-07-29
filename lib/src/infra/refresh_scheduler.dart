import 'dart:async';

/// Owns the two sync-cadence timers: the automatic refresh timer and
/// the failed-sync retry timer.
///
/// Every mutator pairs `cancel()` with `= null`, and each timer clears
/// its own field before dispatching, so a null timer field is a
/// reliable "nothing armed" signal at every site rather than a field
/// that may still reference a spent or cancelled [Timer]. Self-clearing
/// on fire keeps that true independently of what `onTick` does: a
/// callback that re-enters and bails early (a sync cycle already in
/// flight) never gets the chance to clear the field on the scheduler's
/// behalf.
///
/// The scheduler computes nothing on the engine's behalf:
/// [scheduleRetry] receives the backoff delay from the caller, and
/// both timers fire the `onTick` callback supplied at construction.
/// That callback is the only coupling back to the caller — no typed
/// reference to the engine, no import of it — though as an instance
/// tear-off it does keep the caller reachable from here.
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

  /// The cadence [scheduleRefresh] arms with.
  ///
  /// A schedule value, not a statement that a timer is pending: it
  /// survives [pause] and [dispose] unchanged, and [setInterval] leaves
  /// it untouched for a non-positive interval so a later [resume]
  /// re-arms with the most recent positive cadence.
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
    _refreshTimer = Timer(_activeInterval, _fire(() => _refreshTimer = null));
  }

  /// Arms the retry timer [delay] from now, replacing any pending
  /// retry. A non-positive [delay] cancels without re-arming, which is
  /// how the caller signals that the backoff budget is exhausted.
  void scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_disposed) return;
    if (delay > Duration.zero) {
      _retryTimer = Timer(delay, _fire(() => _retryTimer = null));
    }
  }

  /// Wraps [_onTick] so the fired timer's field is cleared before the
  /// callback runs and no dispatch escapes after [dispose].
  ///
  /// [clearField] nulls whichever field armed this timer. It runs
  /// unconditionally — including when disposed — because the field
  /// describes *this* scheduler's arming state, not whether the
  /// callback was worth running. It cannot clear a *newer* timer's
  /// field: every arming path cancels before reassigning, so a
  /// superseded timer never fires.
  void Function() _fire(void Function() clearField) {
    return () {
      clearField();
      if (_disposed) return;
      _onTick();
    };
  }

  /// Cancels both timers at the start of a sync cycle.
  ///
  /// Cancelling the refresh timer closes a gap the caller's in-flight
  /// guard does not: a refresh armed by a prior successful cycle could
  /// otherwise fire moments after this cycle completes, and there is
  /// no overlap for that guard to catch. The success path re-arms a
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
