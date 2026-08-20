# ADR 0002: CarPlay template selection

- Status: Accepted
- Date: 2026-08-13

## Context

The product is an EV-charging CarPlay app, not a navigation app. It needs fixed
choices, a map/list of no more than five charging results, details, and Apple Maps
handoff.

## Decision

Use `CPListTemplate` for selection/summary/relaxation,
`CPPointOfInterestTemplate` for final map + picker results,
`CPInformationTemplate`/POI detail card for detail, and system alert templates for
concise failures. Require `com.apple.developer.carplay-charging`.

## Alternatives

- `CPMapTemplate`: rejected because it belongs to navigation experiences and would
  imply custom map/navigation behavior outside scope.
- Custom UIKit/SwiftUI on the vehicle display: not supported by the template model
  and conflicts with driving-safety guidance.

## Consequences

The system owns layout/input adaptation. Content must respect runtime item limits.
The CarPlay surface remains blocked until Apple grants the entitlement, so presenters
must remain testable without it.
