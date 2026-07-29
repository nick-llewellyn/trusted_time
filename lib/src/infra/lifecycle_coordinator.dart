import 'package:flutter/widgets.dart';

import 'app_lifecycle_observer.dart';
import 'trusted_time_log.dart';

/// Owns registration of the app-lifecycle observer against
/// [WidgetsBinding], and nothing else.
///
/// Deliberately a transport, not a policy: every state is forwarded
/// verbatim to the `onState` callback supplied at construction, with no
/// filtering for [AppLifecycleState.resumed] and no notion of what a
/// resume should trigger. That decision reads anchor age, trust status
/// and in-flight sync state — all private to the caller — so it stays
/// there. The callback is the only coupling back; as an instance
/// tear-off it does keep the caller reachable from here.
///
/// Both binding calls are guarded because [WidgetsBinding.instance]
/// throws when no binding exists: on [install] that is a headless
/// isolate with no widgets layer at all, and on [dispose] it is a
/// binding already torn down beneath a still-live caller. The two
/// cases warrant different handling and are documented at their sites.
class LifecycleCoordinator {
  /// Creates a coordinator that forwards every app-lifecycle state
  /// change to [onState] once [install] has succeeded.
  LifecycleCoordinator({required void Function(AppLifecycleState) onState})
    : _onState = onState;

  final void Function(AppLifecycleState) _onState;

  WidgetsBindingObserver? _observer;

  /// Whether the observer is currently registered with the binding.
  ///
  /// False both before [install] and after a failed one, so callers
  /// cannot distinguish "not yet installed" from "no binding here" —
  /// neither delivers lifecycle events, and no caller needs to.
  bool get installed => _observer != null;

  /// Registers the observer, tolerating the absence of a binding.
  ///
  /// A missing binding is not an error: a headless background isolate
  /// legitimately has no widgets layer, and only the foreground-resume
  /// trigger is lost there. The field is assigned after the binding
  /// accepts the observer, so a throw leaves [installed] false rather
  /// than claiming a registration that never happened.
  void install() {
    final observer = AppLifecycleObserver(_onState);
    try {
      WidgetsBinding.instance.addObserver(observer);
      _observer = observer;
    } catch (e) {
      if (TrustedTimeLog.enabled) {
        TrustedTimeLog.log(
          TrustedTimeLogLevel.info,
          '[TrustedTime] Resume anchor-age observer not installed: $e',
        );
      }
    }
  }

  /// Detaches the observer if one is registered.
  ///
  /// Idempotent, and safe to call after the binding has gone: the
  /// field is cleared whether or not the removal lands, so a torn-down
  /// binding cannot leave [installed] stuck true. Unlike [install]
  /// this failure is silent — a caller disposing during teardown has
  /// nowhere useful to route the log, and the observer it would warn
  /// about is unreachable either way.
  void dispose() {
    final observer = _observer;
    if (observer == null) return;
    try {
      WidgetsBinding.instance.removeObserver(observer);
    } catch (_) {
      // Binding already torn down; nothing to detach.
    }
    _observer = null;
  }
}
