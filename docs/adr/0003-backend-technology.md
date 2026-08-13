# ADR 0003: Backend technology

- Status: Accepted
- Date: 2026-08-13

## Context

The backend normalizes heterogeneous feeds, validates untrusted payloads, performs
scheduled ingestion and spatial queries, and exposes a small versioned API. The MVP
should be a modular monolith.

## Decision

Use strict TypeScript on Node.js active LTS with Fastify, JSON-schema/OpenAPI runtime
validation, and a thin PostgreSQL query/migration layer. Deploy API and worker roles
from one codebase/artifact.

## Alternatives

- Swift server stack: shared language and types, but smaller ingestion/PostGIS
  ecosystem and less independent backend/iOS evolution.
- Python/FastAPI: strong data/geospatial ecosystem and fast development, but weaker
  compile-time constraints unless heavily disciplined.

## Consequences

The team operates Swift and TypeScript. Node.js tooling must be installed locally.
Provider DTO validation and strict compiler/lint rules are mandatory; generated
framework abstractions must not hide spatial SQL or provenance rules.
