/// Worldwide NTS server pool for the Beauty Parade benchmarking mode.
///
/// 57 verified hosts: the 52 recorded on `trusted_time-cln`
/// (2026-07-25) plus 5 admitted by the `trusted_time-2tx`
/// geographic-gap sweep (2026-07-27). Every host below completed a
/// full live NTS-KE + AEAD-NTPv4 exchange (AES-SIV-CMAC-256) during
/// its verification probe, and every host follows the leap-second
/// stepping policy.
/// Unverified, dropped (`time.txryan.com`), and demoted-undecided
/// (`ntp8.rdem-systems.com`) entries from the previous 81-host
/// vendored list are excluded. Ordered by the ticket's tiers:
/// anycast, then unicast stratum 1, then unicast stratum 2.
///
/// One correction relative to the ticket's inventory table:
/// `sth1.nts.netnod.se` was omitted from the table (which is why it
/// enumerates 51 rows while its prose says "52 hosts verified"); it
/// was re-probed live on 2026-07-26 (full NTS-KE + AEAD-NTPv4
/// exchange, stratum 1) and is included here.
///
/// Geographic-gap sweep (`trusted_time-2tx`, 2026-07-27, UK vantage)
/// added five hosts, each passing >= 3 consecutive live exchanges:
/// `any.time.nl` (SIDN TimeNL BGP anycast, S2, documented no-smear —
/// a third anycast administrative group alongside Cloudflare and
/// Netnod), `nts.time.nl` (S1, NL), `time.dfm.dk` (S1, DK national
/// metrology, serves UTC(DFM)), `mirror.mdapi.ch` (S1, CH), and
/// `stratum1.time.cifelli.xyz` (S1, US). No admissible unicast host
/// exists in Oceania, Africa, the Middle East, or Asia beyond the
/// NEU pair: the sole APAC NTS candidate (`ntpmon.dcs1.biz`, SG)
/// refuses connections, the ntp.br S1 fleet either times out or
/// violates RFC 8915 §4.1.5 (AEAD record without Critical bit — same
/// violation as ntp3.fau.de, ntp01.maillink.ch, ntp1.wiktel.com,
/// time1.mbix.ca), and no gap-region national lab (NICT, KRISS,
/// NTSC, NPL-India, CSIR-ZA) runs an NTS listener. Those regions
/// remain anycast-only; explore/exploit selection design
/// (`trusted_time-mvq`) must account for that. `nts.amethyst.name`
/// verified live but is S3 unicast — excluded from the S1/S2 tiers
/// (same precedent as `ntp8.rdem-systems.com`); `ntppool1/2.time.nl`
/// completed NTS-KE but timed out in the NTP phase on most runs.
///
/// The benchmarking UI uses this pool both as the manual chip grid
/// (operator picks arbitrary subsets) and as the source for the
/// "Run Worldwide Beauty Parade" rotation mode (engine cycles
/// through fixed-size subsets to give every host isolated,
/// contention-free measurements over time).
const List<String> extendedNtsPool = [
  // Anycast
  'time.cloudflare.com',
  'nts.netnod.se',
  'any.time.nl',
  // Unicast — stratum 1
  'nts.teambelgium.net',
  'nts.time.nl',
  'time.dfm.dk',
  'mirror.mdapi.ch',
  'stratum1.time.cifelli.xyz',
  'ptbtime1.ptb.de',
  'ptbtime2.ptb.de',
  'ptbtime3.ptb.de',
  'ptbtime4.ptb.de',
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
  'nts.decepticon.space',
  'nts1.ntp.hr',
  'nts2.ntp.hr',
  'time.web-clock.ca',
  'd.st1.ntp.br',
  'time.cincura.net',
  'ntp.neu.edu.cn',
  'ntp1.neu.edu.cn',
  // Unicast — stratum 2
  'ntp0.cam.ac.uk',
  'ntp1.cam.ac.uk',
  'ntp2.cam.ac.uk',
  'ntp3.cam.ac.uk',
  'ntp2.rdem-systems.com',
  'ntp4.rdem-systems.com',
  'ntp6.rdem-systems.com',
  'ntp7.rdem-systems.com',
  'ntp9.rdem-systems.com',
  'ntp10.rdem-systems.com',
  'ntp11.rdem-systems.com',
  '1.nts.nothingtohide.nl',
  '2.nts.nothingtohide.nl',
  '3.nts.nothingtohide.nl',
  '4.nts.nothingtohide.nl',
  'www.jabber-germany.de',
  'www.masters-of-cloud.de',
  'ntp.3eck.net',
  'ntp.miuku.net',
  'ntp.viarouge.net',
  'time.cifelli.xyz',
  'virginia.time.system76.com',
  'ohio.time.system76.com',
  'oregon.time.system76.com',
  'paris.time.system76.com',
  'brazil.time.system76.com',
  '0.ntp.bksp.in',
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
/// and `BenchmarkController._selectedServers` (which seeds the Section 7
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
