/// The curated plain-NTP host inventory shipped with the library.
///
/// 51 verified hosts recorded on `trusted_time-6pu` from the probe run
/// on `trusted_time-5fz` (2026-07-26, UK residential broadband
/// vantage). Every host completed 2/2 live SNTP exchanges via
/// `bin/ntp_cli.dart` with stratum, RTT, resolved IP, and ASN
/// recorded; no host collapsed to the `asn-unknown` sentinel.
///
/// ## What is recorded, and what is not
///
/// Each entry carries the host, its curation tier, the stratum and
/// autonomous system a live probe observed, and how firmly its
/// leap-second behaviour is established. Measured round-trip time and
/// resolved IP are deliberately *not* carried: an RTT taken from one
/// vantage is a misleading prior for a device somewhere else, and a
/// resolved address is stale the moment an operator renumbers. Both
/// are properties of a query rather than of a host, so the engine
/// measures them per install.
///
/// ## Leap-second policy
///
/// No host below is a documented smearing operator. `time.google.com`,
/// `time.aws.com`, and `time.facebook.com` were probed and excluded on
/// published-smear evidence — a smeared source diverges from stepping
/// sources by up to a full second around a leap event and can poison
/// the consensus.
///
/// Per-host evidence strength is on [NtpServerInfo.leapPolicy].
/// `time.apple.com` has no published policy and is flagged for
/// observation at the next leap event. The runtime defence is the
/// Marzullo intersection, which rejects a ~1 s outlier regardless.
///
/// ## Vantage caveat
///
/// [NtpServerTier.anycast] hosts are anycast or DNS-steered: their
/// resolved IP and autonomous system differ per vantage, so
/// [NtpServerInfo.observedGroupId] for those entries is indicative,
/// not fixed.
///
/// ## Grouping
///
/// 27 distinct groups at the probe vantage. Largest, for
/// quorum-inflation awareness: `as57021` (Netnod, 11 hosts), `as680`
/// (DFN, 6), `as786` (Janet, 4). The pool zones resolved into five
/// different member networks here but should be treated as one anycast
/// family when composing a quorum.
///
/// Ordered by tier — anycast, then unicast stratum 1, then unicast
/// stratum 2 — matching the ticket's inventory table.
library;

import '../models/ntp_server_info.dart';

/// Just the hostnames from [curatedNtpInventory], in the same order.
///
/// The engine queries by name; the metadata is for selection and
/// inspection.
final List<String> curatedNtpHostnames = List.unmodifiable(
  curatedNtpInventory.map((e) => e.host),
);

/// The hosts the engine synchronizes against over plain NTP.
///
/// See the library doc comment for provenance, leap-second policy, and
/// the anycast vantage caveat.
const List<NtpServerInfo> curatedNtpInventory = [
  // Anycast
  NtpServerInfo(
    host: 'time.cloudflare.com',
    tier: NtpServerTier.anycast,
    observedStratum: 3,
    observedGroupId: 'as13335',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'pool.ntp.org',
    tier: NtpServerTier.anycast,
    observedStratum: 1,
    observedGroupId: 'as201971',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: '0.pool.ntp.org',
    tier: NtpServerTier.anycast,
    observedStratum: 1,
    observedGroupId: 'as51048',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: '1.pool.ntp.org',
    tier: NtpServerTier.anycast,
    observedStratum: 2,
    observedGroupId: 'as63949',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: '2.pool.ntp.org',
    tier: NtpServerTier.anycast,
    observedStratum: 2,
    observedGroupId: 'as207841',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: '3.pool.ntp.org',
    tier: NtpServerTier.anycast,
    observedStratum: 2,
    observedGroupId: 'as207108',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'time.nist.gov',
    tier: NtpServerTier.anycast,
    observedStratum: 1,
    observedGroupId: 'as49',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'ntp.se',
    tier: NtpServerTier.anycast,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'time.apple.com',
    tier: NtpServerTier.anycast,
    observedStratum: 1,
    observedGroupId: 'as6185',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  // Answered stratum 4 from the probe vantage; kept in the anycast
  // core because it is DNS-steered and self-localizing, which is what
  // the tier records.
  NtpServerInfo(
    host: 'time.windows.com',
    tier: NtpServerTier.anycast,
    observedStratum: 4,
    observedGroupId: 'as8075',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  // Unicast — stratum 1
  NtpServerInfo(
    host: 'time.web-clock.ca',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as11814',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp1.inrim.it',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as137',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'ntp2.inrim.it',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as137',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'hora.roa.es',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as198096',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'minuto.roa.es',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as198096',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'ntp1.npl.co.uk',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as209237',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'ntp2.npl.co.uk',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as209237',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'tick.usask.ca',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as22950',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'tock.usask.ca',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as22950',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'd.st1.ntp.br',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as2715',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'time.cincura.net',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as28725',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp.ix.ru',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as43832',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp.neu.edu.cn',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as4538',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp1.neu.edu.cn',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as4538',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'tempus1.gum.gov.pl',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as50606',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'tempus2.gum.gov.pl',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as50606',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'ntp.metas.ch',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as559',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'gbg1.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'gbg2.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'lul1.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'lul2.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'mmo1.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'mmo2.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'sth1.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'sth2.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'svl1.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'svl2.ntp.se',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as57021',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'ntps1-0.cs.tu-berlin.de',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as680',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ptbtime1.ptb.de',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as680',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'ptbtime2.ptb.de',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as680',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'ptbtime3.ptb.de',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as680',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'ptbtime4.ptb.de',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as680',
    leapPolicy: NtpLeapPolicy.documentedStepping,
  ),
  NtpServerInfo(
    host: 'time.fu-berlin.de',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as680',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp.nict.jp',
    tier: NtpServerTier.unicastStratum1,
    observedStratum: 1,
    observedGroupId: 'as9355',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  // Unicast — stratum 2
  NtpServerInfo(
    host: 'time.chu.nrc.ca',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 2,
    observedGroupId: 'as13319',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'time.kriss.re.kr',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 3,
    observedGroupId: 'as135354',
    leapPolicy: NtpLeapPolicy.bcpStepping,
  ),
  NtpServerInfo(
    host: 'x.ns.gin.ntt.net',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 2,
    observedGroupId: 'as2914',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp0.cam.ac.uk',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 2,
    observedGroupId: 'as786',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp1.cam.ac.uk',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 2,
    observedGroupId: 'as786',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp2.cam.ac.uk',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 2,
    observedGroupId: 'as786',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
  NtpServerInfo(
    host: 'ntp3.cam.ac.uk',
    tier: NtpServerTier.unicastStratum2,
    observedStratum: 2,
    observedGroupId: 'as786',
    leapPolicy: NtpLeapPolicy.presumedStepping,
  ),
];
