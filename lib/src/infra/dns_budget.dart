import 'dart:async';
import 'dart:collection';

/// Thrown when a DNS resolution cannot acquire a [DnsBudget] permit
/// within the configured acquisition window.
///
/// Per ADR 0008 (answer 5) a source whose DNS lookup cannot even start
/// because it is queued behind others is treated identically to a
/// source whose lookup ran but exceeded `maxLatency`: it is dropped from
/// the current sync cycle and follows the standard exponential-cooldown
/// path. Callers therefore let this propagate out of `getTime` rather
/// than swallowing it like an ordinary resolution miss.
class DnsBudgetSaturation implements Exception {
  /// Creates a saturation marker for [host] after waiting [waited].
  const DnsBudgetSaturation(this.host, this.waited);

  /// The hostname whose resolution was abandoned.
  final String host;

  /// How long admission was awaited before giving up.
  final Duration waited;

  @override
  String toString() =>
      'DnsBudgetSaturation: no DNS slot for "$host" within '
      '${waited.inMilliseconds}ms';
}

/// SyncEngine-level budget governing concurrent uncached DNS lookups
/// across source kinds (ADR 0008).
///
/// A fixed counting semaphore caps how many hostname resolutions may hit
/// the resolver at once. A short-lived result cache is consulted first,
/// so warm cycles that have nothing to resolve never consume a permit
/// (ADR 0008 answer 4). When every permit is taken, [guard] waits up to
/// the acquisition window and then throws [DnsBudgetSaturation].
///
/// This type is deliberately free of `dart:io` so it can be constructed
/// unconditionally by [SyncEngine] on every platform, including web,
/// where it is simply never exercised.
class DnsBudget {
  /// Creates a budget admitting at most [maxConcurrent] concurrent
  /// uncached lookups.
  ///
  /// [acquireTimeout] is the per-lookup admission window; SyncEngine
  /// passes `maxLatency` so a queued source drops on the same ceiling as
  /// a slow one. [cacheTtl] bounds how long a successful resolution is
  /// reused before the next lookup re-acquires a permit.
  DnsBudget(
    this.maxConcurrent, {
    Duration acquireTimeout = const Duration(seconds: 4),
    Duration cacheTtl = const Duration(seconds: 60),
  }) : assert(maxConcurrent > 0, 'maxConcurrent must be positive'),
       _available = maxConcurrent,
       _acquireTimeout = acquireTimeout,
       _cacheTtl = cacheTtl;

  /// Maximum number of concurrent uncached lookups permitted.
  final int maxConcurrent;

  final Duration _acquireTimeout;
  final Duration _cacheTtl;
  int _available;
  final Queue<Completer<bool>> _waiters = Queue<Completer<bool>>();
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// Permits currently free. Exposed for tests asserting accounting.
  int get availablePermits => _available;

  /// Resolves [key] cache-first, otherwise acquires a permit and runs
  /// [resolve], caching its non-null result for reuse.
  ///
  /// Throws [DnsBudgetSaturation] if no permit becomes free within the
  /// acquisition window. Errors thrown by [resolve] itself (an actual
  /// resolution failure or timeout) propagate unchanged so callers can
  /// distinguish saturation from a plain lookup miss.
  Future<T> guard<T>(String key, Future<T> Function() resolve) async {
    final cached = _cache[key];
    if (cached != null && cached.expiresAtMs > _nowMs()) {
      return cached.value as T;
    }
    final acquired = await _acquire(_acquireTimeout);
    if (!acquired) {
      throw DnsBudgetSaturation(key, _acquireTimeout);
    }
    try {
      final value = await resolve();
      if (value != null) {
        _cache[key] = _CacheEntry(
          value as Object,
          _nowMs() + _cacheTtl.inMilliseconds,
        );
      }
      return value;
    } finally {
      _release();
    }
  }

  Future<bool> _acquire(Duration timeout) {
    if (_available > 0) {
      _available--;
      return Future<bool>.value(true);
    }
    final completer = Completer<bool>();
    _waiters.add(completer);
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _waiters.remove(completer);
        completer.complete(false);
      }
    });
    return completer.future.whenComplete(timer.cancel);
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(true);
        return;
      }
    }
    _available++;
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;
}

class _CacheEntry {
  const _CacheEntry(this.value, this.expiresAtMs);
  final Object value;
  final int expiresAtMs;
}
