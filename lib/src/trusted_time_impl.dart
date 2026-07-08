import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'models.dart';
import 'anchor_store.dart';
import 'exceptions.dart';
import 'integrity_event.dart';
import 'integrity_monitor.dart';
import 'monotonic_clock.dart';
import 'sync_cycle.dart';
import 'sync_engine.dart';
import 'sources/nts_auth_level.dart';
import 'infra/sync_observer.dart';
import 'infra/consensus_cache.dart';
import 'domain/time_sample.dart';
import 'domain/marzullo_engine.dart';
import 'drift_calibrator.dart';
import 'trusted_time_estimate.dart';
import 'trusted_time_mock.dart';

/// ## Absolute Top Tier: High-Integrity Implementation Engine
///
/// [TrustedTimeImpl] manages the end-to-end lifecycle of temporal trust,
/// from hardware monotonic anchoring to network-verified consensus.
///
/// Features:
/// * **Hardware-Anchored UTC**: Projects time using the device oscillator to
///   thwart wall-clock manipulation.
/// * **Closed-Loop Feedback**: Automatically recovers trust upon detection of
///   monotonic anomalies or system reboots.
/// * **Hermetic Testability**: Supports high-fidelity mock injection for
///   deterministic security auditing.
final class TrustedTimeImpl {
  TrustedTimeImpl._({
    required TrustedTimeConfig config,
    required AnchorStore store,
    required MonotonicClock clock,
  }) : _config = config,
       _store = store,
       _cache = ConsensusCache(),
       _syncClock = SyncClock(),
       _monitor = IntegrityMonitor(clock: clock) {
    _syncEngine = SyncEngine(
      config: config,
      clock: clock,
      // Bind the proxy observer to *this* instance's _observers set
      // rather than to the static _instance. _instance is not assigned
      // until _bootstrap() completes (see init()), and _bootstrap's
      // first sync cycle synchronously invokes onSyncStarted, which
      // would dereference a null _instance on the very first init() —
      // surfacing as 'Null check operator used on a null value' inside
      // _performSync's catch and silently failing the bootstrap sync.
      observer: _ProxySyncObserver(() => _observers),
      // Route engine-originated integrity events (degradedTier) onto the
      // same monitor stream that backs onIntegrityLost, so consumers see a
      // tier degradation through the one integrity channel.
      onIntegrityEvent: _monitor.report,
      cache:
          _cache, // Shared cache between impl and engine for state propagation
    );
  }

  static TrustedTimeImpl? _instance;

  /// Documented.
  static TrustedTimeImpl get instance {
    assert(_instance != null, 'Call TrustedTime.initialize() first.');
    return _instance!;
  }

  /// Documented.
  static Future<TrustedTimeImpl> init(TrustedTimeConfig config) async {
    _instance?.dispose();
    final impl = TrustedTimeImpl._(
      config: config,
      store: AnchorStore(),
      clock: PlatformMonotonicClock(),
    );
    await impl._bootstrap();
    _instance = impl;
    _bgChannel.setMethodCallHandler(impl._handleBackgroundMethodCall);
    return impl;
  }

  final TrustedTimeConfig _config;
  final AnchorStore _store;
  late final SyncEngine _syncEngine;
  final IntegrityMonitor _monitor;
  final ConsensusCache _cache;
  final SyncClock _syncClock;
  final DriftCalibrator _driftCalibrator = DriftCalibrator();
  final _observers = <SyncObserver>{};

  TrustAnchor? _anchor;
  bool _trusted = false;
  Timer? _refreshTimer;
  Timer? _retryTimer;
  Timer? _desktopBgTimer;
  StreamSubscription<IntegrityEvent>? _integritySub;
  Completer<void>? _syncInProgress;

  // Tiered-cadence auxiliaries (ADR 0006), live only under
  // [CadenceMode.tieredMobile]. Under the legacy
  // [CadenceMode.singleTier30m] schedule all three stay null/zero and no
  // tiered code path is ever reached, so that mode is bit-for-bit
  // unchanged.
  Timer? _validateTimer;
  WidgetsBindingObserver? _lifecycleObserver;
  Duration? _backgroundedElapsed;
  int _validateCycleCount = 0;

  // Validate-cycle in-flight guard (ADR 0006). Held for the duration of
  // a single [_runValidateCycle] so the periodic validate timer and the
  // foreground-resume trigger can never run overlapping validate bursts
  // against the same source.
  bool _validateInProgress = false;

  /// Monotonic clock used to measure how long the app spent backgrounded.
  /// Deliberately *not* wall-clock time: a trusted-time library must not
  /// trust [DateTime.now] to gate its own freshness checks, since a
  /// backward clock jump would yield a negative duration and skip the
  /// validate cycle precisely when drift is most likely. [Stopwatch] is
  /// backed by a monotonic platform clock and is immune to such jumps.
  final Stopwatch _monotonic = Stopwatch()..start();

  /// Synchronous re-entry guard for [_performSync], paired with
  /// [_syncInProgress]. The Completer-based check is the canonical
  /// gate that lets concurrent callers converge on the same
  /// in-flight future, but it relies on the assignment of
  /// `_syncInProgress = completer` happening synchronously before
  /// the first `await`. This bool is set together with that
  /// assignment (and reset together with it in the finally block),
  /// inspected first, so any future refactor that accidentally
  /// widens the window between guard-check and Completer-set —
  /// or introduces an `await` before the Completer assignment — is
  /// still protected against same-microtask re-entry from
  /// observers, integrity events, or method-channel callbacks.
  ///
  /// Both fields are written together and read together; the
  /// guarded path in [_performSync] throws [StateError] if it ever
  /// observes the bool true with the Completer null, on the
  /// principle that an invariant break is better surfaced loudly
  /// than masked by a synthetic resolved future.
  ///
  /// Mirrors the `_CompletionGuard` pattern used inside
  /// [SyncEngine._completeSync] (PR #22 / `trusted_time-skj.2`):
  /// a synchronous flag that is checked and set together before
  /// the first await is the only structurally-correct way to
  /// catch re-entry that the Completer-based guard might miss
  /// after a future refactor.
  bool _syncEntryGuard = false;
  int? _offlineLastUtcMs;
  int? _offlineLastWallMs;
  // Idempotency guard for [dispose]. Composed inner resources have
  // mixed semantics — SyncClock and HttpsClient.close are
  // idempotent, but IntegrityMonitor's StreamController.close is
  // documented as idempotent in Dart's API but can throw under
  // older SDKs / unusual subclass overrides. Calling dispose twice
  // most commonly happens when [init] is called more than once
  // (init disposes the previous singleton first) and the consumer's
  // own teardown logic also calls dispose on the prior instance.
  // The guard makes that scenario safe regardless of SDK version.
  bool _disposed = false;

  // Runtime-mutable refresh schedule. Distinct from
  // [TrustedTimeConfig.refreshInterval] which captures the at-init
  // value and is never mutated. [_activeRefreshInterval] is what
  // [_scheduleRefresh] actually uses; consumers can override it via
  // [setRefreshInterval] without re-initialising the engine.
  // [_automaticRefreshPaused] suppresses the timer entirely
  // regardless of the interval value. Both default to a fresh-start
  // configuration on every [init] (pause state is intentionally not
  // persisted across re-init).
  late Duration _activeRefreshInterval = _config.refreshInterval;
  bool _automaticRefreshPaused = false;

  /// Documented.
  Stream<IntegrityEvent> get onIntegrityLost => _monitor.events;

  /// Documented.
  bool get isTrusted => _trusted;

  /// The currently active trust anchor.
  TrustAnchor? get anchor => _anchor;

  /// The [TrustedTimeConfig] this instance was constructed with.
  ///
  /// Exposed so callers can verify the live engine settings (server
  /// pool, quorum thresholds, refresh interval, etc.) without
  /// shadowing the configuration on the call site. The returned
  /// instance is the same object passed to [init]; reading
  /// list-typed fields like [TrustedTimeConfig.ntsServers] is safe
  /// without defensive copying as long as the caller honours
  /// [TrustedTimeConfig]'s "do not mutate after construction"
  /// contract.
  TrustedTimeConfig get config => _config;

  /// Whether the current trust anchor is cryptographically secure.
  bool get isSecure => _anchor?.authLevel == NtsAuthLevel.verified;

  /// The specific authentication level of the current time estimate.
  NtsAuthLevel get authLevel => _anchor?.authLevel ?? NtsAuthLevel.none;

  /// Registers an observer for synchronization events.
  void registerObserver(SyncObserver observer) => _observers.add(observer);

  /// Unregisters a synchronization observer.
  void unregisterObserver(SyncObserver observer) => _observers.remove(observer);

  /// Returns the current trusted UTC time. Synchronous — no I/O.
  DateTime now() {
    if (!_trusted || _anchor == null) {
      throw const TrustedTimeNotReadyException();
    }
    return DateTime.fromMillisecondsSinceEpoch(
      _anchor!.networkUtcMs + _syncClock.elapsedSinceAnchorMs(),
      isUtc: true,
    );
  }

  /// Documented.
  int nowUnixMs() => now().millisecondsSinceEpoch;

  /// Documented.
  String nowIso() => now().toIso8601String();

  /// Documented.
  TrustedTimeEstimate? nowEstimated() {
    int? baseUtcMs;
    int? baseWallMs;

    if (_anchor != null) {
      baseUtcMs = _anchor!.networkUtcMs;
      baseWallMs = _anchor!.wallMs;
    } else if (_offlineLastUtcMs != null && _offlineLastWallMs != null) {
      baseUtcMs = _offlineLastUtcMs;
      baseWallMs = _offlineLastWallMs;
    } else {
      return null;
    }

    final currentTime = testOverride != null
        ? testOverride!.now
        : DateTime.now();
    final wallElapsed = Duration(
      milliseconds: currentTime.millisecondsSinceEpoch - baseWallMs!,
    );
    final confidence = (1.0 - wallElapsed.inMinutes.abs() / 4320.0).clamp(
      0.0,
      1.0,
    );
    final driftFactor =
        _driftCalibrator.calibratedFactor ?? _config.oscillatorDriftFactor;
    final errorMs = (wallElapsed.inMilliseconds.abs() * driftFactor).round();

    return TrustedTimeEstimate(
      estimatedTime: DateTime.fromMillisecondsSinceEpoch(
        baseUtcMs! + wallElapsed.inMilliseconds,
        isUtc: true,
      ),
      confidence: confidence,
      estimatedError: Duration(milliseconds: errorMs),
    );
  }

  /// Forces an immediate network synchronization cycle, purging the current anchor.
  ///
  /// This is used during recovery phases or when the application level requires
  /// a fresh quorum (e.g. before a high-value financial transaction).
  Future<void> forceResync() async {
    _trusted = false;
    await _performSync();
  }

  /// Confirms the live trust anchor is still fresh using the validate
  /// tier (ADR 0006): a short burst of authenticated NTS queries against
  /// one source, keeping the lowest-RTT sample, with no consensus
  /// rebuild.
  ///
  /// Returns `true` when the probe agrees with the projected anchor to
  /// within [TrustedTimeConfig.maxAllowedUncertaintyMs], and `false`
  /// when the probe ran successfully but the anchor disagrees (the
  /// caller may then [forceResync]). A `false` return does **not**
  /// invalidate the anchor — a single disagreeing probe is a hint, not
  /// a verdict.
  ///
  /// Throws [TrustedTimeFreshnessProbeException] when the probe cannot
  /// be performed at all: no anchor has been established, no NTS source
  /// is available, or every query in the burst failed (see
  /// [SyncEngine.validate]).
  Future<bool> validateFreshness() async {
    // If a full establish cycle is already running, a separate probe
    // would only contend with it for the same NTS client. Defer to the
    // cycle: an anchor it establishes is, by definition, fresher than
    // any probe could prove.
    final inFlight = _syncInProgress;
    if (inFlight != null) {
      await inFlight.future;
      if (_trusted && _anchor != null) return true;
      throw const TrustedTimeFreshnessProbeException(
        'Freshness probe deferred to an in-flight sync that did not '
        'establish a trust anchor.',
      );
    }

    if (!_trusted || _anchor == null) {
      throw const TrustedTimeFreshnessProbeException(
        'No established trust anchor to validate. Await initialize() '
        '(or forceResync()) so an establish cycle can build an anchor '
        'before probing freshness.',
      );
    }

    final sample = await _syncEngine.validate();

    // Project the anchor to "now" using the same monotonic arithmetic
    // as now(), then compare against the probe's midpoint. The few ms
    // between the probe returning and this projection are bounded by
    // post-query processing and are negligible against
    // maxAllowedUncertaintyMs.
    final projectedNowMs =
        _anchor!.networkUtcMs + _syncClock.elapsedSinceAnchorMs();
    final offsetMs = (projectedNowMs - sample.interval.midpoint).abs();
    return offsetMs <= _config.maxAllowedUncertaintyMs;
  }

  /// Enables background synchronization to keep trust anchors fresh.
  ///
  /// **Android/iOS**: delegates to the native scheduler (WorkManager /
  /// BGTaskScheduler). A background fire performs a real headless anchor
  /// refresh when the host has registered a callback via
  /// `TrustedTime.registerBackgroundCallback`; otherwise it falls back to
  /// a connectivity-only probe that does not refresh the anchor (ADR 0002).
  /// On iOS the host must additionally wire
  /// `TrustedTimePlugin.setPluginRegistrantCallback` in its AppDelegate so
  /// plugins can be registered onto the headless engine; without it the
  /// fire also falls back to the connectivity probe. Android needs no
  /// equivalent — the v2 embedding auto-registers plugins on engine
  /// creation.
  ///
  /// **Desktop** (Linux/macOS/Windows): a [Timer.periodic] inside the
  /// running isolate re-syncs at [interval] (honoured exactly — no floor).
  /// **Web**: no-op (browsers suspend background tabs).
  ///
  /// On Android/iOS [interval] is applied at minute resolution and clamped
  /// to `[15 min, 1 week]` to respect [WorkManager]'s hard periodic floor;
  /// the desktop timer path honours [interval] as given.
  Future<void> enableBackgroundSync(Duration interval) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (kDebugMode && interval.inMinutes < 15) {
        debugPrint(
          '[TrustedTime] Background sync interval below the platform '
          'scheduler floor (15 min); clamped up.',
        );
      }
      await _invokeBackgroundSync(interval);
    } else {
      _desktopBgTimer?.cancel();
      _desktopBgTimer = Timer.periodic(interval, (_) => _performSync());
    }
  }

  Future<void> _bootstrap() async {
    _listenForIntegrityEvents();
    _startTieredSchedulingIfNeeded();

    if (_config.persistState) {
      final lastKnown = await _store.loadLastKnown();
      if (lastKnown != null) {
        _offlineLastUtcMs = lastKnown.trustedUtcMs;
        _offlineLastWallMs = lastKnown.wallMs;
      }
    }

    // Eagerly prime per-source warm state (e.g., NTS cookie jars) so
    // that the first sync cycle's RTT measurements are not
    // contaminated by cold-start handshake latency. Sources without a
    // warm phase are unaffected. This adds the slowest source's
    // handshake time (typically ~hundreds of ms) to initialize() when
    // NTS sources are configured.
    await _syncEngine.warmAllSources();

    final persisted = _config.persistState ? await _store.load() : null;
    if (persisted != null) {
      final check = await _monitor.checkRebootOnWarmStart(persisted);
      if (!check.rebooted) {
        // Native uptime advances even when the process is not running.
        // Seed SyncClock with the gap so that `now()` accounts for time
        // elapsed since the anchor was captured, not just since this
        // process started.
        final elapsedSinceAnchor = check.currentUptimeMs - persisted.uptimeMs;
        _applyAnchor(persisted, initialElapsedMs: elapsedSinceAnchor);
        _trusted = true;
        _scheduleRefresh();
        if (_config.backgroundSyncInterval != null) {
          await enableBackgroundSync(_config.backgroundSyncInterval!);
        }
        return;
      }
    }

    await _performSync();
    if (_config.backgroundSyncInterval != null) {
      await enableBackgroundSync(_config.backgroundSyncInterval!);
    }
  }

  /// Whether the host platform supports cryptographically secure time (NTS).
  bool get supportsSecureTime => _config.ntsServers.isNotEmpty;

  /// Initializes the integrity monitoring loop.
  ///
  /// We proactively listen for system-level anomalies (clock jumps, reboots).
  /// If an anomaly is detected, we immediately invalidate the cache and
  /// enter a high-priority recovery cycle to re-establish a trust anchor.
  void _listenForIntegrityEvents() {
    _integritySub?.cancel();
    _integritySub = _monitor.events.listen((event) {
      if (event.reason == TamperReason.systemClockJumped ||
          event.reason == TamperReason.deviceRebooted) {
        _trusted = false;

        // Critical: Purge cache and drift calibration on anomaly. Stale drift
        // observations spanning a clock jump or reboot are invalid.
        _cache.clear();
        _driftCalibrator.reset();

        // Trigger an immediate background sync to recover trust.
        unawaited(_performSync());
      }
    });
  }

  Future<void> _performSync() async {
    // Two-tier in-flight guard. The synchronous bool [_syncEntryGuard]
    // is checked first and set together with [_syncInProgress] before
    // any line that could yield to the event loop, so same-microtask
    // re-entry from observers, integrity events, or method-channel
    // callbacks cannot pass the gate. The Completer-based guard
    // exists in addition so concurrent callers receive the same
    // in-flight future and complete together when the cycle resolves.
    //
    // Both are reset together in the finally block, so the bool and
    // Completer are always observably in sync. If they ever diverge
    // (bool true, Completer null), that is a structural lifecycle
    // bug — fail loud with a [StateError] rather than silently
    // returning a resolved future, which would tell the caller a
    // sync succeeded when in fact the engine state machine is
    // corrupted. See the [_syncEntryGuard] field dartdoc for the
    // broader rationale.
    if (_syncEntryGuard || _syncInProgress != null) {
      final inFlight = _syncInProgress;
      if (inFlight != null) return inFlight.future;
      throw StateError(
        '_performSync invariant broken: _syncEntryGuard is true but '
        '_syncInProgress is null. Both fields are set and reset '
        'together in this method; observing one without the other '
        'indicates the engine state machine has been corrupted by '
        'an out-of-band mutation or a partial-cleanup bug.',
      );
    }
    _syncEntryGuard = true;
    final completer = Completer<void>();
    _syncInProgress = completer;
    _retryTimer?.cancel();
    // Pair cancel() with = null here too, so a retry timer that has
    // already fired into this method (its callback is _performSync)
    // does not leave the field pointing at a spent Timer. Together
    // with _scheduleRetry this keeps "_retryTimer == null" a reliable
    // "no retry armed" signal at every site, matching _refreshTimer.
    _retryTimer = null;
    // Cancel any pending automatic refresh as well: without this, a
    // _refreshTimer armed by a prior successful cycle could fire
    // moments after this cycle completes — the in-flight guard above
    // only catches overlap, not the "stale refresh fires shortly
    // after manual sync clears the guard" case. _scheduleRefresh in
    // the success branch re-arms a fresh window from this cycle's
    // completion.
    //
    // Pair cancel() with = null so the field never retains a
    // reference to a cancelled Timer between this point and the
    // next _scheduleRefresh / _scheduleRetry. Without this, a
    // failed sync would leave the field pointing at the cancelled
    // timer indefinitely (the catch path goes to _scheduleRetry,
    // not _scheduleRefresh, so the rebind in _scheduleRefresh would
    // not happen). Keeping the invariant uniform across all call
    // sites makes "_refreshTimer == null" a reliable signal for
    // diagnostics and any future introspection that depends on it.
    _refreshTimer?.cancel();
    _refreshTimer = null;
    try {
      // Shared query-and-bank unit (sync + persistState-gated save), so
      // the foreground and background paths produce and persist anchors
      // identically. Save runs before _applyAnchor: a storage failure
      // surfaces as a failed cycle rather than leaving in-memory state
      // ahead of what the next warm restore will read back.
      final anchor = await performSyncCycle(
        engine: _syncEngine,
        store: _store,
        config: _config,
      );
      _applyAnchor(anchor);
      _trusted = true;
      _offlineLastUtcMs = anchor.networkUtcMs;
      _offlineLastWallMs = anchor.wallMs;
      _scheduleRefresh();
    } catch (e) {
      if (kDebugMode) debugPrint('[TrustedTime] Sync failed: $e');
      _trusted = false;
      // Same transient/non-transient verdict as the background path
      // (see isTransientSyncError): only network-weather failures are
      // worth re-attempting. A non-transient error (e.g. ArgumentError
      // from an invalid config) would fail identically on every attempt,
      // so arming the retry timer would loop the same failure forever.
      if (isTransientSyncError(e)) {
        _scheduleRetry();
      }
    } finally {
      // Reset together so the bool and Completer stay observably in
      // sync. A future caller that arrives after this point sees
      // both cleared and starts a fresh cycle.
      _syncInProgress = null;
      _syncEntryGuard = false;
      completer.complete();
    }
  }

  void _applyAnchor(TrustAnchor anchor, {int initialElapsedMs = 0}) {
    _anchor = anchor;
    _syncClock.update(
      anchor.uptimeMs,
      anchor.wallMs,
      initialElapsedMs: initialElapsedMs,
    );
    _monitor.attach(anchor);
    _driftCalibrator.recordAnchor(anchor.wallMs, anchor.networkUtcMs);
  }

  void _scheduleRefresh() {
    // Always null out alongside cancel() so the field never retains a
    // reference to a cancelled Timer across the early-return paths
    // below. Mirrors pauseAutomaticRefresh's cancel/null pairing and
    // keeps "is _refreshTimer null?" a reliable signal of whether a
    // live timer is armed (used by introspection in tests / future
    // diagnostics).
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_automaticRefreshPaused) return;
    if (_activeRefreshInterval <= Duration.zero) return;
    _refreshTimer = Timer(_activeRefreshInterval, _performSync);
  }

  /// Whether automatic refresh is currently enabled.
  ///
  /// Reflects the schedule's intent — `false` when
  /// [pauseAutomaticRefresh] has been called or when
  /// [setRefreshInterval] was called with a non-positive duration —
  /// not whether [_refreshTimer] is armed at this exact moment.
  /// [_scheduleRefresh] is invoked from three sites: the success
  /// branch of [_performSync] (the *automatic* re-arm), and the
  /// explicit [resumeAutomaticRefresh] / [setRefreshInterval] entry
  /// points (which arm a fresh timer from the time of the call
  /// independent of cycle completion). This getter can therefore
  /// return `true` while no timer is yet pending — post-init pre-
  /// bootstrap, or in the recovery window after a failed sync where
  /// only the retry timer is armed.
  bool get automaticRefreshActive =>
      !_automaticRefreshPaused && _activeRefreshInterval > Duration.zero;

  /// The currently active refresh interval used by the automatic
  /// refresh timer.
  ///
  /// Defaults to [TrustedTimeConfig.refreshInterval] but may be
  /// overridden at runtime via [setRefreshInterval]. The original
  /// at-init value remains accessible via [config].
  Duration get activeRefreshInterval => _activeRefreshInterval;

  /// Pauses the automatic refresh timer.
  ///
  /// Cancels any pending refresh and prevents subsequent successful
  /// syncs from re-arming it. Idempotent. Does not affect the retry
  /// timer (recovery from a failed sync still proceeds) or
  /// integrity-event-driven syncs.
  void pauseAutomaticRefresh() {
    _automaticRefreshPaused = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// Resumes the automatic refresh timer using the active interval
  /// (see [activeRefreshInterval]).
  ///
  /// Arms a refresh timer immediately, scheduled for one active
  /// interval from the time of this call. Any previously-pending
  /// refresh timer is cancelled and re-armed. Calling this while
  /// already enabled therefore pushes the next-refresh deadline
  /// out — safe to call repeatedly without raising, but the
  /// deadline is not invariant. Use [automaticRefreshActive] to
  /// gate calls when that matters.
  ///
  /// The "from the time of the call" deadline is itself only the
  /// *initial* arming. [_performSync] cancels [_refreshTimer] at
  /// the start of every sync cycle and the success path calls
  /// [_scheduleRefresh] from cycle completion, so any sync that
  /// runs before the timer fires (driven by [forceResync], an
  /// integrity event, or [_invokeBackgroundSync]) shifts the
  /// effective next-refresh time to one active interval after that
  /// cycle's completion.
  ///
  /// The internal pause flag is always cleared, but if the active
  /// interval is non-positive (i.e. the schedule was last set via
  /// [setRefreshInterval] with [Duration.zero] or a negative value)
  /// no timer is scheduled — clearing the flag has no observable
  /// effect until [setRefreshInterval] is called with a positive
  /// duration.
  void resumeAutomaticRefresh() {
    _automaticRefreshPaused = false;
    _scheduleRefresh();
  }

  /// Replaces the active refresh interval at runtime.
  ///
  /// Arms a refresh timer immediately, scheduled for [interval]
  /// from the time of this call (any pending refresh is cancelled
  /// and re-armed). As with [resumeAutomaticRefresh], any sync that
  /// runs before the timer fires shifts the effective next-refresh
  /// time to one [interval] after that cycle's completion (because
  /// [_performSync] cancels [_refreshTimer] at cycle entry and the
  /// success branch re-arms via [_scheduleRefresh]).
  ///
  /// An [interval] of [Duration.zero] (or negative) is equivalent
  /// to [pauseAutomaticRefresh] — the timer is cancelled and not
  /// re-armed until [setRefreshInterval] is called again with a
  /// positive duration or [resumeAutomaticRefresh] is called (which
  /// re-arms with the most recent positive interval).
  void setRefreshInterval(Duration interval) {
    if (interval <= Duration.zero) {
      pauseAutomaticRefresh();
      return;
    }
    _activeRefreshInterval = interval;
    _automaticRefreshPaused = false;
    _scheduleRefresh();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    // Null alongside cancel() so the field never retains a reference to a
    // cancelled Timer on the no-retry path, matching _scheduleRefresh /
    // _scheduleValidate and keeping "_retryTimer == null" a reliable
    // "no retry armed" signal for diagnostics.
    _retryTimer = null;
    final delay = _syncEngine.getNextRetryDelay();
    if (delay > Duration.zero) {
      _retryTimer = Timer(delay, _performSync);
    }
  }

  /// Starts the tiered-cadence auxiliaries (ADR 0006): the periodic
  /// validate timer plus a self-installed [WidgetsBindingObserver] that
  /// runs a freshness probe when the app returns to the foreground after
  /// a long background. No-op under [CadenceMode.singleTier30m], so the
  /// legacy single-timer schedule is left bit-for-bit unchanged.
  void _startTieredSchedulingIfNeeded() {
    if (_config.cadenceMode != CadenceMode.tieredMobile) return;
    _scheduleValidate();
    if (kIsWeb) return;
    final observer = _AppLifecycleObserver(
      (state) => _handleAppLifecycleState(state, _monotonic.elapsed),
    );
    try {
      WidgetsBinding.instance.addObserver(observer);
      _lifecycleObserver = observer;
    } catch (e) {
      // No widgets binding (e.g. a headless background isolate). The
      // periodic validate timer still drives cadence; only the
      // foreground-resume trigger is unavailable in this context.
      if (kDebugMode) {
        debugPrint(
          '[TrustedTime] Foreground-validate observer not installed: $e',
        );
      }
    }
  }

  /// Arms the validate-tier timer (ADR 0006). Re-arms itself after each
  /// cycle completes so probes never overlap. No-op under
  /// [CadenceMode.singleTier30m] or when [TrustedTimeConfig.validateInterval]
  /// is non-positive.
  void _scheduleValidate() {
    _validateTimer?.cancel();
    _validateTimer = null;
    if (_disposed) return;
    if (_config.cadenceMode != CadenceMode.tieredMobile) return;
    final interval = _config.validateInterval;
    if (interval <= Duration.zero) return;
    _validateTimer = Timer(interval, () {
      // Fire-and-forget: the cycle re-arms the timer via whenComplete, so
      // the returned Future is intentionally not awaited. unawaited makes
      // that explicit and matches the other validate/sync call sites.
      unawaited(_runValidateCycle().whenComplete(_scheduleValidate));
    });
  }

  /// Runs one validate-tier freshness probe and escalates to a full
  /// establish cycle only if the probe positively disagrees with network
  /// time (ADR 0006).
  ///
  /// Tolerant by design: a probe that cannot run at all (no anchor yet,
  /// no NTS source, every burst query failed) is "freshness unknown",
  /// not a verdict — it is swallowed and the anchor and schedule are left
  /// intact, mirroring [validateFreshness]'s contract. A probe is also
  /// skipped while a full sync is already in flight, since an establish
  /// cycle supersedes a cheap probe, and while another validate cycle is
  /// already running, so the timer and foreground-resume entry points
  /// never issue overlapping bursts.
  Future<void> _runValidateCycle() async {
    if (_disposed) return;
    _validateCycleCount++;
    if (_syncInProgress != null) return;
    // Validate-in-flight guard. The periodic timer self-rearms only
    // after its cycle completes, so the timer path never overlaps
    // itself — but the foreground-resume trigger calls in independently
    // and can land while a timer-driven probe is still awaiting its NTS
    // burst. Without this guard the two entry points would issue
    // concurrent SyncEngine.validate() bursts, doubling radio/battery
    // use and contending on shared per-source state (e.g. NTS cookie
    // jars); the flag gives both paths the same non-overlap guarantee
    // the self-rearming timer already had on its own.
    if (_validateInProgress) return;
    _validateInProgress = true;
    bool fresh;
    try {
      fresh = await validateFreshness();
    } on TrustedTimeFreshnessProbeException {
      return;
    } catch (e) {
      if (kDebugMode) debugPrint('[TrustedTime] Validate probe error: $e');
      return;
    } finally {
      _validateInProgress = false;
    }
    if (!fresh && !_disposed && _syncInProgress == null) {
      unawaited(_performSync());
    }
  }

  /// Foreground-resume validate trigger (ADR 0006). Records the first
  /// non-resumed lifecycle transition as the background-entry reading on
  /// a monotonic clock, and on the next [AppLifecycleState.resumed] runs
  /// a validate cycle iff the app was backgrounded for at least
  /// [TrustedTimeConfig.foregroundValidateThreshold]. [now] is a
  /// monotonic elapsed reading (see [_monotonic]), never wall-clock time,
  /// so a backward clock jump can neither produce a negative duration nor
  /// suppress the probe. Gated on [CadenceMode.tieredMobile] so the
  /// legacy mode never reacts to lifecycle events.
  void _handleAppLifecycleState(AppLifecycleState state, Duration now) {
    if (_disposed) return;
    if (_config.cadenceMode != CadenceMode.tieredMobile) return;
    if (state == AppLifecycleState.resumed) {
      final since = _backgroundedElapsed;
      _backgroundedElapsed = null;
      if (since == null) return;
      // A negative threshold is nonsensical but cannot be rejected in the
      // `const` config constructor; normalize it to zero here so it means
      // "probe on every resume" rather than relying on the always-true
      // comparison against a negative bound.
      final threshold = _config.foregroundValidateThreshold.isNegative
          ? Duration.zero
          : _config.foregroundValidateThreshold;
      if (now - since >= threshold) {
        unawaited(_runValidateCycle());
      }
      return;
    }
    // Any non-resumed state means the app left the foreground. Keep the
    // first such reading (??=) so a burst of inactive/paused/hidden
    // callbacks does not reset the measured background duration.
    _backgroundedElapsed ??= now;
  }

  /// Whether the tiered-cadence validate timer is currently armed.
  @visibleForTesting
  bool get debugValidateTimerActive => _validateTimer != null;

  /// Whether the foreground-resume lifecycle observer is installed.
  @visibleForTesting
  bool get debugLifecycleObserverInstalled => _lifecycleObserver != null;

  /// Number of validate cycles attempted since construction.
  @visibleForTesting
  int get debugValidateCycleCount => _validateCycleCount;

  /// The desktop in-isolate periodic background-sync timer, if armed.
  ///
  /// Exposed as the [Timer] itself (rather than a bool) so tests can pin
  /// the replace-not-stack contract of repeated enableBackgroundSync
  /// calls by observing cancellation and identity of the old timer.
  @visibleForTesting
  Timer? get debugDesktopBgTimer => _desktopBgTimer;

  /// Whether the failed-sync retry timer is currently armed.
  ///
  /// Lets tests pin the transient/non-transient retry verdict: a failed
  /// cycle arms the retry timer only when the error is classified as
  /// transient by the shared [isTransientSyncError] predicate.
  @visibleForTesting
  bool get debugRetryTimerActive => _retryTimer != null;

  /// Drives the foreground-resume validate path deterministically in
  /// tests without a real [WidgetsBinding] lifecycle dispatch. [elapsed]
  /// overrides the monotonic reading used to measure background duration.
  @visibleForTesting
  void debugHandleAppLifecycleState(
    AppLifecycleState state, {
    Duration? elapsed,
  }) => _handleAppLifecycleState(state, elapsed ?? _monotonic.elapsed);

  static const _bgChannel = MethodChannel('trusted_time/background');

  /// Lower bound (minutes) enforced by the platform scheduler. Android's
  /// [WorkManager] rejects any periodic interval below 15 minutes
  /// (`PeriodicWorkRequest.MIN_PERIODIC_INTERVAL_MILLIS`); we mirror that
  /// floor here so the request the native layer receives is always
  /// schedulable and the clamp is visible to Dart-side tests.
  static const int _minBgSyncMinutes = 15;

  /// Upper bound (minutes) = one week, matching the previous 168h cap.
  static const int _maxBgSyncMinutes = 168 * 60;

  Future<void> _invokeBackgroundSync(Duration interval) async {
    // Round *up* to the next whole minute rather than truncating:
    // background sync is battery-sensitive OS work, so a leftover-seconds
    // interval (e.g. 15m59s) must never schedule *more* frequently than
    // the caller requested. Pure integer ceiling division — no double
    // conversion, so no precision loss for very large Durations.
    final minutes =
        (interval.inMicroseconds + Duration.microsecondsPerMinute - 1) ~/
        Duration.microsecondsPerMinute;
    try {
      await _bgChannel.invokeMethod<void>('enableBackgroundSync', {
        'intervalMinutes': minutes.clamp(_minBgSyncMinutes, _maxBgSyncMinutes),
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[TrustedTime] Background sync failed: $e');
    }
  }

  Future<void> _handleBackgroundMethodCall(MethodCall call) async {
    if (call.method == 'onBackgroundSync') await _performSync();
  }

  /// Documented.
  ///
  /// Idempotent: subsequent calls are no-ops. The composed inner
  /// resources have mixed disposal semantics, and the safest
  /// contract for consumers is "call dispose; we will sort out
  /// double-dispose for you" — particularly because [init] disposes
  /// the previous singleton on re-init and applications often have
  /// their own teardown logic that calls dispose on whatever
  /// instance they remember.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _desktopBgTimer?.cancel();
    _desktopBgTimer = null;
    _validateTimer?.cancel();
    _validateTimer = null;
    final observer = _lifecycleObserver;
    if (observer != null) {
      try {
        WidgetsBinding.instance.removeObserver(observer);
      } catch (_) {
        // Binding already torn down; nothing to detach.
      }
      _lifecycleObserver = null;
    }
    _integritySub?.cancel();
    _integritySub = null;
    _syncEngine.dispose();
    _monitor.dispose();
    _syncClock.dispose();
  }
}

class _ProxySyncObserver implements SyncObserver {
  _ProxySyncObserver(this._getObservers);
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

/// Forwards [WidgetsBindingObserver.didChangeAppLifecycleState] to a
/// callback so [TrustedTimeImpl] can self-install a foreground-resume
/// validate trigger (ADR 0006) without itself mixing in the observer.
class _AppLifecycleObserver with WidgetsBindingObserver {
  _AppLifecycleObserver(this._onState);
  final void Function(AppLifecycleState) _onState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onState(state);
}
