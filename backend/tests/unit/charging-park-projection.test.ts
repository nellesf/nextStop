import assert from "node:assert/strict";
import test from "node:test";

import {
  buildChargingCampusProjection,
  buildChargingParkProjection,
  chargingCampusMaximumDiameterMeters,
  findEVSEIdentityConflicts,
} from "../../src/domain/charging-park-projection.js";
import { geodesicDistanceMeters } from "../../src/domain/geodesy.js";
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

void test("fine parks split a transitive 200 m neighbor chain", () => {
  const locations = [
    location("c", 300, "Gamma", [point("c-1", 50)]),
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 150, "Beta", [point("b-1", 50)]),
  ];
  const parks = buildChargingParkProjection(locations);

  assert.deepEqual(sortedMemberships(parks), [["a", "b"], ["c"]]);

  const campuses = buildChargingCampusProjection(locations, parks);
  assert.equal(campuses.length, 1);
  assert.deepEqual(campuses[0]?.memberLocationIds, ["a", "b", "c"]);
  assert.equal(campuses[0]?.memberParkIds.length, 2);
});

void test("campus combines Wertheim fine parks and includes a low-power bridge", () => {
  const locations = [
    location("tesla", 490, "Tesla Germany GmbH", points("tesla", 20)),
    location("home-east", 390, "HomE of Mobility GmbH", points("home-east", 4)),
    location("ewe", 440, "EWE Go GmbH", points("ewe", 2)),
    location("electra", 0, "Electra Germany GmbH", points("electra", 20)),
    location("enbw", 415, "EnBW mobility+ AG und Co.KG", points("enbw", 2)),
    location("home-west", 100, "HomE of Mobility GmbH", points("home-west", 18)),
    location("low-power-bridge", 245, "Bridge Energy GmbH", points("bridge", 2, 50)),
  ];
  const parks = buildChargingParkProjection(locations);

  assert.equal(parks.length, 3);
  assert.deepEqual(
    parks
      .map((park) => qualifyingPointCount(locations, park.memberLocationIds, 150))
      .toSorted((first, second) => first - second),
    [0, 28, 38],
  );

  const campuses = buildChargingCampusProjection(locations, parks);
  assert.equal(campuses.length, 1);
  assert.equal(campuses[0]?.memberParkIds.length, 3);
  assert.deepEqual(campuses[0]?.memberLocationIds, [
    "electra",
    "enbw",
    "ewe",
    "home-east",
    "home-west",
    "low-power-bridge",
    "tesla",
  ]);
  assert.deepEqual(campuses[0]?.operators, [
    "Bridge Energy GmbH",
    "Electra Germany GmbH",
    "EnBW mobility+ AG und Co.KG",
    "EWE Go GmbH",
    "HomE of Mobility GmbH",
    "Tesla Germany GmbH",
  ]);
  assert.deepEqual(campuses[0]?.operatorChargingPointCounts, [
    { operatorName: "Bridge Energy GmbH", chargingPointCount: 2 },
    { operatorName: "Electra Germany GmbH", chargingPointCount: 20 },
    { operatorName: "EnBW mobility+ AG und Co.KG", chargingPointCount: 2 },
    { operatorName: "EWE Go GmbH", chargingPointCount: 2 },
    { operatorName: "HomE of Mobility GmbH", chargingPointCount: 22 },
    { operatorName: "Tesla Germany GmbH", chargingPointCount: 20 },
  ]);
  assert.equal(campuses[0]?.chargingPointCount, 68);
  assert.equal(
    qualifyingPointCount(locations, campuses[0]?.memberLocationIds ?? [], 150),
    66,
  );
});

void test("campus merges just below 500 m and separates just above it", () => {
  const belowLimitLocations = [
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 180, "Beta", [point("b-1", 50)]),
    location("c", 360, "Gamma", [point("c-1", 50)]),
    location("d", 499, "Delta", [point("d-1", 50)]),
  ];
  const belowLimitDiameter = maximumMemberDistance(
    belowLimitLocations,
    belowLimitLocations.map(({ id }) => id),
  );
  assert.ok(belowLimitDiameter < chargingCampusMaximumDiameterMeters);
  assert.ok(belowLimitDiameter > chargingCampusMaximumDiameterMeters - 2);
  const belowLimitCampuses = buildChargingCampusProjection(
    belowLimitLocations,
    buildChargingParkProjection(belowLimitLocations),
  );
  assert.equal(belowLimitCampuses.length, 1);
  assert.equal(
    maximumMemberDistance(
      belowLimitLocations,
      belowLimitCampuses[0]?.memberLocationIds ?? [],
    ),
    belowLimitDiameter,
  );

  const aboveLimitLocations = [
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 180, "Beta", [point("b-1", 50)]),
    location("c", 360, "Gamma", [point("c-1", 50)]),
    location("d", 501, "Delta", [point("d-1", 50)]),
  ];
  assert.ok(
    maximumMemberDistance(
      aboveLimitLocations,
      aboveLimitLocations.map(({ id }) => id),
    ) > chargingCampusMaximumDiameterMeters,
  );
  const aboveLimitCampuses = buildChargingCampusProjection(
    aboveLimitLocations,
    buildChargingParkProjection(aboveLimitLocations),
  );
  assert.equal(aboveLimitCampuses.length, 2);
  for (const campus of aboveLimitCampuses) {
    assert.ok(
      maximumMemberDistance(aboveLimitLocations, campus.memberLocationIds) <=
        chargingCampusMaximumDiameterMeters,
    );
  }
});

void test("campus seed validation rejects missing and duplicate memberships", () => {
  const locations = [
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 500, "Beta", [point("b-1", 50)]),
  ];
  const parks = buildChargingParkProjection(locations);
  assert.equal(parks.length, 2);
  assert.throws(
    () => buildChargingCampusProjection(locations, parks.slice(0, 1)),
    /has no fine park/u,
  );

  const singleLocation = [location("a", 0, "Alpha", [point("a-1", 50)])];
  const park = buildChargingParkProjection(singleLocation)[0];
  assert.ok(park !== undefined);
  assert.throws(
    () =>
      buildChargingCampusProjection(singleLocation, [
        { ...park, memberLocationIds: ["a", "a"] },
      ]),
    /belongs to multiple fine parks/u,
  );
});

void test("all input permutations yield identical campuses and stable campus IDs", () => {
  const locations = [
    location("a", 0, "Alpha", [point("a-1", 50)]),
    location("b", 150, "Beta", [point("b-1", 50)]),
    location("c", 300, "Gamma", [point("c-1", 50)]),
    location("d", 700, "Delta", [point("d-1", 50)]),
  ];
  const expected = buildChargingCampusProjection(
    locations,
    buildChargingParkProjection(locations),
  );

  for (const permutation of permutations(locations)) {
    const parks = buildChargingParkProjection(permutation);
    assert.deepEqual(
      buildChargingCampusProjection(permutation, parks.toReversed()),
      expected,
    );
  }
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

void test("keeps a conflicting EVSE identity distinct inside one bridged campus", () => {
  const sharedIdentity = "DEABCE42";
  const locations = [
    location("a", 0, "Alpha", [point("source-a", 150, sharedIdentity)]),
    location("b", 150, "Beta", [point("bridge", 150)]),
    location("c", 300, "Gamma", [point("source-c", 150, sharedIdentity)]),
  ];

  const parks = buildChargingParkProjection(locations);
  const campuses = buildChargingCampusProjection(locations, parks);
  const conflicts = findEVSEIdentityConflicts(locations);

  assert.equal(parks.length, 2);
  assert.equal(campuses.length, 1);
  assert.deepEqual(campuses[0]?.memberLocationIds, ["a", "b", "c"]);
  assert.equal(campuses[0]?.chargingPointCount, 3);
  assert.deepEqual(campuses[0]?.operatorChargingPointCounts, [
    { operatorName: "Alpha", chargingPointCount: 1 },
    { operatorName: "Beta", chargingPointCount: 1 },
    { operatorName: "Gamma", chargingPointCount: 1 },
  ]);
  assert.equal(conflicts.length, 1);
  assert.equal(conflicts[0]?.canonicalEVSEIdentity, sharedIdentity);
  assert.equal(conflicts[0]?.resolution, "kept_distinct");
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

function points(
  idPrefix: string,
  count: number,
  maximumPowerKW = 150,
): NormalizedChargingLocation["chargingPoints"] {
  return Array.from({ length: count }, (_, index) =>
    point(`${idPrefix}-${index + 1}`, maximumPowerKW),
  );
}

function sortedMemberships(
  projections: readonly Readonly<{ memberLocationIds: readonly string[] }>[],
): readonly (readonly string[])[] {
  return projections
    .map(({ memberLocationIds }) => memberLocationIds)
    .toSorted((first, second) => first.join("\u0000").localeCompare(second.join("\u0000")));
}

function qualifyingPointCount(
  locations: readonly NormalizedChargingLocation[],
  memberLocationIds: readonly string[],
  minimumPowerKW: number,
): number {
  const members = new Set(memberLocationIds);
  return locations
    .filter((candidate) => members.has(candidate.id))
    .flatMap((candidate) => candidate.chargingPoints)
    .filter((candidate) => candidate.maximumPowerKW >= minimumPowerKW).length;
}

function maximumMemberDistance(
  locations: readonly NormalizedChargingLocation[],
  memberLocationIds: readonly string[],
): number {
  const members = locations.filter((candidate) =>
    memberLocationIds.includes(candidate.id),
  );
  let maximumDistance = 0;
  for (let firstIndex = 0; firstIndex < members.length; firstIndex += 1) {
    const first = members[firstIndex];
    if (first === undefined) {
      continue;
    }
    for (let secondIndex = firstIndex + 1; secondIndex < members.length; secondIndex += 1) {
      const second = members[secondIndex];
      if (second !== undefined) {
        maximumDistance = Math.max(
          maximumDistance,
          geodesicDistanceMeters(first.coordinate, second.coordinate),
        );
      }
    }
  }
  return maximumDistance;
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
