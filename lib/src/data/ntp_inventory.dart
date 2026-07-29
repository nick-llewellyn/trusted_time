/// The curated plain-NTP host inventory shipped with the library.
///
/// 51 verified hosts recorded on `trusted_time-6pu` from the probe run
/// on `trusted_time-5fz` (2026-07-26, UK residential broadband
/// vantage). Every host completed 2/2 live SNTP exchanges via
/// `bin/ntp_cli.dart` with stratum, RTT, resolved IP, and ASN
/// recorded; no host collapsed to the `asn-unknown` sentinel.
///
/// ## Leap-second policy
///
/// No host below is a documented smearing operator. `time.google.com`,
/// `time.aws.com`, and `time.facebook.com` were probed and excluded on
/// published-smear evidence — a smeared source diverges from stepping
/// sources by up to a full second around a leap event and can poison
/// the consensus.
///
/// Stepping is *documented* for Cloudflare, the pool zones, PTB, NIST
/// (leap applied on schedule), and Microsoft (W32Time never smears),
/// and follows from the IETF NTP BCP for the metrology institutes
/// (INRIM, ROA, NPL, GUM, METAS, NICT, NRC, KRISS). For the remaining
/// public university and IXP servers it is *presumed*: stock
/// `ntpd`/`chrony` step by default, and smearing requires explicit
/// operator configuration that every known smearer has published.
/// `time.apple.com` has no published policy and is flagged for
/// observation at the next leap event. The runtime defence is the
/// Marzullo intersection, which rejects a ~1 s outlier regardless.
///
/// ## Vantage caveat
///
/// `pool.ntp.org` zones, `time.nist.gov`, `time.cloudflare.com`,
/// `ntp.se`, `time.apple.com`, and `time.windows.com` are anycast or
/// DNS-steered: their resolved IP and ASN differ per vantage, so the
/// ASN grouping observed at probe time is indicative, not fixed.
///
/// ## Grouping
///
/// 27 distinct ASN groups at the probe vantage. Largest, for
/// quorum-inflation awareness: `as57021` (Netnod, 11 hosts), `as680`
/// (DFN, 6), `as786` (Janet, 4). The pool zones resolved into five
/// different member ASNs here but should be treated as one anycast
/// family when composing a quorum.
///
/// Ordered by tier — anycast, then unicast stratum 1, then unicast
/// stratum 2 — matching the ticket's inventory table.
library;

/// The hostnames the engine synchronizes against over plain NTP.
///
/// See the library doc comment for provenance, leap-second policy, and
/// the anycast vantage caveat.
const List<String> curatedNtpInventory = [
  // Anycast
  'time.cloudflare.com',
  'pool.ntp.org',
  '0.pool.ntp.org',
  '1.pool.ntp.org',
  '2.pool.ntp.org',
  '3.pool.ntp.org',
  'time.nist.gov',
  'ntp.se',
  'time.apple.com',
  'time.windows.com',
  // Unicast — stratum 1
  'time.web-clock.ca',
  'ntp1.inrim.it',
  'ntp2.inrim.it',
  'hora.roa.es',
  'minuto.roa.es',
  'ntp1.npl.co.uk',
  'ntp2.npl.co.uk',
  'tick.usask.ca',
  'tock.usask.ca',
  'd.st1.ntp.br',
  'time.cincura.net',
  'ntp.ix.ru',
  'ntp.neu.edu.cn',
  'ntp1.neu.edu.cn',
  'tempus1.gum.gov.pl',
  'tempus2.gum.gov.pl',
  'ntp.metas.ch',
  'gbg1.ntp.se',
  'gbg2.ntp.se',
  'lul1.ntp.se',
  'lul2.ntp.se',
  'mmo1.ntp.se',
  'mmo2.ntp.se',
  'sth1.ntp.se',
  'sth2.ntp.se',
  'svl1.ntp.se',
  'svl2.ntp.se',
  'ntps1-0.cs.tu-berlin.de',
  'ptbtime1.ptb.de',
  'ptbtime2.ptb.de',
  'ptbtime3.ptb.de',
  'ptbtime4.ptb.de',
  'time.fu-berlin.de',
  'ntp.nict.jp',
  // Unicast — stratum 2
  'time.chu.nrc.ca',
  'time.kriss.re.kr',
  'x.ns.gin.ntt.net',
  'ntp0.cam.ac.uk',
  'ntp1.cam.ac.uk',
  'ntp2.cam.ac.uk',
  'ntp3.cam.ac.uk',
];
