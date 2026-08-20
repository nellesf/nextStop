# ADR 0012: Default criteria for non-profile rides

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-08-17

## Context

The allowed filter values are fixed, but a destination selected without a profile
still needs an efficient starting state in CarPlay. Requiring four first-time
selections would add avoidable driving interaction.

## Decision

Initialize a non-profile `RideSearchDraft` with visible, centrally configured
defaults:

- distance range: 50–100 km;
- minimum charging points: 4 EVSEs;
- minimum power: 100 kW;
- nearby restaurant required: no (`foodChain = nil`).

Show every value on the ride summary before search. The driver may change any
value for the current ride. Defaults and ride edits never mutate saved profiles.

## Alternatives

- Force an explicit value for every filter: assumption-free but unnecessarily
  interaction-heavy.
- Reuse a previous ride automatically: less predictable and conflicts with the
  ride-scoped persistence boundary.

## Consequences

Availability was removed as a filter by owner approval on 2026-08-17 and remains
informational. The broad defaults avoid excluding charging candidates based on
uncertain food data while still favoring meaningful site size and fast charging.
Product changes
to these values require updating this ADR, the central catalog, tests, and German
summary localization.
