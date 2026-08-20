import {
  earthCenteredCoordinate,
  geodesicDistanceMeters,
} from "./geodesy.js";
import type {
  AvailabilityState,
  ChargingCampusProjection,
  ChargingParkProjection,
  EVSEIdentityConflict,
  NormalizedChargingLocation,
  NormalizedChargingPoint,
  OperatorChargingPointCount,
  SourceReference,
} from "./normalized-charging.js";
import { stableId } from "./stable-id.js";

export const chargingParkMaximumDiameterMeters = 200;
export const chargingCampusMaximumNeighborDistanceMeters = 200;
export const chargingCampusMaximumDiameterMeters = 500;

export function buildChargingParkProjection(
  locations: readonly NormalizedChargingLocation[],
): readonly ChargingParkProjection[] {
  const conflictingCanonicalEVSEIdentities = new Set(
    findEVSEIdentityConflicts(locations).map(({ canonicalEVSEIdentity }) =>
      canonicalEVSEIdentity,
    ),
  );
  const activeLocations = locations
    .filter((location) => location.active)
    .toSorted((first, second) => first.id.localeCompare(second.id));
  assertUniqueLocationIds(activeLocations);

  return connectedComponents(
    activeLocations,
    chargingParkMaximumDiameterMeters,
  )
    .flatMap(clusterComponent)
    .map((members) => aggregatePark(members, conflictingCanonicalEVSEIdentities))
    .toSorted((first, second) => first.id.localeCompare(second.id));
}

export function buildChargingCampusProjection(
  locations: readonly NormalizedChargingLocation[],
  fineParks: readonly ChargingParkProjection[],
): readonly ChargingCampusProjection[] {
  const activeLocations = locations
    .filter((location) => location.active)
    .toSorted((first, second) => first.id.localeCompare(second.id));
  assertUniqueLocationIds(activeLocations);

  const sortedFineParks = fineParks.toSorted((first, second) =>
    first.id.localeCompare(second.id),
  );
  assertUniqueParkIds(sortedFineParks);
  const activeLocationById = new Map(
    activeLocations.map((location) => [location.id, location]),
  );
  const fineParkIndexByLocationId = validateFineParkSeeds(
    activeLocations,
    sortedFineParks,
    activeLocationById,
  );
  const parents = sortedFineParks.map((_, index) => index);
  const memberLocationsByRoot = sortedFineParks.map((park) =>
    park.memberLocationIds
      .map((locationId) => requiredLocation(activeLocationById, locationId))
      .toSorted((first, second) => first.id.localeCompare(second.id)),
  );
  const rejectedRootPairs = new Set<string>();

  for (const edge of locationNeighborEdges(
    activeLocations,
    chargingCampusMaximumNeighborDistanceMeters,
  )) {
    const firstLocation = activeLocations[edge.firstIndex];
    const secondLocation = activeLocations[edge.secondIndex];
    if (firstLocation === undefined || secondLocation === undefined) {
      throw new Error("Campus neighbor edge references an unknown location.");
    }
    const firstParkIndex = fineParkIndexByLocationId.get(firstLocation.id);
    const secondParkIndex = fineParkIndexByLocationId.get(secondLocation.id);
    if (firstParkIndex === undefined || secondParkIndex === undefined) {
      throw new Error("Campus neighbor edge references a location without a fine park.");
    }
    const firstRoot = find(parents, firstParkIndex);
    const secondRoot = find(parents, secondParkIndex);
    if (firstRoot === secondRoot) {
      continue;
    }

    const lowerRoot = Math.min(firstRoot, secondRoot);
    const higherRoot = Math.max(firstRoot, secondRoot);
    const pairKey = `${lowerRoot}:${higherRoot}`;
    if (rejectedRootPairs.has(pairKey)) {
      continue;
    }
    const lowerMembers = memberLocationsByRoot[lowerRoot];
    const higherMembers = memberLocationsByRoot[higherRoot];
    if (lowerMembers === undefined || higherMembers === undefined) {
      throw new Error("Campus cluster members disappeared during aggregation.");
    }
    if (!canMergeCampusClusters(lowerMembers, higherMembers)) {
      rejectedRootPairs.add(pairKey);
      continue;
    }

    parents[higherRoot] = lowerRoot;
    memberLocationsByRoot[lowerRoot] = [...lowerMembers, ...higherMembers].toSorted(
      (first, second) => first.id.localeCompare(second.id),
    );
    memberLocationsByRoot[higherRoot] = [];
  }

  const fineParksByRoot = new Map<number, ChargingParkProjection[]>();
  sortedFineParks.forEach((park, index) => {
    const root = find(parents, index);
    const group = fineParksByRoot.get(root) ?? [];
    group.push(park);
    fineParksByRoot.set(root, group);
  });
  const conflictingCanonicalEVSEIdentities = new Set(
    findEVSEIdentityConflicts(locations).map(({ canonicalEVSEIdentity }) =>
      canonicalEVSEIdentity,
    ),
  );

  return [...fineParksByRoot.values()]
    .map((parks) => {
      const memberParkIds = parks
        .map((park) => park.id)
        .toSorted((first, second) => first.localeCompare(second));
      const memberLocations = parks
        .flatMap((park) =>
          park.memberLocationIds.map((locationId) =>
            requiredLocation(activeLocationById, locationId),
          ),
        )
        .toSorted((first, second) => first.id.localeCompare(second.id));
      const aggregate = aggregatePark(
        memberLocations,
        conflictingCanonicalEVSEIdentities,
      );
      return {
        ...aggregate,
        id: stableId("charging-campus-v1", memberParkIds),
        memberParkIds,
      };
    })
    .toSorted((first, second) => first.id.localeCompare(second.id));
}

export function findEVSEIdentityConflicts(
  locations: readonly NormalizedChargingLocation[],
): readonly EVSEIdentityConflict[] {
  const byIdentity = new Map<
    string,
    { location: NormalizedChargingLocation; point: NormalizedChargingPoint }[]
  >();
  for (const location of locations) {
    for (const point of location.chargingPoints) {
      if (point.canonicalEVSEIdentity === undefined) {
        continue;
      }
      const group = byIdentity.get(point.canonicalEVSEIdentity) ?? [];
      group.push({ location, point });
      byIdentity.set(point.canonicalEVSEIdentity, group);
    }
  }

  const conflicts: EVSEIdentityConflict[] = [];
  for (const [canonicalEVSEIdentity, group] of byIdentity) {
    const maximumDistanceMeters = maximumLocationDistance(
      group.map(({ location }) => location),
    );
    if (maximumDistanceMeters <= chargingParkMaximumDiameterMeters) {
      continue;
    }
    const locationIds = sortedDistinct(group.map(({ location }) => location.id));
    const chargingPointIds = sortedDistinct(group.map(({ point }) => point.id));
    conflicts.push({
      id: stableId("evse-identity-conflict-v1", [
        canonicalEVSEIdentity,
        ...locationIds,
        ...chargingPointIds,
      ]),
      type: "evse_coordinate_disagreement",
      canonicalEVSEIdentity,
      locationIds,
      chargingPointIds,
      maximumDistanceMeters: Math.ceil(maximumDistanceMeters),
      resolution: "kept_distinct",
    });
  }
  return conflicts.toSorted((first, second) => first.id.localeCompare(second.id));
}

function connectedComponents(
  locations: readonly NormalizedChargingLocation[],
  maximumNeighborDistanceMeters: number,
): readonly (readonly NormalizedChargingLocation[])[] {
  const parents = locations.map((_, index) => index);
  for (const edge of locationNeighborEdges(
    locations,
    maximumNeighborDistanceMeters,
  )) {
    union(parents, edge.firstIndex, edge.secondIndex);
  }

  const grouped = new Map<number, NormalizedChargingLocation[]>();
  locations.forEach((location, index) => {
    const root = find(parents, index);
    const group = grouped.get(root) ?? [];
    group.push(location);
    grouped.set(root, group);
  });
  return [...grouped.values()].toSorted((first, second) =>
    clusterKey(first).localeCompare(clusterKey(second)),
  );
}

function clusterComponent(
  component: readonly NormalizedChargingLocation[],
): readonly (readonly NormalizedChargingLocation[])[] {
  const clusters: NormalizedChargingLocation[][] = component.map((location) => [location]);

  while (true) {
    let best: Readonly<{
      firstIndex: number;
      secondIndex: number;
      distance: number;
      key: string;
    }> | undefined;

    for (let firstIndex = 0; firstIndex < clusters.length; firstIndex += 1) {
      const first = clusters[firstIndex];
      if (first === undefined) {
        continue;
      }
      for (let secondIndex = firstIndex + 1; secondIndex < clusters.length; secondIndex += 1) {
        const second = clusters[secondIndex];
        if (second === undefined) {
          continue;
        }
        const distance = completeLinkDistance(first, second);
        if (distance === undefined) {
          continue;
        }
        const key = `${clusterKey(first)}\u0000${clusterKey(second)}`;
        if (
          best === undefined ||
          distance < best.distance ||
          (distance === best.distance && key.localeCompare(best.key) < 0)
        ) {
          best = { firstIndex, secondIndex, distance, key };
        }
      }
    }

    if (best === undefined) {
      break;
    }
    const first = clusters[best.firstIndex];
    const second = clusters[best.secondIndex];
    if (first === undefined || second === undefined) {
      throw new Error("Selected charging-park clusters disappeared.");
    }
    const merged = [...first, ...second].toSorted((left, right) =>
      left.id.localeCompare(right.id),
    );
    clusters.splice(best.secondIndex, 1);
    clusters.splice(best.firstIndex, 1);
    clusters.push(merged);
    clusters.sort((left, right) => clusterKey(left).localeCompare(clusterKey(right)));
  }

  return clusters;
}

function completeLinkDistance(
  first: readonly NormalizedChargingLocation[],
  second: readonly NormalizedChargingLocation[],
): number | undefined {
  let maximumDistance = 0;
  for (const firstLocation of first) {
    for (const secondLocation of second) {
      const distance = geodesicDistanceMeters(
        firstLocation.coordinate,
        secondLocation.coordinate,
      );
      if (distance > chargingParkMaximumDiameterMeters) {
        return undefined;
      }
      maximumDistance = Math.max(maximumDistance, distance);
    }
  }
  return maximumDistance;
}

interface LocationNeighborEdge {
  readonly firstIndex: number;
  readonly secondIndex: number;
  readonly distanceMeters: number;
}

function locationNeighborEdges(
  locations: readonly NormalizedChargingLocation[],
  maximumNeighborDistanceMeters: number,
): readonly LocationNeighborEdge[] {
  const buckets = new Map<string, number[]>();
  const edges: LocationNeighborEdge[] = [];

  locations.forEach((location, index) => {
    const earthCentered = earthCenteredCoordinate(location.coordinate);
    const bucket = [earthCentered.x, earthCentered.y, earthCentered.z].map((value) =>
      Math.floor(value / maximumNeighborDistanceMeters),
    );
    for (let xOffset = -1; xOffset <= 1; xOffset += 1) {
      for (let yOffset = -1; yOffset <= 1; yOffset += 1) {
        for (let zOffset = -1; zOffset <= 1; zOffset += 1) {
          const neighborKey = bucketKey(
            (bucket[0] ?? 0) + xOffset,
            (bucket[1] ?? 0) + yOffset,
            (bucket[2] ?? 0) + zOffset,
          );
          for (const neighborIndex of buckets.get(neighborKey) ?? []) {
            const neighbor = locations[neighborIndex];
            if (neighbor === undefined) {
              continue;
            }
            const distanceMeters = geodesicDistanceMeters(
              neighbor.coordinate,
              location.coordinate,
            );
            if (distanceMeters <= maximumNeighborDistanceMeters) {
              edges.push({
                firstIndex: neighborIndex,
                secondIndex: index,
                distanceMeters,
              });
            }
          }
        }
      }
    }
    const ownKey = bucketKey(bucket[0] ?? 0, bucket[1] ?? 0, bucket[2] ?? 0);
    const ownBucket = buckets.get(ownKey) ?? [];
    ownBucket.push(index);
    buckets.set(ownKey, ownBucket);
  });

  return edges.toSorted((first, second) => {
    const firstStartId = locations[first.firstIndex]?.id;
    const secondStartId = locations[second.firstIndex]?.id;
    const firstEndId = locations[first.secondIndex]?.id;
    const secondEndId = locations[second.secondIndex]?.id;
    if (
      firstStartId === undefined ||
      secondStartId === undefined ||
      firstEndId === undefined ||
      secondEndId === undefined
    ) {
      throw new Error("Neighbor edge references an unknown location.");
    }
    return (
      first.distanceMeters - second.distanceMeters ||
      firstStartId.localeCompare(secondStartId) ||
      firstEndId.localeCompare(secondEndId)
    );
  });
}

function canMergeCampusClusters(
  first: readonly NormalizedChargingLocation[],
  second: readonly NormalizedChargingLocation[],
): boolean {
  for (const firstLocation of first) {
    for (const secondLocation of second) {
      if (
        geodesicDistanceMeters(
          firstLocation.coordinate,
          secondLocation.coordinate,
        ) > chargingCampusMaximumDiameterMeters
      ) {
        return false;
      }
    }
  }
  return true;
}

function aggregatePark(
  members: readonly NormalizedChargingLocation[],
  conflictingCanonicalEVSEIdentities: ReadonlySet<string>,
): ChargingParkProjection {
  const sortedMembers = members.toSorted((first, second) => first.id.localeCompare(second.id));
  const pointMemberships = deduplicatePointMemberships(
    sortedMembers.flatMap((member) =>
      member.chargingPoints.map((point) => ({
        operatorName: member.operatorName,
        point,
      })),
    ),
    conflictingCanonicalEVSEIdentities,
  );
  const points = pointMemberships.map(({ point }) => point);
  if (points.length === 0) {
    throw new Error("An active charging location must contain at least one EVSE.");
  }
  const sourceReferences = distinctSourceReferences(
    sortedMembers.flatMap((member) => [
      member.sourceReference,
      ...member.chargingPoints.map((point) => point.sourceReference),
    ]),
  );
  const availability = aggregateAvailability(points);
  const memberLocationIds = sortedMembers.map((member) => member.id);
  const names = sortedDistinct(sortedMembers.map((member) => member.name));
  const operatorChargingPointCounts = aggregateOperatorChargingPointCounts(pointMemberships);
  const operators = operatorChargingPointCounts.map(({ operatorName }) => operatorName);

  return {
    id: stableId("charging-park-v1", memberLocationIds),
    name: names.length === 1 ? (names[0] ?? "Ladepark") : composeParkName(operators),
    centroid: centroid(sortedMembers),
    navigationCoordinate: medoid(sortedMembers).coordinate,
    memberLocationIds,
    operators,
    operatorChargingPointCounts,
    chargingPointCount: points.length,
    availability,
    maximumPowerKW: Math.max(...points.map((point) => point.maximumPowerKW)),
    sourceReferences,
    lastStaticObservationAt: latestInstant(
      sourceReferences.map((reference) => reference.observedAt),
    ),
  };
}

interface PointMembership {
  readonly operatorName: string;
  readonly point: NormalizedChargingPoint;
}

function deduplicatePointMemberships(
  memberships: readonly PointMembership[],
  conflictingCanonicalEVSEIdentities: ReadonlySet<string>,
): readonly PointMembership[] {
  const groups = new Map<string, PointMembership[]>();
  for (const membership of memberships) {
    const key = membership.point.canonicalEVSEIdentity === undefined
      ? `point:${membership.point.id}`
      : `canonical:${membership.point.canonicalEVSEIdentity}`;
    const group = groups.get(key) ?? [];
    group.push(membership);
    groups.set(key, group);
  }
  return [...groups.entries()]
    .toSorted(([first], [second]) => first.localeCompare(second))
    .flatMap(([, group]) => {
      const sorted = group.toSorted(
        (first, second) =>
          first.point.id.localeCompare(second.point.id) ||
          first.operatorName.localeCompare(second.operatorName),
      );
      const selected = sorted[0];
      if (selected === undefined) {
        throw new Error("Cannot merge an empty EVSE membership group.");
      }
      const canonicalEVSEIdentity = selected.point.canonicalEVSEIdentity;
      return canonicalEVSEIdentity !== undefined &&
        conflictingCanonicalEVSEIdentities.has(canonicalEVSEIdentity)
        ? sorted
        : [{
            ...selected,
            point: mergeExactPointGroup(sorted.map(({ point }) => point)),
          }];
    });
}

function aggregateOperatorChargingPointCounts(
  memberships: readonly PointMembership[],
): readonly OperatorChargingPointCount[] {
  const counts = new Map<string, number>();
  for (const { operatorName } of memberships) {
    counts.set(operatorName, (counts.get(operatorName) ?? 0) + 1);
  }
  return [...counts.entries()]
    .toSorted(([first], [second]) => first.localeCompare(second))
    .map(([operatorName, chargingPointCount]) => ({
      operatorName,
      chargingPointCount,
    }));
}

function mergeExactPointGroup(
  group: readonly NormalizedChargingPoint[],
): NormalizedChargingPoint {
  const sorted = group.toSorted((first, second) => first.id.localeCompare(second.id));
  const first = sorted[0];
  if (first === undefined) {
    throw new Error("Cannot merge an empty EVSE group.");
  }
  const states = new Set(sorted.map((point) => point.availability.state));
  const state: AvailabilityState = states.size === 1 ? first.availability.state : "unknown";
  const observedAt = latestOptionalInstant(
    sorted.flatMap((point) =>
      point.availability.observedAt === undefined ? [] : [point.availability.observedAt],
    ),
  );
  return {
    ...first,
    connectors: sorted.flatMap((point) => point.connectors),
    maximumPowerKW: Math.max(...sorted.map((point) => point.maximumPowerKW)),
    availability: {
      state,
      isLive: sorted.every((point) => point.availability.isLive),
      ...(observedAt === undefined ? {} : { observedAt }),
    },
  };
}

function aggregateAvailability(
  points: readonly NormalizedChargingPoint[],
): ChargingParkProjection["availability"] {
  let knownAvailableCount = 0;
  let knownUnavailableCount = 0;
  let unknownCount = 0;
  const liveInstants: string[] = [];
  for (const point of points) {
    if (!point.availability.isLive || point.availability.state === "unknown") {
      unknownCount += 1;
      continue;
    }
    if (point.availability.state === "available") {
      knownAvailableCount += 1;
    } else {
      knownUnavailableCount += 1;
    }
    if (point.availability.observedAt !== undefined) {
      liveInstants.push(point.availability.observedAt);
    }
  }
  const lastLiveObservationAt = latestOptionalInstant(liveInstants);
  return {
    knownAvailableCount,
    knownUnavailableCount,
    unknownCount,
    totalCount: points.length,
    complete: unknownCount === 0,
    ...(lastLiveObservationAt === undefined ? {} : { lastLiveObservationAt }),
  };
}

function centroid(
  members: readonly NormalizedChargingLocation[],
): Readonly<{ latitude: number; longitude: number }> {
  return {
    latitude:
      members.reduce((sum, member) => sum + member.coordinate.latitude, 0) /
      members.length,
    longitude:
      members.reduce((sum, member) => sum + member.coordinate.longitude, 0) /
      members.length,
  };
}

function medoid(
  members: readonly NormalizedChargingLocation[],
): NormalizedChargingLocation {
  const ranked = members.map((member) => ({
    member,
    totalDistance: members.reduce(
      (sum, other) =>
        sum + geodesicDistanceMeters(member.coordinate, other.coordinate),
      0,
    ),
  }));
  ranked.sort(
    (first, second) =>
      first.totalDistance - second.totalDistance ||
      first.member.id.localeCompare(second.member.id),
  );
  const selected = ranked[0]?.member;
  if (selected === undefined) {
    throw new Error("Cannot select a medoid for an empty park.");
  }
  return selected;
}

function distinctSourceReferences(
  references: readonly SourceReference[],
): readonly SourceReference[] {
  const byIdentity = new Map<string, SourceReference>();
  for (const reference of references) {
    const key = `${reference.providerId}\u0000${reference.sourceRecordId}\u0000${reference.contentHash}`;
    byIdentity.set(key, reference);
  }
  return [...byIdentity.entries()]
    .toSorted(([first], [second]) => first.localeCompare(second))
    .map(([, reference]) => reference);
}

function latestInstant(instants: readonly string[]): string {
  const latest = latestOptionalInstant(instants);
  if (latest === undefined) {
    throw new Error("At least one source instant is required.");
  }
  return latest;
}

function latestOptionalInstant(instants: readonly string[]): string | undefined {
  return instants.toSorted().at(-1);
}

function composeParkName(operators: readonly string[]): string {
  if (operators.length === 0) {
    return "Ladepark";
  }
  if (operators.length <= 2) {
    return operators.join(" & ");
  }
  return `${operators[0] ?? "Ladepark"} + ${operators.length - 1}`;
}

function sortedDistinct(values: readonly string[]): readonly string[] {
  return [...new Set(values)].toSorted((first, second) => first.localeCompare(second));
}

function maximumLocationDistance(
  locations: readonly NormalizedChargingLocation[],
): number {
  let maximumDistance = 0;
  for (let firstIndex = 0; firstIndex < locations.length; firstIndex += 1) {
    const first = locations[firstIndex];
    if (first === undefined) {
      continue;
    }
    for (let secondIndex = firstIndex + 1; secondIndex < locations.length; secondIndex += 1) {
      const second = locations[secondIndex];
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

function assertUniqueLocationIds(locations: readonly NormalizedChargingLocation[]): void {
  for (let index = 1; index < locations.length; index += 1) {
    if (locations[index - 1]?.id === locations[index]?.id) {
      throw new Error(`Duplicate charging location ID: ${locations[index]?.id ?? "unknown"}`);
    }
  }
}

function assertUniqueParkIds(parks: readonly ChargingParkProjection[]): void {
  for (let index = 1; index < parks.length; index += 1) {
    if (parks[index - 1]?.id === parks[index]?.id) {
      throw new Error(`Duplicate charging park ID: ${parks[index]?.id ?? "unknown"}`);
    }
  }
}

function validateFineParkSeeds(
  activeLocations: readonly NormalizedChargingLocation[],
  fineParks: readonly ChargingParkProjection[],
  activeLocationById: ReadonlyMap<string, NormalizedChargingLocation>,
): ReadonlyMap<string, number> {
  const fineParkIndexByLocationId = new Map<string, number>();

  fineParks.forEach((park, parkIndex) => {
    if (park.memberLocationIds.length === 0) {
      throw new Error(`Charging park ${park.id} has no member locations.`);
    }
    const members = park.memberLocationIds.map((locationId) => {
      if (fineParkIndexByLocationId.has(locationId)) {
        throw new Error(`Charging location ${locationId} belongs to multiple fine parks.`);
      }
      const location = requiredLocation(activeLocationById, locationId);
      fineParkIndexByLocationId.set(locationId, parkIndex);
      return location;
    });
    if (maximumLocationDistance(members) > chargingParkMaximumDiameterMeters) {
      throw new Error(`Charging park ${park.id} exceeds the 200 m fine-park diameter.`);
    }
  });

  for (const location of activeLocations) {
    if (!fineParkIndexByLocationId.has(location.id)) {
      throw new Error(`Active charging location ${location.id} has no fine park.`);
    }
  }
  return fineParkIndexByLocationId;
}

function requiredLocation(
  activeLocationById: ReadonlyMap<string, NormalizedChargingLocation>,
  locationId: string,
): NormalizedChargingLocation {
  const location = activeLocationById.get(locationId);
  if (location === undefined) {
    throw new Error(`Fine park references unknown or inactive location ${locationId}.`);
  }
  return location;
}

function bucketKey(x: number, y: number, z: number): string {
  return `${x}:${y}:${z}`;
}

function clusterKey(cluster: readonly NormalizedChargingLocation[]): string {
  return cluster.map((location) => location.id).toSorted().join("\u0000");
}

function find(parents: number[], value: number): number {
  const parent = parents[value];
  if (parent === undefined) {
    throw new Error("Union-find index is outside the location collection.");
  }
  if (parent === value) {
    return value;
  }
  const root = find(parents, parent);
  parents[value] = root;
  return root;
}

function union(parents: number[], first: number, second: number): void {
  const firstRoot = find(parents, first);
  const secondRoot = find(parents, second);
  if (firstRoot === secondRoot) {
    return;
  }
  const lower = Math.min(firstRoot, secondRoot);
  const higher = Math.max(firstRoot, secondRoot);
  parents[higher] = lower;
}
