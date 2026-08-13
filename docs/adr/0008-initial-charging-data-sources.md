# ADR 0008: Initial charging data sources

- Status: Accepted
- Date: 2026-08-13

## Context

The vertical slice needs at least one real, free, legally usable source without
prematurely integrating all of Europe. Authority and live-data behavior both need
proof.

## Decision

First ingest Germany's official Bundesnetzagentur static register, which validates
German route relevance and the required unknown-availability behavior. Add
Switzerland's official `ich-tanke-strom` static/live API immediately next. Then
prioritize Netherlands DOT-NL, France IRVE, Norway NOBIL, and UK open OCPI/registry.
Use Open Charge Map only as an open-data-filtered attributed supplement.

## Alternatives

- Switzerland first: demonstrates live availability sooner but does not cover the
  likely first German journeys.
- Open Charge Map first: broad reach, but mixed licenses/community authority and
  weaker live guarantees complicate the foundation.

## Consequences

The first slice intentionally has unknown German availability and limited country
coverage. The UI must handle that honestly. Provider expansion is incremental and
each source needs a license/quality review.
