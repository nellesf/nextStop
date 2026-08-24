# ADR 0016: Passenger-car access exclusions

- Status: Accepted
- Date: 2026-08-24

## Context

nextStop is a passenger-car product. Charging locations that are accessible only
to trucks are therefore not valid search candidates, even when their connectors
and charging power would technically fit a passenger car.

The German Bundesnetzagentur source does not provide a structured passenger-car
or truck access field. Its general parking information is not a reliable vehicle
classification. Milence states that all of its hubs are exclusively for electric
trucks and that passenger cars may neither enter nor charge there. The currently
normalized German operator name is exactly `Milence Germany GmbH`.

Aral pulse is different: Aral operates separately designated passenger-car and
truck charging points at some shared locations. The current authority source does
not expose that distinction per EVSE, so an operator-wide Aral rule would remove
valid passenger-car charging points.

Evidence reviewed for this decision:

- <https://milence.com/faq/>
- <https://milence.com/app/uploads/2025/06/EN_Milence-House-Rules_June-2025-2.pdf>
- <https://mein.aral.de/kontakt/faqs/strom-laden/e-lkw-laden>
- <https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenkarte/start.html>

## Decision

Maintain a small, evidence-backed backend policy for charging operators whose
locations are known to forbid passenger cars. The initial policy contains only
the exact normalized operator name `Milence Germany GmbH`.

Apply this policy before fine-park and campus clustering. Excluded locations must
not create, merge, bridge, count toward, name, or determine the navigation
coordinate of a passenger-car search candidate. The power projections are built
only from the resulting passenger-car candidate parks and campuses.

Retain provider records, normalized locations, normalized EVSEs, and identity
conflicts for audit and provenance. Identity conflicts are an audit projection and
do not make an excluded location searchable. A conflict that exists only because
of an excluded location is stored with resolution `audit_only`; only a conflict
that also exists among eligible passenger-car locations remains `kept_distinct`
for search deduplication. This prevents excluded evidence from changing an
eligible park's EVSE count while preserving the full conflict record.

An operator without an exact policy match remains `unknown` and eligible. Do not
infer a prohibition from a partial operator-name match, connector type, charging
power, or the Bundesnetzagentur parking text. In particular, do not exclude Aral
pulse without an authoritative EVSE-level classification.

This is a backend search invariant, not a vehicle-profile option or a request
criterion. Adding mixed-operator or EVSE-level inference requires a reviewed
amendment with an authoritative data source.

## Consequences

Milence locations no longer appear in passenger-car results and cannot alter
nearby result aggregation. Their source evidence remains available for audit.

The static projection policy version changes so an unchanged provider dataset is
rebuilt once under the new rule. A successful publish atomically replaces the old
search projection.

This narrow rule does not solve mixed passenger-car/truck infrastructure such as
Aral pulse. That requires a future provider or standard field with reliable
vehicle access at parking-place or EVSE granularity.
