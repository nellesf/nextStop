import assert from "node:assert/strict";
import test from "node:test";

import {
  buildChargingParkProjection,
  findEVSEIdentityConflicts,
} from "../../src/domain/charging-park-projection.js";
import type {
  AvailabilityState,
  NormalizedChargingLocation,
} from "../../src/domain/normalized-charging.js";

void test("clusters different operators at 100 m and aggregates distinct EVSEs", () => {
  const first = location("a", 0, "Alpha", [point("a-1", 150), point("a-2", 22)]);
  const second = location("b", 100, "Beta", [point("b-1", 300)]);

  const parks = buildChargingParkProjection([second, first]);

  assert.equal(parks.length, 1);
  assert.deepEqual(parks[0]?.memberLocationIds, ["a", "b"]);
  assert.deepEqual(parks[0]?.operators, ["Alpha", "Beta"]);
  assert.deepEqual(parks[0]?.operatorChargingPointCounts, [
    { operatorName: "Alpha", chargingPointCount: 2 },
    { operatorName: "Beta", chargingPointCount: 1 },
  ]);
  assert.equal(parks[0]?.chargingPointCount, 3);
  assert.equal(parks[0]?.maximumPowerKW, 300);
  assert.equal(parks[0]?.availability.unknownCount, 3);
  assert.equal(parks[0]?.availability.complete, false);
  assert.deepEqual(parks[0]?.navigationCoordinate, first.coordinate);
});

void test("clusters locations at 199 m and separates locations over 200 m", () => {
  assert.equal(
    buildChargingParkProjection([
      location("a", 0, "Alpha", [point("a-1", 22)]),
      location("b", 199, "Beta", [point("b-1", 22)]),
    ]).length,
    1,
  );
  assert.equal(
    buildChargingParkProjection([
      location("a", 0, "Alpha", [point("a-1", 22)]),
      location("b", 201, "Beta", [point("b-1", 22)]),
    ]).length,
    2,
  );
});

void test("complete-link clustering prevents transitive 300 m chains", () => {
  const parks = buildChargingParkProjection([
    location("c", 300, "Gamma", [point("c-1", 50)]),
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 150, "Beta", [point("b-1", 50)]),
  ]);

  assert.deepEqual(
    parks.map((park) => park.memberLocationIds),
    [["a", "b"], ["c"]],
  );
});

void test("all input permutations yield identical membership and stable park IDs", () => {
  const locations = [
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 100, "Beta", [point("b-1", 50)]),
    location("c", 500, "Gamma", [point("c-1", 50)]),
  ];
  const expected = buildChargingParkProjection(locations);
  for (const permutation of permutations(locations)) {
    assert.deepEqual(buildChargingParkProjection(permutation), expected);
  }
});

void test("deduplicates an exact EVSE identity but not distinct EVSEs at one coordinate", () => {
  const sharedIdentity = "DEABCE42";
  const parks = buildChargingParkProjection([
    location("a", 0, "Alpha", [point("source-a", 150, sharedIdentity)]),
    location("b", 0, "Beta", [
      point("source-b", 300, sharedIdentity),
      point("distinct", 22),
    ]),
  ]);

  assert.equal(parks[0]?.chargingPointCount, 2);
  assert.deepEqual(parks[0]?.operatorChargingPointCounts, [
    { operatorName: "Alpha", chargingPointCount: 1 },
    { operatorName: "Beta", chargingPointCount: 1 },
  ]);
  assert.equal(parks[0]?.maximumPowerKW, 300);
});

void test("counts only fresh live availability as known", () => {
  const parks = buildChargingParkProjection([
    location("a", 0, "Alpha", [
      point("available", 150, undefined, "available", true),
      point("occupied", 150, undefined, "occupied", true),
      point("static", 150),
    ]),
  ]);

  assert.deepEqual(parks[0]?.availability, {
    knownAvailableCount: 1,
    knownUnavailableCount: 1,
    unknownCount: 1,
    totalCount: 3,
    complete: false,
    lastLiveObservationAt: "2026-08-14T07:00:00.000Z",
  });
});

void test("keeps a conflicting exact EVSE identity distinct and records why", () => {
  const sharedIdentity = "DEABCE42";
  const conflicts = findEVSEIdentityConflicts([
    location("a", 0, "Alpha", [point("source-a", 150, sharedIdentity)]),
    location("b", 300, "Beta", [point("source-b", 150, sharedIdentity)]),
  ]);

  assert.equal(conflicts.length, 1);
  assert.equal(conflicts[0]?.canonicalEVSEIdentity, sharedIdentity);
  assert.deepEqual(conflicts[0]?.locationIds, ["a", "b"]);
  assert.equal(conflicts[0]?.resolution, "kept_distinct");
  assert.ok((conflicts[0]?.maximumDistanceMeters ?? 0) > 200);
  assert.equal(
    buildChargingParkProjection([
      location("a", 0, "Alpha", [point("source-a", 150, sharedIdentity)]),
      location("b", 300, "Beta", [point("source-b", 150, sharedIdentity)]),
    ]).length,
    2,
  );
});

function location(
  id: string,
  northMeters: number,
  operatorName: string,
  chargingPoints: NormalizedChargingLocation["chargingPoints"],
): NormalizedChargingLocation {
  const sourceReference = source(`location-${id}`);
  return {
    id,
    name: `Site ${id.toUpperCase()}`,
    operatorName,
    coordinate: {
      latitude: 52 + northMeters / 111_267,
      longitude: 10,
    },
    address: {},
    chargingPoints,
    active: true,
    sourceReference,
  };
}

function point(
  id: string,
  maximumPowerKW: number,
  canonicalEVSEIdentity?: string,
  state: AvailabilityState = "unknown",
  isLive = false,
): NormalizedChargingLocation["chargingPoints"][number] {
  return {
    id,
    ...(canonicalEVSEIdentity === undefined ? {} : { canonicalEVSEIdentity }),
    identityDecision: canonicalEVSEIdentity === undefined ? "unresolved" : "exact",
    connectors: [{ sourceValue: "fixture", maximumPowerKW }],
    maximumPowerKW,
    availability: {
      state,
      isLive,
      ...(isLive ? { observedAt: "2026-08-14T07:00:00.000Z" } : {}),
    },
    sourceReference: source(`point-${id}`),
  };
}

function source(sourceRecordId: string) {
  return {
    providerId: "fixture",
    sourceRecordId,
    qualityTier: "authority",
    observedAt: "2026-08-13T00:00:00.000Z",
    fetchedAt: "2026-08-14T07:00:00.000Z",
    contentHash: sourceRecordId.padEnd(64, "0").slice(0, 64),
  } as const;
}

function permutations<T>(values: readonly T[]): readonly (readonly T[])[] {
  if (values.length <= 1) {
    return [values];
  }
  return values.flatMap((value, index) =>
    permutations([...values.slice(0, index), ...values.slice(index + 1)]).map(
      (remaining) => [value, ...remaining],
    ),
  );
}
