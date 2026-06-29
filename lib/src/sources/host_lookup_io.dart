import 'dart:io' show InternetAddress;

/// Resolves [host] to its address literals via the platform resolver.
///
/// The returned IP strings are intentionally unused by the caller: the
/// point of the call is the side effect of populating the OS/platform
/// DNS cache so that `package:http`'s subsequent internal resolution of
/// the same host hits the warm cache instead of issuing a second cold
/// lookup. Routing this warming through the shared `DnsBudget` (ADR
/// 0008) is what brings HTTPS cold-start DNS under the unified
/// concurrency cap, even though the eventual request resolves inside
/// `package:http` / `HttpClient`, which exposes no in-process seam.
///
/// Resolves to an empty list when the host yields no addresses; throws
/// on a resolution failure, which the caller treats as a best-effort
/// warming miss (the HTTPS request proceeds and surfaces its own error).
Future<List<String>> defaultHttpsHostLookup(String host) async {
  final addrs = await InternetAddress.lookup(host);
  return [for (final a in addrs) a.address];
}
