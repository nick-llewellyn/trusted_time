# ADR 0008: Unified DNS concurrency cap across NTS, NTP, and HTTPS sources

- Status: **Accepted**
- Date: 2026-05-13
- Tracking issue: `trusted_time-cuq`
- Supersedes: portions of ADR 0001 §"Implementation notes" that
  scoped the DNS concurrency cap to NTS-KE only. With the source pool
  widening per ADR 0007, the NTS-only cap no longer reflects where
  the cold-start DNS budget actually goes.
- Depends on: ADR 0006 (establish/validate cadence — the cap matters
  on Establish cold-start), ADR 0007 (hybrid trust model — wider
  source pool is what makes a unified cap necessary)
- Composition: `trusted_time-wy3` (burst sampling — its stress-run
  data is the empirical input for revisiting the chosen default)

## Context

`TrustedTimeConfig.ntsDnsConcurrencyCap`
(`lib/src/models.dart:131`) is currently passed only to the `NtsSource`
constructor at `lib/src/sync_engine.dart:66-67`; it does not govern
HTTPS or NTP DNS resolution. The knob made sense when the source pool
was small and NTS-KE was the dominant cold-start cost. ADR 0007
widens the pool to 12–18 hosts mixing NTS, NTP, and HTTPS, which
shifts the cold-start bottleneck:

- Carrier DNS resolvers (especially over CGNAT) often serialise
  beyond 4–8 concurrent queries. 18 lookups against a serialising
  resolver = ~5–8 s of pure DNS time before any time samples can be
  gathered.
- This dwarfs the actual NTS-KE / TLS / NTP costs the engine is
  tuned around.
- An NTS-only cap does not help when 6–10 NTP sources also need to
  resolve hostnames in parallel.

A unified DNS budget makes the actual constraint explicit and applies
the same semaphore across all source kinds.

TLS handshake concurrency is a separate concern in the same family
but with weaker evidence: cert-chain validation is parallelisable
across cores, and the OS crypto pool (rather than the package's
scheduler) is the realistic bottleneck.

## Decision

Introduce a single SyncEngine-level DNS-lookup semaphore
(`maxConcurrentDnsLookups`, default `6`) governing all uncached DNS
resolutions across NTS, NTP, and HTTPS source kinds. Deprecate
`ntsDnsConcurrencyCap` with a one-version migration path. Do **not**
introduce a TLS-handshake cap until measurement justifies it.

### Answers to the cuq open questions

1. **Default value for `maxConcurrentDnsLookups` — 6.** Sits between
   the carrier-conservative (4) and WiFi-optimistic (8) options.
   Six covers the typical NTS pool size (3–5 per ADR 0007) plus
   HTTPS headroom while staying inside the typical CGNAT serialise
   threshold. The choice will be revisited in a postscript once
   `trusted_time-wy3` produces measured carrier-vs-WiFi
   stress-run data; the current default is the value that holds up
   under the most cited carrier serialisation envelope without
   waiting for measurement.

2. **TLS handshake cap necessity — no, do not add the knob.** The
   `cuq` description explicitly directs against speculative knobs;
   surface area should grow only when measurement justifies it. If
   `wy3` data shows the OS crypto pool serialising TLS handshakes
   in a way that materially extends Establish cold-start, a
   `maxConcurrentTlsHandshakes` knob lands as a follow-up ADR with
   the measured rationale attached.

3. **Per-network-class tuning — fixed cap, not auto-tuned.** The
   package does not currently observe connectivity events
   (`connectivity_plus` and equivalents are caller-supplied), and
   adding a connectivity listener crosses architectural boundaries
   that the package has deliberately kept out of its dependency
   surface. Callers with their own connectivity awareness can
   reconfigure the cap via `TrustedTimeConfig.copyWith` on the
   transition. A connectivity-aware variant is deferred to a
   separate ADR if a measurement-driven case emerges.

4. **Interaction with platform DNS caching — cache check first, cap
   governs uncached lookups only.** The cap is a cold-start budget;
   cache hits are free. Enforcing the cap *before* the cache check
   would throttle warm-cycle resolutions that have nothing to
   resolve, defeating the cap's purpose. The implementation must
   consult any platform / Dart-side DNS cache first and only acquire
   the semaphore for resolutions that actually hit the resolver.

5. **Failure mode when saturated — drop the source from this cycle
   as if it had hit `maxLatency`.** The package's existing
   `maxLatency` (default 4 s) is the hard ceiling for any single
   source's contribution. A source whose DNS lookup cannot even
   start within `maxLatency` because it is queued behind others
   should be treated identically to a source whose lookup ran but
   timed out: dropped from this cycle, exponential cooldown
   semantics applied as for any other failure. This preserves the
   existing per-source latency guarantee without inventing a new
   queueing-specific error class.

### Migration

`TrustedTimeConfig.ntsDnsConcurrencyCap` is deprecated, not removed,
in this decision. Migration semantics in code:

- If `maxConcurrentDnsLookups` is set explicitly, it wins.
- Else if the deprecated `ntsDnsConcurrencyCap` is set, log a
  one-time deprecation warning and use it as the unified cap value.
- Else use the new default (`6`).

Removal of the deprecated knob is deferred to the fork's 2.x release
per the migration discipline established in ADR 0006 §answer 5.

## Consequences

### Positive

- Cold-start DNS budget is explicit and uniform across source kinds,
  matching where the actual bottleneck lives once ADR 0007's wider
  pool lands.
- Composes directly with ADR 0006: the Establish cycle is exactly
  when the cap matters most; Validate cycles run against warm caches
  and rarely acquire the semaphore at all.
- Surface area minimisation: one knob (`maxConcurrentDnsLookups`)
  replaces the per-source-type knob, with no speculative TLS knob
  added.
- Migration path preserves source compatibility for callers already
  setting `ntsDnsConcurrencyCap`.

### Negative

- The semaphore moves from per-source (today's `NtsSource` ctor) to
  SyncEngine-level. Any third-party `TimeSource` implementations
  (`TrustedTimeConfig.additionalSources`,
  `lib/src/models.dart`, the `additionalSources` field) that perform
  their own DNS lookups will not be governed by the cap unless they
  opt in through a new internal hook. This is intentional — third
  parties cannot be assumed to honour a private semaphore — but it
  means the cap is best-effort across the source-kind boundary.
- The cap composes with ADR 0007's ASN-based NTP `groupId`
  derivation: if the implementation chooses a network-call IP-to-ASN
  service, those lookups also count against the budget. If it
  chooses a bundled offline ASN database (e.g., a packaged
  GeoLite2-ASN snapshot), they do not. The implementation ticket
  (`trusted_time-c8y`) must pick one and document the budget impact
  in its own design notes.
- Conservative default (`6`) may underuse WiFi headroom on
  WiFi-only devices. Acceptable trade — the cost of underused
  headroom is measured in milliseconds; the cost of overused budget
  on cellular is measured in seconds.

### Open follow-ups (filed at PR landing)

- Implementation ticket for the SyncEngine-level semaphore, the
  `maxConcurrentDnsLookups` field on `TrustedTimeConfig`, the
  deprecation of `ntsDnsConcurrencyCap`, and the cache-first /
  drop-on-saturation behaviour.
- Postscript revisiting the chosen default once `trusted_time-wy3`
  burst-sampling data lands with measured carrier-vs-WiFi
  serialisation thresholds.
- A separate ADR introducing `maxConcurrentTlsHandshakes` if (and
  only if) `wy3` data shows the OS crypto pool is a real
  bottleneck.

## Alternatives considered

- **Keep `ntsDnsConcurrencyCap` and add a separate
  `httpsDnsConcurrencyCap` / `ntpDnsConcurrencyCap`.** Rejected:
  three knobs to express what is fundamentally one shared resource
  (the resolver); callers would have to coordinate them by hand.
- **Auto-size the cap based on observed resolver behaviour.**
  Rejected: requires per-call latency observation and a feedback
  loop; significantly more state for a problem the fixed default
  already addresses.
- **Add `maxConcurrentTlsHandshakes` now, with a conservative
  default.** Rejected per `cuq` description's explicit guidance; see
  open question 2.
- **Auto-tune the cap on connectivity-class transitions.** Deferred,
  not rejected outright; see open question 3.
