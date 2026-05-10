/// Worldwide NTS server pool for the Beauty Parade benchmarking mode.
///
/// Transcribed from the canonical inventory at
/// `../nts/example/assets/nts-sources.yml` (82 entries; 81 here
/// after the IPv6-only exclusion below). Hostnames
/// originally wrapped in markdown-link syntax (`[host](url)`) in the
/// source YAML are unwrapped to bare hostnames here. The single
/// IPv6-only entry (`ntp3.ipv6.fau.de`) is intentionally omitted so
/// the pool only contains hosts a typical IPv4-capable device can
/// reach; that exclusion is the only deliberate filter applied —
/// every other entry is preserved verbatim so re-vendoring the
/// canonical list stays a mechanical diff.
///
/// The benchmarking UI uses this pool both as the manual chip grid
/// (operator picks arbitrary subsets) and as the source for the
/// "Run Worldwide Beauty Parade" rotation mode (engine cycles
/// through fixed-size subsets to give every host isolated,
/// contention-free measurements over time).
const List<String> extendedNtsPool = [
  'time.cloudflare.com',
  'nts.teambelgium.net',
  'a.st1.ntp.br',
  'b.st1.ntp.br',
  'c.st1.ntp.br',
  'd.st1.ntp.br',
  'gps.ntp.br',
  'brazil.time.system76.com',
  'time.bolha.one',
  'time1.mbix.ca',
  'time2.mbix.ca',
  'time3.mbix.ca',
  'time.web-clock.ca',
  'nts1.ntp.hr',
  'nts2.ntp.hr',
  'time.cincura.net',
  'ntp.miuku.net',
  'paris.time.system76.com',
  'ntp1.rdem-systems.com',
  'ntp2.rdem-systems.com',
  'ntp3.rdem-systems.com',
  'ntp4.rdem-systems.com',
  'ntp5.rdem-systems.com',
  'ntp6.rdem-systems.com',
  'ntp8.rdem-systems.com',
  'ntp9.rdem-systems.com',
  'ntp10.rdem-systems.com',
  'ntp11.rdem-systems.com',
  'ntp3.fau.de',
  'ntp7.rdem-systems.com',
  'ptbtime1.ptb.de',
  'ptbtime2.ptb.de',
  'ptbtime3.ptb.de',
  'ptbtime4.ptb.de',
  'www.jabber-germany.de',
  'www.masters-of-cloud.de',
  'ntp.nanosrvr.cloud',
  '1.nts.nothingtohide.nl',
  '2.nts.nothingtohide.nl',
  '3.nts.nothingtohide.nl',
  '4.nts.nothingtohide.nl',
  'ntppool1.time.nl',
  'ntppool2.time.nl',
  'nts.decepticon.space',
  'ntpmon.dcs1.biz',
  'nts.netnod.se',
  'gbg1.nts.netnod.se',
  'gbg2.nts.netnod.se',
  'lul1.nts.netnod.se',
  'lul2.nts.netnod.se',
  'mmo1.nts.netnod.se',
  'mmo2.nts.netnod.se',
  'sth1.nts.netnod.se',
  'sth2.nts.netnod.se',
  'svl1.nts.netnod.se',
  'svl2.nts.netnod.se',
  'ntp.3eck.net',
  'ntp.trifence.ch',
  'ntp.zeitgitter.net',
  'ntp01.maillink.ch',
  'ntp02.maillink.ch',
  'ntp03.maillink.ch',
  'time.signorini.ch',
  'ntp2.glypnod.com',
  'ntp1.dmz.terryburton.co.uk',
  'ntp2.dmz.terryburton.co.uk',
  'ntp0.cam.ac.uk',
  'ntp1.cam.ac.uk',
  'ntp2.cam.ac.uk',
  'ntp3.cam.ac.uk',
  'ntp1.glypnod.com',
  'ohio.time.system76.com',
  'oregon.time.system76.com',
  'virginia.time.system76.com',
  'stratum1.time.cifelli.xyz',
  'time.cifelli.xyz',
  'time.txryan.com',
  'ntp.viarouge.net',
  'time.xargs.org',
  'ntp1.wiktel.com',
  'ntp2.wiktel.com',
];

/// Curated NTS pool for the integration stress test.
///
/// Five geographically diverse, high-availability NTS servers, each
/// reaching 100% reliability across multiple stress runs in their
/// current configuration. ntp1.glypnod.com was dropped after going
/// 0/2 (unreachable cold-start NTS-KE timeouts both selections).
/// Only one System76 host is included because multiple System76
/// hosts in a single pool reliably cause one to lose its cold-start
/// NTS-KE handshake (cannibalisation pattern observed across runs).
///
/// Shared between `main()` (which seeds the engine's initial config)
/// and `_HomePageState._selectedServers` (which seeds the Section 7
/// FilterChip selection) so the chips and the live engine config
/// agree on cold launch. Note that `mmo1.nts.netnod.se` is the
/// Malmö regional endpoint, intentionally distinct from the
/// round-robin `nts.netnod.se` entry in [extendedNtsPool].
const List<String> curatedNtsPool = [
  'time.cloudflare.com',
  'mmo1.nts.netnod.se',
  'nts.teambelgium.net',
  'ptbtime2.ptb.de',
  'ohio.time.system76.com',
];

/// Stable, ordered union of [extendedNtsPool] and [curatedNtsPool].
///
/// Used by the Section 7 FilterChip grid so every host that may be
/// present in the initial selection (or appear in subsequent operator
/// edits) has a representable chip. [extendedNtsPool] entries come
/// first to preserve the existing chip ordering; any host that exists
/// only in [curatedNtsPool] would be appended after in its
/// `curatedNtsPool` order.
///
/// As of this writing every entry in [curatedNtsPool] is also in
/// [extendedNtsPool], so the union currently has the same length as
/// [extendedNtsPool] and the trailing comprehension is a no-op. The
/// comprehension is retained as forward-compat: if [curatedNtsPool]
/// ever gains a host that is intentionally absent from
/// [extendedNtsPool] (e.g. a small experimental endpoint we want
/// pinned for benchmarking but not promoted to the worldwide
/// rotation pool), the chip grid picks it up automatically.
///
/// Computed rather than const so it stays correct if either pool
/// gains or loses a host.
final List<String> benchmarkChipPool = List<String>.unmodifiable([
  ...extendedNtsPool,
  for (final host in curatedNtsPool)
    if (!extendedNtsPool.contains(host)) host,
]);
