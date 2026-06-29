/// Web stub for [defaultHttpsHostLookup].
///
/// Platforms without `dart:io` have no in-process resolver to warm — the
/// browser performs DNS itself as part of `fetch` — so this is a no-op
/// that resolves to an empty list and never touches the network. It
/// exists only so `time_sources.dart` can resolve the conditional import
/// on web; HTTPS DNS-budget warming is an IO-only concern.
Future<List<String>> defaultHttpsHostLookup(String host) async =>
    const <String>[];
