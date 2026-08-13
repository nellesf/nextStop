# ADR 0007: Charging-data provider abstraction

- Status: Accepted
- Date: 2026-08-13

## Context

Europe has heterogeneous NAP, authority, operator, and community feeds. CEAP will
arrive later. UI, routing, filtering, and ranking must not depend on one source.

## Decision

Define provider fetch/health ports and source-private validated DTO mappers that
emit normalized observations with provenance. Perform identity, conflict
resolution, clustering, and projection only after normalization.

## Alternatives

- Provider-specific domain/repository logic: faster for the first source but makes
  every later source a cross-cutting rewrite.
- A universal protocol client only: insufficient because source semantics,
  omissions, auth, quality, and versions vary even under common standards.

## Consequences

Every provider has more explicit adapter/test/documentation work. In return it can
be shadowed, disabled, replaced, or superseded by CEAP without changing UI/search
policy.
