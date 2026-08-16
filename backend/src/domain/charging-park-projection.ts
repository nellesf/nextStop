import {
  earthCenteredCoordinate,
  geodesicDistanceMeters,
} from "./geodesy.js";
import type {
  AvailabilityState,
  ChargingParkProjection,
  EVSEIdentityConflict,
  NormalizedChargingLocation,
  NormalizedChargingPoint,
  OperatorChargingPointCount,
  SourceReference,
} from "./normalized-charging.js";
import { stableId } from "./stable-id.js";

export const chargingParkMaximumDiameterMeters = 200;

export function buildChargingParkProjection(
  locations: readonly NormalizedChargingLocation[],
): readonly ChargingParkProjection[] {
  const activeLocations = locations
    .filter((location) => location.active)
    .toSorted((first, second) => first.id.localeCompare(second.id));
  assertUniqueLocationIds(activeLocations);

  const components = connectedComponents(activeLocations);
  const clusters = components.flatMap(clusterComponent);
  return clusters
    .map(aggregatePark)
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
): readonly (readonly NormalizedChargingLocation[])[] {
  const parents = locations.map((_, index) => index);
  const buckets = new Map<string, number[]>();

  locations.forEach((location, index) => {
    const earthCentered = earthCenteredCoordinate(location.coordinate);
    const bucket = [earthCentered.x, earthCentered.y, earthCentered.z].map((value) =>
      Math.floor(value / chargingParkMaximumDiameterMeters),
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
            if (
              neighbor !== undefined &&
              geodesicDistanceMeters(location.coordinate, neighbor.coordinate) <=
                chargingParkMaximumDiameterMeters
            ) {
              union(parents, index, neighborIndex);
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

function aggregatePark(
  members: readonly NormalizedChargingLocation[],
): ChargingParkProjection {
  const sortedMembers = members.toSorted((first, second) => first.id.localeCompare(second.id));
  const pointMemberships = deduplicatePointMemberships(
    sortedMembers.flatMap((member) =>
      member.chargingPoints.map((point) => ({
        operatorName: member.operatorName,
        point,
      })),
    ),
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
): readonly PointMembership[] {
  const groups = new Map<string, PointMembership[]>();
  for (const membership of memberships) {
    const key = membership.point.canonicalEVSEIdentity ?? membership.point.id;
    const group = groups.get(key) ?? [];
    group.push(membership);
    groups.set(key, group);
  }
  return [...groups.entries()]
    .toSorted(([first], [second]) => first.localeCompare(second))
    .map(([, group]) => {
      const sorted = group.toSorted(
        (first, second) =>
          first.point.id.localeCompare(second.point.id) ||
          first.operatorName.localeCompare(second.operatorName),
      );
      const selected = sorted[0];
      if (selected === undefined) {
        throw new Error("Cannot merge an empty EVSE membership group.");
      }
      return {
        operatorName: selected.operatorName,
        point: mergeExactPointGroup(sorted.map(({ point }) => point)),
      };
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
