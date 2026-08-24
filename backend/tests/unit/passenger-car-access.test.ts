import assert from "node:assert/strict";
import test from "node:test";

import { passengerCarAccessDecision } from "../../src/domain/passenger-car-access.js";
import { buildPassengerCarChargingProjection } from "../../src/domain/passenger-car-charging-projection.js";
import type {
  NormalizedChargingLocation,
  SourceReference,
} from "../../src/domain/normalized-charging.js";

const sourceReference: SourceReference = {
  providerId: "bundesnetzagentur_ladesaeulenregister",
  sourceRecordId: "fixture",
  qualityTier: "authority",
  observedAt: "2026-08-24T00:00:00.000Z",
  fetchedAt: "2026-08-24T00:00:00.000Z",
  contentHash: "a".repeat(64),
};

void test("excludes only the exact documented Milence operator from passenger-car search", () => {
  const milence = makeLocation("milence", "Milence Germany GmbH", 8);
  const aral = makeLocation("aral", "BP Europa SE", 8.01);
  const similarlyNamed = makeLocation(
    "similarly-named",
    "Milence Germany GmbH & Partner",
    8.02,
  );

  const decision = passengerCarAccessDecision(milence);
  assert.equal(decision.status, "forbidden");
  if (decision.status === "forbidden") {
    assert.equal(decision.policy.operatorName, "Milence Germany GmbH");
    assert.equal(decision.policy.evidenceURL, "https://milence.com/faq/");
  }
  assert.equal(passengerCarAccessDecision(aral).status, "unknown");
  assert.equal(passengerCarAccessDecision(similarlyNamed).status, "unknown");
});

void test("Milence cannot affect passenger-car parks, counts, or navigation", () => {
  const aral = makeLocation("aral", "BP Europa SE", 8);
  const milence = makeLocation("milence", "Milence Germany GmbH", 8.0005);

  const projection = buildPassengerCarChargingProjection([aral, milence]);

  assert.equal(projection.parks.length, 1);
  assert.equal(projection.campuses.length, 1);
  assert.equal(projection.conflicts.length, 0);
  assert.deepEqual(projection.parks[0]?.memberLocationIds, [aral.id]);
  assert.deepEqual(projection.parks[0]?.operators, ["BP Europa SE"]);
  assert.equal(projection.parks[0]?.chargingPointCount, 1);
  assert.deepEqual(projection.parks[0]?.navigationCoordinate, aral.coordinate);
});

void test("Milence cannot bridge otherwise separate passenger-car candidates", () => {
  const first = makeLocation("first", "First Passenger Operator", 8);
  const milence = makeLocation("milence", "Milence Germany GmbH", 8.002);
  const second = makeLocation("second", "Second Passenger Operator", 8.004);

  const projection = buildPassengerCarChargingProjection([
    second,
    milence,
    first,
  ]);

  assert.deepEqual(
    projection.parks.map(({ memberLocationIds }) => memberLocationIds).toSorted(),
    [["first"], ["second"]],
  );
  assert.deepEqual(
    projection.campuses.map(({ memberLocationIds }) => memberLocationIds).toSorted(),
    [["first"], ["second"]],
  );
});

void test("retains identity conflicts from excluded locations for audit", () => {
  const canonicalEVSEIdentity = "DEMLEEIDENTITY";
  const first = makeLocation(
    "milence-first",
    "Milence Germany GmbH",
    8,
    canonicalEVSEIdentity,
  );
  const second = makeLocation(
    "milence-second",
    "Milence Germany GmbH",
    8.004,
    canonicalEVSEIdentity,
  );

  const projection = buildPassengerCarChargingProjection([first, second]);

  assert.deepEqual(projection.parks, []);
  assert.deepEqual(projection.campuses, []);
  assert.equal(projection.conflicts.length, 1);
  assert.equal(
    projection.conflicts[0]?.canonicalEVSEIdentity,
    canonicalEVSEIdentity,
  );
  assert.equal(projection.conflicts[0]?.resolution, "audit_only");
  assert.deepEqual(projection.conflicts[0]?.locationIds, [
    "milence-first",
    "milence-second",
  ]);
});

void test("keeps conflicts between eligible locations search-active", () => {
  const canonicalEVSEIdentity = "DEALLOWEDIDENTITY";
  const first = makeLocation(
    "eligible-first",
    "First Passenger Operator",
    8,
    canonicalEVSEIdentity,
  );
  const second = makeLocation(
    "eligible-second",
    "Second Passenger Operator",
    8.004,
    canonicalEVSEIdentity,
  );

  const projection = buildPassengerCarChargingProjection([first, second]);

  assert.equal(projection.conflicts.length, 1);
  assert.equal(projection.conflicts[0]?.resolution, "kept_distinct");
});

function makeLocation(
  id: string,
  operatorName: string,
  longitude: number,
  canonicalEVSEIdentity?: string,
): NormalizedChargingLocation {
  const locationReference = {
    ...sourceReference,
    sourceRecordId: id,
  };
  return {
    id,
    name: operatorName,
    operatorName,
    coordinate: { latitude: 50, longitude },
    address: {},
    active: true,
    sourceReference: locationReference,
    chargingPoints: [
      {
        id: `${id}-point`,
        ...(canonicalEVSEIdentity === undefined
          ? {}
          : { canonicalEVSEIdentity }),
        identityDecision:
          canonicalEVSEIdentity === undefined ? "unresolved" : "exact",
        connectors: [{ sourceValue: "CCS" }],
        maximumPowerKW: 300,
        availability: { state: "unknown", isLive: false },
        sourceReference: locationReference,
      },
    ],
  };
}
