import 'package:nts/nts.dart' as nts;
import 'infra/trusted_time_log.dart';
import 'models.dart';

/// Signature of the NTS runtime initialiser.
///
/// Defaults to [nts.NtsRustLib.init]; exposed as a seam so tests can
/// observe (or script) the bootstrap without touching the real
/// flutter_rust_bridge FFI, which cannot be initialised from a plain Dart
/// unit-test isolate.
typedef NtsInitFn = Future<void> Function();

/// Ensures the flutter_rust_bridge runtime backing `package:nts` is
/// initialised for the current isolate, returning the config the engine
/// should actually run against.
///
/// This is the single source of truth for NTS bootstrap and is shared by
/// both entry points that construct a [SyncEngine]:
///
/// - `TrustedTime.initialize` (the foreground engine), and
/// - `runBackgroundSync` (the headless background isolate).
///
/// The background isolate is a *fresh* Dart isolate spawned by the OS
/// scheduler (WorkManager / BGTaskScheduler); flutter_rust_bridge FFI
/// initialisation performed on the foreground isolate does not carry over,
/// so the background path must run this bootstrap itself before any
/// [nts.NtsClient] is constructed — otherwise every NTS source throws
/// instantly and an NTS-only config can never reach quorum (trusted_time-y81).
///
/// Behaviour:
///
/// - Gated on [TrustedTimeConfig.ntsServers] being non-empty, preserving
///   `package:nts`'s "zero overhead when unused" guarantee.
/// - [nts.NtsRustLib] uses a process-wide singleton: a second `init()` call
///   within the same process throws
///   `StateError: Should not initialize flutter_rust_bridge twice`. That
///   happens whenever the host app re-initialises TrustedTime (benchmark UIs
///   that cycle the engine through different source pools, hot-restart in
///   development, a foreground init followed later by a background fire in the
///   same process, etc.). The "already initialised" StateError is treated as
///   success so re-init flows do not silently strip [ntsServers] and leave
///   the engine with zero sources for the rest of the process lifetime.
/// - Other exceptions (missing native asset, arch mismatch, etc.) are treated
///   as real failures and disable NTS for this configuration by returning a
///   copy with empty [ntsServers].
///
/// Returns [config] unchanged on success (or when NTS is not configured), or
/// `config.copyWith(ntsServers: const [])` when a genuine init failure means
/// NTS must be disabled for this run.
Future<TrustedTimeConfig> ensureNtsRuntime(
  TrustedTimeConfig config, {
  NtsInitFn init = nts.NtsRustLib.init,
}) async {
  if (config.ntsServers.isEmpty) return config;

  try {
    await init();
    return config;
  } catch (e) {
    // Detect "already initialised" loosely: any StateError whose message
    // references flutter_rust_bridge. The exact phrase "Should not
    // initialize flutter_rust_bridge twice" is the current upstream wording
    // but is not part of any public API contract; matching just the package
    // name is robust to wording / capitalisation drift across frb releases
    // while still narrow enough not to swallow unrelated StateErrors from
    // other code paths. The case-insensitive comparison (lowercasing both
    // sides) is the source of that capitalisation robustness — without it we
    // would only accept the canonical lowercase package name as it appears in
    // upstream's current panic, defeating the safety margin the loose match
    // was added for. If frb starts throwing StateError for genuinely new
    // structural failures we will need to revisit, but the failure mode of an
    // unrecognised double-init (silently disabling NTS) is significantly
    // worse than the failure mode of an unrecognised real error (the engine
    // will surface it at first NTS use).
    final message = e is StateError ? e.message.toLowerCase() : '';
    final alreadyInitialised =
        e is StateError && message.contains('flutter_rust_bridge');
    if (alreadyInitialised) return config;

    TrustedTimeLog.log(
      TrustedTimeLogLevel.warning,
      '[TrustedTime] NTS disabled — NtsRustLib.init failed: $e',
    );
    return config.copyWith(ntsServers: const []);
  }
}
