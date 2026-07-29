/// Multi-label public suffixes relevant to plausible time-server
/// hostnames — a deliberately tiny embedded subset of the Public
/// Suffix List (mini-PSL), so registrable-domain extraction needs no
/// dependency.
///
/// Only suffixes where the *registrable* domain sits three labels
/// deep need an entry (e.g. `cam.ac.uk` under `ac.uk`,
/// `neu.edu.cn` under `edu.cn`); every other hostname falls through
/// to the last-two-labels default. A suffix missing from this set is
/// fail-safe in the direction that matters: the extractor then
/// groups at the second level, merging *more* hosts into one group
/// and thus under-counting diversity — the same never-inflate policy
/// as the NTP tier's `asn-unknown` sentinel.
const Set<String> _multiLabelPublicSuffixes = {
  // United Kingdom
  'ac.uk', 'co.uk', 'gov.uk', 'org.uk', 'net.uk',
  // China
  'edu.cn', 'com.cn', 'net.cn', 'org.cn', 'gov.cn', 'ac.cn',
  // Brazil (note: `ntp.br` itself is registrable, so it has no entry)
  'com.br', 'net.br', 'org.br', 'edu.br', 'gov.br',
  // Australia
  'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  // Japan
  'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp',
  // New Zealand
  'co.nz', 'net.nz', 'org.nz', 'ac.nz', 'govt.nz',
  // South Africa
  'co.za', 'ac.za', 'org.za',
  // India
  'co.in', 'net.in', 'org.in', 'ac.in', 'gov.in', 'edu.in',
  // South Korea
  'co.kr', 'ac.kr', 're.kr',
};

/// Extracts the registrable domain (public suffix + one label) from
/// [host], using the embedded [_multiLabelPublicSuffixes] mini-PSL.
///
/// `gbg1.nts.netnod.se` → `netnod.se`; `ntp0.cam.ac.uk` →
/// `cam.ac.uk`; `ntp.neu.edu.cn` → `neu.edu.cn`. Hostnames with two
/// or fewer labels (including a bare TLD or a single label) are
/// returned lowercased. Empty labels — a trailing root dot in
/// FQDN form (`example.com.`) or stray consecutive dots — are
/// dropped before extraction, so `example.com.` groups with
/// `example.com` rather than minting a malformed `com.` group. IP
/// literals get no special handling — they pass through the same
/// label logic, which is harmless: grouping collapses rather than
/// splits.
String registrableDomain(String host) {
  final labels = host
      .toLowerCase()
      .split('.')
      .where((label) => label.isNotEmpty)
      .toList();
  if (labels.length <= 2) return labels.join('.');
  final lastTwo = labels.sublist(labels.length - 2).join('.');
  final take = _multiLabelPublicSuffixes.contains(lastTwo) ? 3 : 2;
  if (labels.length <= take) return labels.join('.');
  return labels.sublist(labels.length - take).join('.');
}
