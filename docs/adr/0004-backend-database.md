# ADR 0004: Backend database

- Status: Accepted
- Date: 2026-08-13

## Context

The system needs normalized relational identity, raw JSON payloads, atomic
projection publication, geospatial indexing, provenance/conflict history, and
standard operational tooling.

## Decision

Use PostgreSQL as the single MVP database. Keep raw provider metadata/payloads,
normalized observations, identity decisions, clusters, and active search
projections in explicit schemas/tables.

## Alternatives

- Document database: convenient raw ingestion but weaker relational identity,
  constraints, and projection transactions.
- Separate search/geospatial store: adds synchronization and operations before
  measured need.

## Consequences

One database simplifies transactional rebuilds and recovery. Schema migrations and
least-privilege roles become critical. Large raw payload retention must be bounded
by provider license and replay need.
