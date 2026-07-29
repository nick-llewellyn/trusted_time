import 'package:flutter/widgets.dart';

/// Forwards [WidgetsBindingObserver.didChangeAppLifecycleState] to a
/// callback so a caller can self-install the resume-time anchor-age
/// check without itself mixing in the observer.
class AppLifecycleObserver with WidgetsBindingObserver {
  /// Creates an observer that forwards each state change to [onState].
  AppLifecycleObserver(void Function(AppLifecycleState) onState)
    : _onState = onState;

  final void Function(AppLifecycleState) _onState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onState(state);
}
