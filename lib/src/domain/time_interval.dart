import 'package:flutter/foundation.dart';

/// Represents a CLOSED mathematical interval `[startMs, endMs]` in UNIX epoch milliseconds.
/// Used for Marzullo's consensus algorithm. Both bounds are inclusive.
@immutable
final class TimeInterval {
  /// Creates a new [TimeInterval] with the specified start and end times in milliseconds.
  ///
  /// Throws an [ArgumentError] if `startMs > endMs`. An inverted interval is
  /// mathematically meaningless and, if admitted, would silently corrupt
  /// every downstream computation ([midpoint], [width], Marzullo
  /// intersection) rather than fail loudly — so the invariant is enforced
  /// at construction in all build modes, not just via `assert`.
  TimeInterval({required this.startMs, required this.endMs}) {
    if (startMs > endMs) {
      throw ArgumentError.value(
        startMs,
        'startMs',
        'must be <= endMs (got [$startMs, $endMs])',
      );
    }
  }

  /// The start of the interval (inclusive).
  final int startMs;

  /// The end of the interval (inclusive).
  final int endMs;

  /// The midpoint of the interval.
  int get midpoint => (startMs + endMs) ~/ 2;

  /// The width of the interval (uncertainty).
  int get width => endMs - startMs;

  @override
  String toString() => '[$startMs, $endMs]';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeInterval &&
          runtimeType == other.runtimeType &&
          startMs == other.startMs &&
          endMs == other.endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);
}
