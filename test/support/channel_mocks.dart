import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The secure-storage channel `AnchorStore` writes through.
const storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// The channel backing `MonotonicClock` (uptime and boot identity).
const monotonicChannel = MethodChannel('trusted_time/monotonic');

/// The channel backing background-sync scheduling.
const backgroundChannel = MethodChannel('trusted_time/background');

/// Installs null storage (persistence-free) and a fixed 1000ms uptime.
///
/// Groups that need richer behaviour install their own handlers and call
/// this from a `tearDown` to restore the defaults.
void installDefaultChannelHandlers() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(storageChannel, (call) async => null);
  messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
    if (call.method == 'getUptimeMs') return 1000;
    return null;
  });
  messenger.setMockMethodCallHandler(backgroundChannel, (call) async => null);
}

/// Binds [installDefaultChannelHandlers] to the calling file's lifecycle.
///
/// Flutter tests share one process, so the defaults go in via `setUpAll`
/// and come back out (set to null) in `tearDownAll`. Leaving them
/// installed past the calling file would leak into — and race with —
/// other test files that set handlers on the same channels, causing
/// order-dependent flakiness.
void useDefaultChannelHandlers() {
  setUpAll(installDefaultChannelHandlers);

  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(storageChannel, null);
    messenger.setMockMethodCallHandler(monotonicChannel, null);
    messenger.setMockMethodCallHandler(backgroundChannel, null);
  });
}
