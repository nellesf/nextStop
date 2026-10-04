# Product backlog

This is the durable record of requested future work for nextStop. Entries are
deferred until the owner requests implementation. Recording an idea does not
change the accepted product rules or authorize implementation.

## Status overview

| ID | Requested feature | Status | Added | Implementation evidence |
| --- | --- | --- | --- | --- |
| BL-001 | Add Austria, preferably with live charging availability | Open | 2026-10-04 | None |
| BL-002 | Add advertising | Open | 2026-10-04 | None |

## BL-001 Austria coverage

Include Austrian charging locations in route searches. Prefer live charging
availability where a suitable source can provide it; feasibility remains to be
checked when this work is scheduled. Missing live data must remain unknown and
must not exclude otherwise eligible candidates.

Before implementation, assess Austrian static and live sources, EVSE identity,
coverage, freshness, access and licensing, and the restaurant coverage needed for
food-filtered searches. Follow the existing provider approval and onboarding
process. See [charging data source research](research/charging-data-sources.md)
and [provider architecture](architecture/providers.md).

## BL-002 Advertising

Add advertising in a future product iteration. Placement, format and provider
remain undecided.

Advertising is currently excluded from the MVP by [AGENTS.md](../AGENTS.md).
Before implementation, obtain the owner's explicit approval for the corresponding
product-rule change and document the intended scope and privacy implications.
This backlog entry does not change the current MVP boundary.

## Maintaining the backlog

- Keep stable IDs and retain completed entries.
- Use `Open`, `In progress`, `Implemented` or `Dropped`. Only `Implemented` means
  the feature has been completed; list dropped items separately from pending work.
- Update the status with the implementation work. Mark an entry `Implemented`
  only after its requested scope is complete, with a commit or PR reference and
  relevant verification evidence. Record deployment or device-validation gaps
  separately rather than treating a pushed branch as a release.
- For status questions, compare this record with the current implementation and
  Git history. Report partial work and remaining gaps explicitly; do not infer
  completion from a plan or an ADR.
