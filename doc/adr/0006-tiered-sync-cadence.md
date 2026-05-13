# ADR 0006: Mobile-optimized sync cadence: tiered establish/validate refresh

- Status: **Accepted**
- Date: 2026-05-13
- Tracking issue: `trusted_time-rg6`
- Depends on: ADR 0001 (NTS as authenticated source for the validate
  cycle), ADR 0002 (real headless background anchor refresh — the
  scheduling target for the establish tier)
- Related: ADR 0005 (the fork is the venue for this change; upstream
  2.0.0 retains a single-tier 30-minute model)
- Composition: `trusted_time-26p` (hybrid trust model — truth box
  recomputed only on establish), `trusted_time-cuq` (unified DNS/TLS
  budget — bites hardest at establish-cycle cold start),
  `trusted_time-wy3` (burst sampling — bursts during establish, single
  during validate)

## Context

`TrustedTimeConfig.refreshInterval` defaults to `Duration(minutes: 30)`.
That value was inherited from the upstream desktop/server lineage and
is wrong for mobile in three independent ways:

1. **Drift modelling is over-conservative.** `oscillatorDriftFactor`
   defaults to `0.00005` (50 ppm) and feeds the `estimatedError` band
   that `nowEstimated()` reports
   (`lib/src/trusted_time_impl.dart:221-223`,
   `errorMs = (wallElapsed.inMilliseconds.abs() * oscillatorDriftFactor).round()`).
   Modern ARM SoCs (Pixel Tablet generation, A14+ iPhones) drift at
   5–15 ppm in pocket conditions, so the reported `estimatedError`
   band is roughly 3–10× wider than the hardware actually warrants.
   The separate `confidence` decay
   (`lib/src/trusted_time_impl.dart:217-220`,
   `(1.0 - wallElapsed.inMinutes.abs() / 4320.0).clamp(0.0, 1.0)`) is
   purely a function of elapsed wall time and does not use
   `oscillatorDriftFactor`; it independently reaches 0.5 at 36h and
   0.0 at 72h regardless of the drift constant.
2. **OS background scheduling defeats it anyway.** iOS
   `BGTaskScheduler` and Android `WorkManager` throttle frequent
   background tasks. A 30-min `refreshInterval` is aspirational; the
   OS will batch/defer/skip it to a 12–24h cadence regardless. Setting
   30 minutes just means the engine documents a frequency it cannot
   actually deliver. (See `trusted_time-e0v`.)
3. **Battery cost.** 48 cycles/day × 12–18 hosts × cold-handshake
   amortisation lands in single-digit % daily battery on cellular.
   1 establish/day plus a handful of cookie-warm validates is
   negligible.

The current single-tier model also conflates two operationally distinct
concerns: **establishing** a fresh truth anchor (expensive — full
Marzullo across the tiered pool, NTS-KE handshakes, DNS resolution) and
**validating** that the existing anchor is still good (cheap — a single
cookie-warm NTS query against a known-good source).

## Decision

Adopt a two-tier refresh model that separates establish from validate,
and recalibrate the underlying drift assumptions to match measured
mobile-SoC behaviour.

| Tier | Cadence | Cost profile | Trigger |
|---|---|---|---|
| **Establish** | 24h default | Full Marzullo across 12–18 hosts, ~3s cold | Scheduled, integrity reset, `forceResync()` |
| **Validate** | 1h default; also on app foreground after >15 min background | Single cookie-warm NTS query, ~50–200 ms, no consensus | Cheap freshness probe |
| **Recover** | event-driven | = Establish | Tamper detection (clock jump, reboot) |
| **On-demand** | per-action | Caller's choice | `forceResync()` before financial transactions etc. |

### Answers to the rg6 open questions

1. **Default Establish interval — 24h.** Chosen over 12h because the
   OS-throttling reality (open question #2 in the rg6 description) is
   that anything under ~12h is fictional on iOS BGTaskScheduler, and
   setting the engine's documented cadence to a value the platform
   will reliably honour avoids the
   "refreshInterval lies about what it does" failure mode. 12h remains
   a supported override for callers with stricter audit windows; the
   chosen default is the value that holds up under platform reality
   without measurement noise. Open for revision in a postscript once
   `trusted_time-wy3` produces measured drift data on ≥2 device
   classes.
2. **`oscillatorDriftFactor` recalibration — keep 50 ppm default;
   document the realistic envelope.** Lowering the global default to
   15 ppm would silently shrink the worst-case `estimatedError` band
   for desktop callers whose hardware actually drifts at 30–50 ppm.
   The conservative ceiling is correct as a default. A new
   convenience factory `TrustedTimeConfig.mobileDefaults()` — peer of
   the existing `TrustedTimeConfig.web()` factory
   (`lib/src/models.dart:84`),
   which is the only platform-targeted factory currently shipped — is
   introduced as part of this decision's follow-up implementation
   work and sets `oscillatorDriftFactor: 0.000015` (15 ppm) alongside
   the tiered cadence. Callers select platform-tuned defaults
   explicitly; the global default is never silently changed.
3. **`confidence` decay curve — leave the linear-zero-at-72h ceiling
   as conservative bound; revisit only if measurement
   contradicts.** The current formula bounds confidence purely by
   elapsed wall time and does not depend on `oscillatorDriftFactor`,
   so its shape is independent of the platform-tuned drift constant.
   Re-tuning now would entangle two changes whose evidence bases
   differ (cadence is a behavioural decision, decay shape is a
   measurement-driven calibration). Decay re-tuning is deferred to a
   follow-up ADR after `trusted_time-wy3` data lands.
4. **Validate-cycle source selection — single trusted NTS source per
   cycle, rotating across the establish-cycle pool, with
   Cloudflare anycast as the seed.** A fixed single source concentrates
   trust on one operator and one network path; rotation across the
   already-vetted establish-cycle pool keeps the validate cycle cheap
   (one query) while spreading the validate trust surface across the
   same operators that the establish cycle already approves.
   Cloudflare anycast is the seed because it has the lowest measured
   cold-start RTT on cellular in the 2026-05-09 stress run and is
   already the `ntsServers` default.
5. **Migration — opt-in flag with a deferred default flip.** The
   default-flip path is `trusted_time` 2.x release of the fork (see
   ADR 0005 for the fork's release lineage). For 1.x, a new
   `TrustedTimeConfig.cadenceMode` enum
   (`CadenceMode.singleTier30m` (legacy default) |
   `CadenceMode.tieredMobile`) gates the behaviour. `mobileDefaults()`
   selects `CadenceMode.tieredMobile`. CHANGELOG notes the planned
   default flip in the next major. This keeps in-flight 1.x
   integrators on stable behaviour and gives the fork's `axiom x`
   consumer a one-line opt-in via
   `cadenceMode: CadenceMode.tieredMobile` in its existing config.

### API addition

```dart
// Public surface, sketch
extension TrustedTimeValidate on TrustedTime {
  /// Cheap freshness probe against a single rotating NTS source.
  /// Updates `confidenceScore` without recomputing the truth box.
  /// Returns `true` if the existing anchor still passes the validate
  /// query within `maxAllowedUncertaintyMs`; `false` if the validate
  /// query disagrees by more than the threshold (caller may then
  /// invoke `forceResync()`).
  Future<bool> validateFreshness();
}
```

`validateFreshness()` does not invalidate the anchor on its own; that
remains the integrity monitor's responsibility. A failing validate is
a hint, not a verdict.

## Consequences

### Positive

- Establish cycle's documented cadence (24h) matches what iOS
  BGTaskScheduler and Android WorkManager will actually honour on
  battery-conscious devices, removing the
  "refreshInterval lies about what it does" failure mode.
- Validate tier provides sub-second freshness checks at app
  foreground without paying for a full Marzullo cycle. Caller flow
  for "I just came back from background, is my anchor still good?" is
  a single cheap call.
- `mobileDefaults()` factory makes the platform-tuned configuration
  one constructor call away, mirroring the shape of the existing
  `TrustedTimeConfig.web()` factory so callers do not have to
  assemble the knobs by hand.
- 50 ppm global default is preserved. Single-tier 30-minute callers
  on existing 1.x continue to behave exactly as they did before
  (`cadenceMode` defaults to `CadenceMode.singleTier30m`).

### Negative

- Two cadence modes is more configuration surface to test. The
  `CadenceMode.tieredMobile` and `CadenceMode.singleTier30m` paths
  must both be exercised;
  follow-up test work is tracked separately under `wy3` and the
  validate-API implementation ticket (filed at PR landing).
- `validateFreshness()` is a new public API and locks the fork into
  carrying it through 2.x. Surface is intentionally minimal
  (one `bool` return, no parameters) to keep the lock-in cost low.

### Open follow-ups (filed at PR landing)

- Implement `mobileDefaults()` factory, `cadenceMode` enum,
  `validateFreshness()` API, and the establish/validate scheduler
  refactor in `trusted_time_impl.dart`.
- Postscript revisiting Establish cadence (open question 1) and
  decay curve (open question 3) once `trusted_time-wy3`
  burst-sampling instrumentation produces measured drift data on
  Pixel Tablet and A14+ device classes.
- Postscript revisiting validate-cycle source rotation policy
  (open question 4) once `trusted_time-26p` hybrid trust model is
  decided — the establish-cycle pool definition is downstream of that
  decision.

## Alternatives considered

- **Lower the global `refreshInterval` default to 24h without
  introducing a validate tier.** Rejected: misses the orthogonal
  "is my anchor still good after foreground?" use case that the
  validate tier addresses, and conflates the two cost profiles into
  a single knob.
- **Lower the global `oscillatorDriftFactor` default to 15 ppm.**
  Rejected: silently shrinks the worst-case error band for desktop
  callers whose hardware really does drift at 30–50 ppm. Platform
  defaults are explicit; global default stays conservative.
- **Skip the migration flag; flip the default in a 1.x minor.**
  Rejected: behavioural break without an opt-in escape hatch
  violates the fork's own non-breaking-1.x stance (ADR 0005). The
  flag costs one enum and gives integrators a controlled landing.
