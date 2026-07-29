import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'models.dart';
import 'anchor_store.dart';
import 'exceptions.dart';
import 'integrity_monitor.dart';
import 'monotonic_clock.dart';
import 'sync_cycle.dart';
import 'sync_engine.dart';
import 'sources/nts_auth_level.dart';
import 'infra/app_lifecycle_observer.dart';
import 'infra/proxy_sync_observer.dart';
import 'infra/sync_observer.dart';
import 'infra/consensus_cache.dart';
import 'infra/refresh_scheduler.dart';
import 'infra/trusted_time_log.dart';
import 'drift_history.dart';
import 'time_assessment.dart';

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
       _clock = clock,
       _cache = ConsensusCache(),
       _syncClock = SyncClock(),
       _monitor = IntegrityMonitor(clock: clock) {
    _syncEngine = SyncEngine(
      config: config,
      clock: clock,
      // Bind the proxy observer to *this* instance's _observers set
      // rather than to the static _instance: during a re-initialize
      // the previous engine's teardown and the new bootstrap must not
      // observe each other through the shared static, and binding to
      // the instance keeps the observer set correct regardless of
      // when init() assigns _instance.
      observer: ProxySyncObserver(() => _observers),
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
    _instance = null;
    final impl = TrustedTimeImpl._(
      config: config,
      store: AnchorStore(),
      clock: PlatformMonotonicClock(),
    );
    // Assign the singleton *before* bootstrapping: _bootstrap() fires
    // the cold-start first sync detached, and that cycle is not
    // ordered against init() resuming — any path it triggers that
    // reads [instance] (observer callbacks, integrity events) must
    // find the live engine, not a null. The pre-detachment ordering
    // (assign after a fully-awaited bootstrap) would make those reads
    // assert.
    _instance = impl;
    try {
      await impl._bootstrap();
    } catch (_) {
      // Restore the "not initialized" posture before propagating: if
      // _bootstrap() throws (a fail-fast config gate), [instance] must
      // not hand out the disposed partial engine. dispose() also
      // releases its resources (sync engine, timers).
      _instance = null;
      impl.dispose();
      rethrow;
    }
    _bgChannel.setMethodCallHandler(impl._handleBackgroundMethodCall);
    return impl;
  }

  final TrustedTimeConfig _config;
  final AnchorStore _store;
  final MonotonicClock _clock;
  late final SyncEngine _syncEngine;
  final IntegrityMonitor _monitor;
  final ConsensusCache _cache;
  final SyncClock _syncClock;
  final DriftHistoryRecorder _driftHistory = DriftHistoryRecorder();
  final _observers = <SyncObserver>{};

  TrustAnchor? _anchor;
  bool _trusted = false;

  /// The [TrustStatusReason] to report while no live anchor exists.
  ///
  /// Only read by [getAssessment] on the unanchored path (`!_trusted ||
  /// _anchor == null`); anchored postures derive their reason from the
  /// anchor itself. Transition sites: [rebootDetected] is set during
  /// [_bootstrap] when a persisted anchor is discarded (R5) and takes
  /// precedence over subsequent failed syncs; a successful cycle resets
  /// the field to [TrustStatusReason.syncFailed], which is never read
  /// while anchored but primes the correct reason for any later lost
  /// trust (failed refresh, or the in-flight window of [forceResync]).
  TrustStatusReason _unanchoredReason = TrustStatusReason.neverSynced;
  Timer? _desktopBgTimer;
  Completer<void>? _syncInProgress;

  /// Completes when the first sync cycle concludes (see
  /// [firstSyncSettled]). Settled via [_settleFirstSync] from exactly
  /// three sites: the warm-restore return in [_bootstrap] (no cycle
  /// needed), the conclusion of the detached first cycle fired by the
  /// cold path, and [dispose] (so a waiter never hangs on an engine
  /// that was torn down before its first cycle concluded).
  final Completer<void> _firstSyncSettled = Completer<void>();

  // Resume anchor-age check: installed at bootstrap wherever a live
  // widgets binding exists, so returning to the foreground with a
  // stale (or absent) anchor triggers a full sync immediately instead
  // of waiting for the next refresh tick.
  WidgetsBindingObserver? _lifecycleObserver;

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
  // Idempotency guard for [dispose]. Composed inner resources have
  // mixed semantics — SyncClock.close is
  // idempotent, but IntegrityMonitor's StreamController.close is
  // documented as idempotent in Dart's API but can throw under
  // older SDKs / unusual subclass overrides. Calling dispose twice
  // most commonly happens when [init] is called more than once
  // (init disposes the previous singleton first) and the consumer's
  // own teardown logic also calls dispose on the prior instance.
  // The guard makes that scenario safe regardless of SDK version.
  bool _disposed = false;

  // Owns the automatic-refresh and failed-sync retry timers, seeded
  // from [TrustedTimeConfig.refreshInterval] which captures the
  // at-init value and is never mutated; consumers override the live
  // cadence via [setRefreshInterval] without re-initialising the
  // engine. Constructed fresh per instance, so pause state is
  // intentionally not persisted across re-init.
  late final RefreshScheduler _scheduler = RefreshScheduler(
    initialInterval: _config.refreshInterval,
    onTick: _performSync,
  );

  /// Whether a live trust anchor exists (assessment postures
  /// [TrustStatusReason.synchronized] / [TrustStatusReason.degraded]).
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

  /// Whether the projection behind [now] rides a sleep-aware monotonic
  /// timeline. See [TrustedTimeConfig.requireSleepAwareProjection] for
  /// the two timelines and their failure modes.
  bool get isProjectionSleepAware => _syncClock.isSleepAware;

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
    _enforceSleepAwareProjection();
    return DateTime.fromMillisecondsSinceEpoch(
      _anchor!.networkUtcMs + _syncClock.elapsedSinceAnchorMs(),
      isUtc: true,
    );
  }

  /// Defence-in-depth gate shared by [now] and [getAssessment].
  ///
  /// The init-time gate makes this unreachable in practice; it stays
  /// so a projection can never silently ride a suspend-frozen timeline
  /// under the hard requirement — even if a future re-anchor path
  /// resolves a different reader than init saw.
  void _enforceSleepAwareProjection() {
    if (_config.requireSleepAwareProjection && !_syncClock.isSleepAware) {
      throw const TrustedTimeSecurityException(
        'requireSleepAwareProjection is set but the active projection '
        'rides a suspend-frozen Stopwatch timeline: the nts bridge is '
        'not initialized, so projected time would silently fall behind '
        'by the duration of any device sleep. Configure reachable '
        'ntsServers (whose FFI bootstrap must succeed) or relax the '
        'requirement.',
      );
    }
  }

  /// Minimum observed span (on the network-UTC timeline) before the
  /// current boot's drift rate is trusted for correction: shorter
  /// windows are dominated by per-anchor consensus noise rather than
  /// genuine oscillator drift.
  static const _kMinDriftCorrectionSpan = Duration(hours: 1);

  /// Largest drift-rate magnitude accepted for correction: 200 ppm.
  /// Real oscillators sit around 5–50 ppm, so anything beyond this
  /// bound indicates corrupt or semantically-implausible persisted
  /// history rather than genuine drift — and rates near or below -1
  /// would make the `elapsed / (1 + rate)` projection blow up.
  static const _kMaxDriftRateMagnitude = 0.0002;

  /// Builds the unified [TimeAssessment] snapshot for the current
  /// instant — time, posture reason, and caveats, all evaluated at one
  /// moment on the same monotonic timeline as [now].
  ///
  /// Never throws for posture reasons: an unanchored engine yields an
  /// assessment with `time == null` and the active [TrustStatusReason]
  /// rather than [TrustedTimeNotReadyException]. The only throwing path
  /// is the [TrustedTimeConfig.requireSleepAwareProjection] defence-in-
  /// depth gate shared with [now] (unreachable in practice — see [now]).
  TimeAssessment getAssessment() {
    final anchor = _anchor;
    if (_trusted && anchor != null) {
      _enforceSleepAwareProjection();
      // One monotonic read: time, anchorAge, uncertainty and the drift
      // pair all derive from the same elapsed value, so the snapshot
      // truly describes a single instant.
      final elapsedMs = _syncClock.elapsedSinceAnchorMs();
      final time = DateTime.fromMillisecondsSinceEpoch(
        anchor.networkUtcMs + elapsedMs,
        isUtc: true,
      );
      final rate = _currentBootDriftRate(anchor);
      return TimeAssessment(
        reason: anchor.authLevel == NtsAuthLevel.verified
            ? TrustStatusReason.synchronized
            : TrustStatusReason.degraded,
        authLevel: anchor.authLevel,
        confidence: anchor.confidence,
        time: time,
        uncertainty: Duration(milliseconds: anchor.uncertaintyMs),
        anchorAge: Duration(milliseconds: elapsedMs),
        driftRate: rate,
        driftCorrectedTime: rate == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                anchor.networkUtcMs + (elapsedMs / (1 + rate)).round(),
                isUtc: true,
              ),
        syncInProgress: _syncActivity,
      );
    }
    return TimeAssessment(
      reason: _unanchoredReason,
      authLevel: NtsAuthLevel.none,
      confidence: ConfidenceLevel.none,
      syncInProgress: _syncActivity,
    );
  }

  /// Resolves the drift rate usable for correction: the newest history
  /// record's observed rate, iff that record belongs to the live
  /// anchor's boot session, its observed span crosses
  /// [_kMinDriftCorrectionSpan], and the rate is finite with magnitude
  /// within [_kMaxDriftRateMagnitude] (persisted history is only
  /// syntactically validated, so a semantically-corrupt record must
  /// not reach the projection). Prior boots' rates are diagnostics
  /// only ([driftHistory]) — never applied across a reboot.
  double? _currentBootDriftRate(TrustAnchor anchor) {
    final bootId = anchor.bootId;
    if (bootId == null) return null;
    final records = _driftHistory.records;
    if (records.isEmpty) return null;
    final newest = records.last;
    if (newest.bootId != bootId) return null;
    if (newest.span < _kMinDriftCorrectionSpan) return null;
    final rate = newest.observedDriftRate;
    if (rate == null || !rate.isFinite) return null;
    if (rate.abs() > _kMaxDriftRateMagnitude) return null;
    return rate;
  }

  /// Backs [TimeAssessment.syncInProgress]. A cycle guarded by
  /// [_syncInProgress] counts, and so does the detached first-sync
  /// chain before its cycle reaches _performSync (its warm phase):
  /// a caller sampling right after initialize() must read the cold
  /// start as "resolution imminent", not as a concluded posture.
  bool get _syncActivity =>
      _syncInProgress != null || !_firstSyncSettled.isCompleted;

  /// The recorded per-boot drift history, oldest → newest. Backs
  /// `TrustedTime.getDriftHistory()`.
  List<DriftBootRecord> get driftHistory => _driftHistory.records;

  /// Forces an immediate network synchronization cycle, purging the current anchor.
  ///
  /// This is used during recovery phases or when the application level requires
  /// a fresh quorum (e.g. before a high-value financial transaction).
  Future<void> forceResync() async {
    _trusted = false;
    await _performSync();
  }

  /// Enables background synchronization to keep trust anchors fresh.
  ///
  /// **Android/iOS**: delegates to the native scheduler (WorkManager /
  /// BGTaskScheduler). A background fire performs a real headless anchor
  /// refresh when the host has registered a callback via
  /// `TrustedTime.registerBackgroundCallback`; otherwise the fire is a
  /// no-op that performs no network activity and does not refresh the
  /// anchor (ADR 0002). On iOS the host must additionally wire
  /// `TrustedTimePlugin.setPluginRegistrantCallback` in its AppDelegate so
  /// plugins can be registered onto the headless engine; without it the
  /// fire is also a no-op. Android needs no equivalent — the v2 embedding
  /// auto-registers plugins on engine creation.
  ///
  /// **Desktop** (Linux/macOS/Windows): a [Timer.periodic] inside the
  /// running isolate re-syncs at [interval] (honoured exactly — no floor).
  ///
  /// On Android/iOS [interval] is applied at minute resolution and clamped
  /// to `[15 min, 1 week]` to respect [WorkManager]'s hard periodic floor;
  /// the desktop timer path honours [interval] as given.
  Future<void> enableBackgroundSync(Duration interval) async {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (interval.inMinutes < 15) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
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
    // Fail-fast gate for the sleep-aware hard requirement: by this
    // point the nts bridge bootstrap (ensureNtsRuntime) has already
    // run — including the degrade path that strips ntsServers on a
    // genuine init failure — so the reader the engine will project on
    // is decidable now. Surfacing the misconfiguration here, before
    // any sync or persistence work, beats throwing from the first
    // now() call at an arbitrary point in the consumer's runtime.
    if (_config.requireSleepAwareProjection && !_syncClock.isSleepAware) {
      throw const TrustedTimeSecurityException(
        'requireSleepAwareProjection is set but no sleep-aware '
        'monotonic clock is available: the nts bridge is not '
        'initialized (NTP-only config, or the bridge '
        'bootstrap failed and NTS was disabled). Projection would '
        'silently freeze during device sleep. Configure reachable '
        'ntsServers (whose FFI bootstrap must succeed) or relax the '
        'requirement.',
      );
    }

    // Second fail-fast gate: trust-config validation. The getter
    // throws ArgumentError on usePlatformTrust + customRootCerts.
    // Before the first sync was detached, the cold path's *awaited*
    // warm call surfaced this through the engine's lazy _sources
    // initializer; with that cycle now backgrounded, nothing on the
    // initialize() critical path would touch _sources at all. Evaluate
    // eagerly so a misconfiguration throws synchronously from
    // initialize() on every path — the error split the API documents:
    // config errors throw, network outcomes never do.
    final _ = _config.effectiveTrustMode;

    _installLifecycleObserver();

    if (_config.persistState) {
      // Restore the drift history before the anchor: a warm-restored
      // anchor re-applied by _applyAnchor below must land on the loaded
      // history (dedup against the persisted latest pair), not on an
      // empty recorder that would double-count it.
      _driftHistory.restore(await _store.loadDriftHistory());
      // Seed the engine's source-quality tracker before any sync cycle
      // runs, so the very first cycle already ranks servers on the
      // accumulated RTT/success history instead of starting blind.
      _syncEngine.restoreSourceStats(await _store.loadSourceStats());
    }

    // The persisted-anchor restore check runs before any network-bound
    // work: on the most common startup path — warm start with a valid
    // anchor and no reboot — nothing below needs warm source state, so
    // initialize() stays storage-read-bound instead of paying NTS-KE
    // handshake wall time for warmth only the next refresh (minutes
    // away) would use.
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
        _scheduler.scheduleRefresh();
        if (_config.backgroundSyncInterval != null) {
          await enableBackgroundSync(_config.backgroundSyncInterval!);
        }
        // No first cycle is needed on a warm restore: the engine is
        // already anchored, so a firstSyncSettled waiter has its
        // answer now.
        _settleFirstSync();
        // Prime per-source warm state (e.g., NTS cookie jars) in the
        // background so the scheduled refresh cycle finds warmed
        // sources, without holding up the already-restored
        // initialize(). warmAllSources() swallows per-source warm()
        // failures internally; the eager effectiveTrustMode gate above
        // has already ruled out the lazy _sources initializer's
        // ArgumentError. The catchError stays as defence in depth —
        // this warm-up is strictly best-effort and an unawaited future
        // must never surface an unhandled async exception. Warm
        // futures are memoized, so the refresh cycle's warming
        // barrier re-joins (or has already joined) the same work.
        unawaited(
          Future.sync(_syncEngine.warmAllSources).catchError((
            Object e,
            StackTrace s,
          ) {
            if (TrustedTimeLog.enabled) {
              TrustedTimeLog.log(
                TrustedTimeLogLevel.warning,
                '[TrustedTime] Background bootstrap warm-up failed: $e\n$s',
              );
            }
          }),
        );
        return;
      }
      // R5: the persisted anchor was discarded because the device
      // rebooted since it was captured. Record the reason before the
      // fresh sync below — it must survive a failed first cycle
      // (getAssessment keeps reporting rebootDetected, not syncFailed,
      // until a sync succeeds).
      _unanchoredReason = TrustStatusReason.rebootDetected;
    }

    // Cold path (no restorable anchor): fire the first sync cycle
    // detached so initialize() resolves after local work only — the
    // caller observes the wait state through getAssessment()
    // (unanchored + syncInProgress) or awaits [firstSyncSettled] for
    // its conclusion. The warm-then-sync ordering inside the detached
    // chain is preserved: eagerly priming per-source warm state keeps
    // the first cycle's RTT measurements free of cold-start handshake
    // latency, and the wait stays bounded by warmBarrierCap (warm
    // futures are memoized and not cancellable, so on timeout the wait
    // is abandoned — not the handshake — and the cycle's Phase A JIT
    // warm re-joins the same future under the maxLatency budget).
    //
    // The chain cannot surface an unhandled async exception: the
    // eager effectiveTrustMode gate in init() has already ruled out
    // the lazy _sources initializer's ArgumentError, warmAllSources()
    // swallows per-source warm() failures, and _performSync() catches
    // every cycle failure internally (recordFailure + retry
    // scheduling). The catchError is defence in depth for anything
    // that slips past those layers, and _settleFirstSync() in the
    // whenComplete resolves [firstSyncSettled] on success and failure
    // alike — it reports conclusion, not outcome.
    //
    // The chain can outlive the engine: dispose() may run while the
    // warm phase is still in flight. The _disposed checks before each
    // phase stop a torn-down engine from starting network work or
    // re-arming timers (dispose has already settled firstSyncSettled,
    // so bailing out early cannot strand a waiter). A phase already
    // past its check merely runs to completion against inert state —
    // dispose cancels timers and _performSync's failure path re-checks
    // _disposed before scheduling a retry.
    unawaited(
      Future.sync(() async {
            if (_disposed) return;
            await _syncEngine.warmAllSources().timeout(
              SyncEngine.warmBarrierCap,
              onTimeout: () {},
            );
            if (_disposed) return;
            await _performSync();
          })
          .catchError((Object e, StackTrace s) {
            if (TrustedTimeLog.enabled) {
              TrustedTimeLog.log(
                TrustedTimeLogLevel.warning,
                '[TrustedTime] Detached first sync cycle failed: $e\n$s',
              );
            }
          })
          .whenComplete(_settleFirstSync),
    );
    if (_config.backgroundSyncInterval != null) {
      await enableBackgroundSync(_config.backgroundSyncInterval!);
    }
  }

  /// Resolves [firstSyncSettled] exactly once; later calls are no-ops
  /// (e.g. dispose() racing the detached first cycle's whenComplete).
  void _settleFirstSync() {
    if (!_firstSyncSettled.isCompleted) _firstSyncSettled.complete();
  }

  /// Completes when the engine's first sync cycle has concluded —
  /// success or failure alike. See [TrustedTime.firstSyncSettled] for
  /// the full contract.
  Future<void> get firstSyncSettled => _firstSyncSettled.future;

  /// Whether the host platform supports cryptographically secure time (NTS).
  bool get supportsSecureTime => _config.ntsServers.isNotEmpty;

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
    // Clear both timers for the duration of this cycle. The retry
    // timer may have fired into this very method, and a refresh armed
    // by a prior successful cycle could otherwise fire moments after
    // this one completes — the in-flight guard above only catches
    // overlap, not that case. The success branch re-arms a fresh
    // refresh window from this cycle's completion.
    _scheduler.cancelPending();
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
      // The anchor's readings are backdated to the consensus reference
      // instant (see SyncEngine._createAnchor), so the projection must
      // be seeded with the gap between that instant and now — the same
      // uptime arithmetic the warm-restore path uses. Without the seed,
      // elapsed time would start at zero *now* while networkUtcMs is
      // valid at the (older) reference instant, re-introducing the age
      // skew the backdating removed.
      final uptimeNow = await _clock.uptimeMs();
      final gapMs = uptimeNow - anchor.uptimeMs;
      _applyAnchor(anchor, initialElapsedMs: gapMs > 0 ? gapMs : 0);
      _trusted = true;
      // A successful cycle retires any rebootDetected/neverSynced
      // posture; from here on, losing trust means a failed cycle.
      _unanchoredReason = TrustStatusReason.syncFailed;
      _scheduler.scheduleRefresh();
    } catch (e) {
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] Sync failed: $e',
        );
      }
      _trusted = false;
      // rebootDetected outranks syncFailed: a failed cycle after a
      // detected reboot keeps reporting the reboot until one succeeds.
      if (_unanchoredReason != TrustStatusReason.rebootDetected) {
        _unanchoredReason = TrustStatusReason.syncFailed;
      }
      // Same transient/non-transient verdict as the background path
      // (see isTransientSyncError): only network-weather failures are
      // worth re-attempting. A non-transient error (e.g. ArgumentError
      // from an invalid config) would fail identically on every attempt,
      // so arming the retry timer would loop the same failure forever.
      if (isTransientSyncError(e)) {
        _scheduler.scheduleRetry(_syncEngine.getNextRetryDelay());
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
    // Passive drift-history bookkeeping. recordAnchor is synchronous
    // and dedups warm-restore re-applies, so persistence is only paid
    // when the history actually changed. The write is fire-and-forget:
    // _applyAnchor must stay synchronous, and history is pure
    // diagnostics — a lost write costs one observation, never trust.
    final changed = _driftHistory.recordAnchor(
      uptimeMs: anchor.uptimeMs,
      networkUtcMs: anchor.networkUtcMs,
      bootId: anchor.bootId,
    );
    if (changed && _config.persistState) {
      unawaited(
        _store.saveDriftHistory(_driftHistory.records).catchError((
          Object e,
          StackTrace s,
        ) {
          if (TrustedTimeLog.enabled) {
            TrustedTimeLog.log(
              TrustedTimeLogLevel.warning,
              '[TrustedTime] Drift history persistence failed: $e\n$s',
            );
          }
        }),
      );
    }
  }

  /// Whether automatic refresh is currently enabled.
  ///
  /// Reflects the schedule's intent — `false` when
  /// [pauseAutomaticRefresh] has been called or when
  /// [setRefreshInterval] was called with a non-positive duration —
  /// not whether a refresh timer is armed at this exact moment.
  /// [RefreshScheduler.scheduleRefresh] is invoked from three sites:
  /// the success branch of [_performSync] (the *automatic* re-arm),
  /// and the explicit [resumeAutomaticRefresh] / [setRefreshInterval]
  /// entry points (which arm a fresh timer from the time of the call
  /// independent of cycle completion). This getter can therefore
  /// return `true` while no timer is yet pending — post-init pre-
  /// bootstrap, or in the recovery window after a failed sync where
  /// only the retry timer is armed.
  ///
  /// `false` guarantees the engine initiates no anchor-age-driven
  /// syncs: both the refresh timer and the resume-time staleness
  /// check ([_handleAppLifecycleState]) are gated on this value. The
  /// unanchored resume *establish* attempt, the failed-sync retry
  /// timer, integrity-event-driven syncs, and background sync are
  /// intentionally outside this contract.
  bool get automaticRefreshActive => _scheduler.automaticRefreshActive;

  /// The currently active refresh interval used by the automatic
  /// refresh timer.
  ///
  /// Defaults to [TrustedTimeConfig.refreshInterval] but may be
  /// overridden at runtime via [setRefreshInterval]. The original
  /// at-init value remains accessible via [config].
  Duration get activeRefreshInterval => _scheduler.activeInterval;

  /// Pauses the automatic refresh timer.
  ///
  /// Cancels any pending refresh and prevents subsequent successful
  /// syncs from re-arming it. Idempotent. Does not affect the retry
  /// timer (recovery from a failed sync still proceeds) or
  /// integrity-event-driven syncs.
  void pauseAutomaticRefresh() => _scheduler.pause();

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
  /// *initial* arming. [_performSync] cancels the refresh timer at
  /// the start of every sync cycle and the success path re-arms from
  /// cycle completion, so any sync that runs before the timer fires
  /// (driven by [forceResync], an integrity event, or
  /// [_invokeBackgroundSync]) shifts the effective next-refresh time
  /// to one active interval after that cycle's completion.
  ///
  /// The internal pause flag is always cleared, but if the active
  /// interval is non-positive (i.e. the schedule was last set via
  /// [setRefreshInterval] with [Duration.zero] or a negative value)
  /// no timer is scheduled — clearing the flag has no observable
  /// effect until [setRefreshInterval] is called with a positive
  /// duration.
  void resumeAutomaticRefresh() => _scheduler.resume();

  /// Replaces the active refresh interval at runtime.
  ///
  /// Arms a refresh timer immediately, scheduled for [interval]
  /// from the time of this call (any pending refresh is cancelled
  /// and re-armed). As with [resumeAutomaticRefresh], any sync that
  /// runs before the timer fires shifts the effective next-refresh
  /// time to one [interval] after that cycle's completion (because
  /// [_performSync] cancels the refresh timer at cycle entry and the
  /// success branch re-arms it).
  ///
  /// An [interval] of [Duration.zero] (or negative) is equivalent
  /// to [pauseAutomaticRefresh] — the timer is cancelled and not
  /// re-armed until [setRefreshInterval] is called again with a
  /// positive duration or [resumeAutomaticRefresh] is called (which
  /// re-arms with the most recent positive interval).
  void setRefreshInterval(Duration interval) =>
      _scheduler.setInterval(interval);

  /// Installs the resume-time anchor-age check: a self-installed
  /// [WidgetsBindingObserver] that runs a full sync when the app
  /// returns to the foreground with a stale (or absent) anchor.
  void _installLifecycleObserver() {
    final observer = AppLifecycleObserver(_handleAppLifecycleState);
    try {
      WidgetsBinding.instance.addObserver(observer);
      _lifecycleObserver = observer;
    } catch (e) {
      // No widgets binding (e.g. a headless background isolate). The
      // periodic refresh timer still drives cadence; only the
      // foreground-resume trigger is unavailable in this context.
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.info,
          '[TrustedTime] Resume anchor-age observer not installed: $e',
        );
      }
    }
  }

  /// Resume-time anchor-age check. On [AppLifecycleState.resumed], runs
  /// a full sync iff no trusted anchor exists or the anchor is at least
  /// one refresh interval old ([activeRefreshInterval], so a runtime
  /// [setRefreshInterval] override governs staleness here too). Anchor
  /// age is measured on the projection's monotonic timeline
  /// ([SyncClock.elapsedSinceAnchorMs]) — the same reading
  /// [TimeAssessment.anchorAge] reports — never wall-clock time, so a
  /// backward clock jump can neither hide staleness nor fabricate it.
  /// Other lifecycle states need no bookkeeping: staleness is a property
  /// of the anchor's age, not of how long the app was backgrounded.
  ///
  /// The staleness branch is gated on [automaticRefreshActive]: a
  /// paused schedule ([pauseAutomaticRefresh]) or a non-positive
  /// [activeRefreshInterval] (only reachable via a non-positive
  /// [TrustedTimeConfig.refreshInterval] at init — [setRefreshInterval]
  /// routes non-positive values to [pauseAutomaticRefresh] without
  /// touching the interval) means the integrator opted out of
  /// anchor-age-driven cadence, so an anchored engine never resyncs on
  /// resume, matching [RefreshScheduler.scheduleRefresh]'s
  /// suppressed-timer semantics
  /// and keeping `automaticRefreshActive == false` a reliable "no
  /// anchor-age-driven syncs" signal. The unanchored branch is
  /// unaffected by either condition: a resume with no anchor is an
  /// *establish* attempt (the resume analogue of the bootstrap cycle,
  /// which also runs regardless of the schedule), not a staleness
  /// refresh.
  void _handleAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state != AppLifecycleState.resumed) return;
    // An establish cycle already in flight supersedes the age check;
    // _performSync would only converge on the same in-flight future.
    if (_syncInProgress != null) return;
    if (_trusted && _anchor != null) {
      // Staleness refreshes are suppressed while paused and disabled
      // outright when the interval is non-positive — exactly the two
      // conditions automaticRefreshActive folds together. Without the
      // interval half, `age < interval` below would never hold and
      // every resume would resync.
      if (!automaticRefreshActive) return;
      final age = Duration(milliseconds: _syncClock.elapsedSinceAnchorMs());
      if (age < activeRefreshInterval) return;
    }
    unawaited(_performSync());
  }

  /// Whether the foreground-resume lifecycle observer is installed.
  @visibleForTesting
  bool get debugLifecycleObserverInstalled => _lifecycleObserver != null;

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
  bool get debugRetryTimerActive => _scheduler.retryTimerActive;

  /// Drives the resume anchor-age check deterministically in tests
  /// without a real [WidgetsBinding] lifecycle dispatch.
  @visibleForTesting
  void debugHandleAppLifecycleState(AppLifecycleState state) =>
      _handleAppLifecycleState(state);

  /// Cancels any pending refresh timer *without* pausing the schedule.
  ///
  /// Lets tests isolate the resume-time staleness trigger from the
  /// refresh timer while keeping [automaticRefreshActive] true —
  /// [pauseAutomaticRefresh] cannot serve that purpose because pause
  /// suppresses the resume trigger too.
  @visibleForTesting
  void debugCancelRefreshTimer() => _scheduler.cancelRefreshTimer();

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
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.warning,
          '[TrustedTime] Background sync failed: $e',
        );
      }
    }
  }

  Future<void> _handleBackgroundMethodCall(MethodCall call) async {
    // Defence in depth alongside the handler unbind in [dispose]: a
    // callback already dispatched (in flight on the platform thread)
    // when dispose ran must not drive a sync on a disposed engine.
    if (_disposed) return;
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
    // A firstSyncSettled waiter must never hang on an engine torn down
    // before its first cycle concluded (the detached cycle's own
    // whenComplete may still fire later; _settleFirstSync is
    // idempotent).
    _settleFirstSync();
    // Detach the static background-channel handler so platform
    // callbacks (onBackgroundSync) can never invoke a disposed
    // engine. Only the live engine ever reaches this line — stale
    // references are already _disposed and return above — and [init]
    // re-binds the handler only after a successful bootstrap, so a
    // failed re-initialize leaves the channel cleanly unbound.
    _bgChannel.setMethodCallHandler(null);
    _scheduler.dispose();
    _desktopBgTimer?.cancel();
    _desktopBgTimer = null;
    final observer = _lifecycleObserver;
    if (observer != null) {
      try {
        WidgetsBinding.instance.removeObserver(observer);
      } catch (_) {
        // Binding already torn down; nothing to detach.
      }
      _lifecycleObserver = null;
    }
    _syncEngine.dispose();
    _syncClock.dispose();
  }
}
