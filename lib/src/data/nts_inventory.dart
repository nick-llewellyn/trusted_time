/// The curated NTS host inventory shipped with the library.
///
/// 57 verified hosts: the 52 recorded on `trusted_time-cln`
/// (2026-07-25, UK vantage) plus 5 admitted by the `trusted_time-2tx`
/// geographic-gap sweep (2026-07-27, same vantage). Every host
/// completed a full live NTS-KE + AEAD-NTPv4 exchange
/// (AES-SIV-CMAC-256, platform trust) during its verification probe;
/// the five later admissions each passed three or more consecutive
/// exchanges.
///
/// ## What is recorded, and what is not
///
/// Each entry carries the host, its curation tier, the stratum a live
/// probe observed, and how firmly its leap-second behaviour is
/// established. No group identifier is stored: an NTS group is the
/// registrable domain of the hostname, which `registrableDomain` reads
/// straight off [NtsServerInfo.host] and which is the same at every
/// vantage — unlike the plain-NTP tier's autonomous system, which has
/// to be observed. Measured round-trip time and resolved IP are
/// likewise absent: both are properties of a query rather than of a
/// host, so the engine measures them per install.
///
/// ## Leap-second policy
///
/// No host below is a documented smearing operator. Per-host evidence
/// strength is on [NtsServerInfo.leapPolicy]. The runtime defence is
/// the Marzullo intersection, which rejects a roughly one-second
/// outlier whatever caused it.
///
/// ## Grouping
///
/// 24 registrable-domain groups. Largest, for quorum-inflation
/// awareness: `netnod.se` (11 hosts), `rdem-systems.com` (7),
/// `system76.com` (5), and `cam.ac.uk`, `ptb.de`, `nothingtohide.nl`
/// (4 each). The three anycast hosts sit in three distinct groups, so
/// a quorum drawn from the anycast tier alone already spans three
/// operators.
///
/// ## Coverage caveat
///
/// No admissible unicast NTS host exists in Oceania, Africa, the
/// Middle East, or Asia beyond the two NEU hosts: the sole listed APAC
/// candidate has decommissioned its listener, several fleets violate
/// RFC 8915 §4.1.5, and no gap-region national laboratory runs an NTS
/// listener. Those regions are reached through the anycast tier only.
///
/// Ordered by tier — anycast, then unicast stratum 1, then unicast
/// stratum 2 — matching the ticket's inventory table.
library;

import '../models/nts_server_info.dart';
import '../models/time_server_tier.dart';

/// Just the hostnames from [curatedNtsInventory], in the same order.
///
/// The engine queries by name; the metadata is for selection and
/// inspection.
final List<String> curatedNtsHostnames = List.unmodifiable(
  curatedNtsInventory.map((e) => e.host),
);

/// The hosts the engine synchronizes against over NTS.
///
/// See the library doc comment for provenance, leap-second policy, and
/// the coverage caveat.
const List<NtsServerInfo> curatedNtsInventory = [
  // Anycast
  //
  // Answered stratum 3 from the probe vantage; the tier records that
  // it is anycast and self-localizing, which is the curation decision.
  NtsServerInfo(
    host: 'time.cloudflare.com',
    tier: TimeServerTier.anycast,
    observedStratum: 3,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'nts.netnod.se',
    tier: TimeServerTier.anycast,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'any.time.nl',
    tier: TimeServerTier.anycast,
    observedStratum: 2,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  // Unicast — stratum 1
  NtsServerInfo(
    host: 'nts.teambelgium.net',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'nts.time.nl',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'time.dfm.dk',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.bcpStepping,
  ),
  NtsServerInfo(
    host: 'mirror.mdapi.ch',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'stratum1.time.cifelli.xyz',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ptbtime1.ptb.de',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'ptbtime2.ptb.de',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'ptbtime3.ptb.de',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'ptbtime4.ptb.de',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'gbg1.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'gbg2.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'lul1.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'lul2.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'mmo1.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'mmo2.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'sth1.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'sth2.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'svl1.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'svl2.nts.netnod.se',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.documentedStepping,
  ),
  NtsServerInfo(
    host: 'nts.decepticon.space',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'nts1.ntp.hr',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'nts2.ntp.hr',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'time.web-clock.ca',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  // Live-confirmed stratum 1; the upstream list is stale at stratum 2.
  NtsServerInfo(
    host: 'd.st1.ntp.br',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'time.cincura.net',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp.neu.edu.cn',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp1.neu.edu.cn',
    tier: TimeServerTier.unicastStratum1,
    observedStratum: 1,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  // Unicast — stratum 2
  NtsServerInfo(
    host: 'ntp0.cam.ac.uk',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp1.cam.ac.uk',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp2.cam.ac.uk',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp3.cam.ac.uk',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp2.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp4.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp6.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp7.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp9.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp10.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp11.rdem-systems.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: '1.nts.nothingtohide.nl',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: '2.nts.nothingtohide.nl',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: '3.nts.nothingtohide.nl',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: '4.nts.nothingtohide.nl',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'www.jabber-germany.de',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'www.masters-of-cloud.de',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  // Live-confirmed stratum 2; the upstream list says stratum 3.
  NtsServerInfo(
    host: 'ntp.3eck.net',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  // Live-confirmed stratum 2; the upstream list says stratum 3.
  NtsServerInfo(
    host: 'ntp.miuku.net',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ntp.viarouge.net',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'time.cifelli.xyz',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'virginia.time.system76.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'ohio.time.system76.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'oregon.time.system76.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'paris.time.system76.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  NtsServerInfo(
    host: 'brazil.time.system76.com',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
  // Live-measured stratum 2; the upstream list says stratum 3.
  NtsServerInfo(
    host: '0.ntp.bksp.in',
    tier: TimeServerTier.unicastStratum2,
    observedStratum: 2,
    leapPolicy: LeapPolicy.presumedStepping,
  ),
];
