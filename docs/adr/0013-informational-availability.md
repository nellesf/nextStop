# ADR 0013: Availability is informational

- Status: Accepted
- Date: 2026-08-17

## Context

The MVP has authoritative static charging data for Germany but no nationwide,
authorized live-availability source. A minimum-free-EVSE filter therefore suggests
a reliability and coverage the product cannot currently provide. Even where live
data exists, partial provider coverage would make the same profile behave
differently by region.

## Decision

Remove minimum available EVSEs from saved profiles, ride drafts, iPhone and CarPlay
editors, and the candidate-search API. Availability remains normalized and visible
as informational data when a provider supplies it, but it never includes or
excludes a charging candidate.

The minimum charging-point criterion remains and counts only deduplicated EVSEs
that satisfy the selected minimum power. The legacy SwiftData availability field
is retained as an ignored optional column so existing local profile stores remain
readable.

## Alternatives

- Keep the three-valued filter: logically safe for unknown values, but still
  presents an availability choice that cannot be delivered consistently.
- Hide the filter only in Germany: creates region-dependent profile semantics and
  complicates CarPlay presentation.
- Treat unknown as unavailable: would incorrectly remove most German candidates.

## Consequences

Profiles and ride summaries have four criteria instead of five. The version 1 API
rejects the removed field rather than silently accepting a criterion it does not
apply. Live availability ingestion and provenance remain in place for truthful
status presentation and can support a future product decision without changing
EVSE identity or provider boundaries.
