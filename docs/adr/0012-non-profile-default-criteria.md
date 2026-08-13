# ADR 0012: Default criteria for non-profile rides

- Status: Accepted
- Date: 2026-08-13

## Context

The allowed filter values are fixed, but a destination selected without a profile
still needs an efficient starting state in CarPlay. Requiring five first-time
selections would add avoidable driving interaction.

## Decision

Initialize a non-profile `RideSearchDraft` with visible, centrally configured
defaults:

- distance range: 50–100 km;
- minimum charging points: 4 EVSEs;
- minimum available points: any (`nil`);
- minimum power: 100 kW;
- food chain: any (`nil`).

Show every value on the ride summary before search. The driver may change any
value for the current ride. Defaults and ride edits never mutate saved profiles.

## Alternatives

- Force an explicit value for every filter: assumption-free but unnecessarily
  interaction-heavy.
- Reuse a previous ride automatically: less predictable and conflicts with the
  ride-scoped persistence boundary.

## Consequences

The broad defaults avoid excluding parks based on uncertain availability or food
data while still favoring meaningful park size and fast charging. Product changes
to these values require updating this ADR, the central catalog, tests, and German
summary localization.
