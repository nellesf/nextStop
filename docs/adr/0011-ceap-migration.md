# ADR 0011: CEAP migration strategy

- Status: Accepted
- Date: 2026-08-13

## Context

AFIR requires the Commission to establish CEAP by 2026-12-31. Research on
2026-08-13 found implementation guidance but no production gateway that can replace
national sources.

## Decision

Implement CEAP later as `FutureCEAPProvider` behind the same normalization port.
Shadow it per country against national/operator sources. Prefer it only after
measured coverage, freshness, identity, terms, and uptime are at least equivalent;
retain national fallbacks during transition.

## Alternatives

- Wait for CEAP: blocks MVP on an external deadline and unproven operational
  quality.
- Hard switch at launch: risks coverage regressions and removes independent quality
  comparison.

## Consequences

Some temporary provider duplication is intentional. No UI, domain, routing, or API
redesign is needed when CEAP becomes ready. Country-by-country evidence controls
cutover rather than a calendar flag.
