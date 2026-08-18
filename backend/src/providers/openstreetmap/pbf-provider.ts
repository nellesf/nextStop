import { createOSMStream } from "osm-pbf-parser-node";

import type { GeofabrikDatasetArtifact } from "./geofabrik-downloader.js";
import type { OpenStreetMapFoodChain } from "./descriptor.js";

const relevantTagKeys = [
  "amenity",
  "brand",
  "brand:wikidata",
  "name",
  "opening_hours",
  "addr:street",
  "addr:housenumber",
  "addr:postcode",
  "addr:city",
] as const;

const chainByWikidata: Readonly<Record<string, OpenStreetMapFoodChain>> = {
  Q38076: "mcdonalds",
  Q177054: "burger_king",
  Q524757: "kfc",
  Q244457: "subway",
};

const chainByNormalizedAlias: Readonly<Record<string, OpenStreetMapFoodChain>> = {
  mcdonalds: "mcdonalds",
  burgerking: "burger_king",
  kfc: "kfc",
  kentuckyfriedchicken: "kfc",
  subway: "subway",
};

const chainDisplayName: Readonly<Record<OpenStreetMapFoodChain, string>> = {
  mcdonalds: "McDonald's",
  burger_king: "Burger King",
  kfc: "KFC",
  subway: "Subway",
};

type OSMType = "node" | "way" | "relation";
type MatchMethod = "brand_wikidata" | "brand" | "name";
type CoordinateTuple = readonly [longitude: number, latitude: number];

export type FoodPOIGeometry =
  | Readonly<{ type: "Point"; coordinates: CoordinateTuple }>
  | Readonly<{ type: "Polygon"; coordinates: readonly (readonly CoordinateTuple[])[] }>
  | Readonly<{
      type: "MultiPolygon";
      coordinates: readonly (readonly (readonly CoordinateTuple[])[])[];
    }>;

export interface OpenStreetMapFoodPOIRecord {
  readonly osmType: OSMType;
  readonly osmId: number;
  readonly chain: OpenStreetMapFoodChain;
  readonly name: string;
  readonly geometry: FoodPOIGeometry;
  readonly openingHours?: string;
  readonly address: Readonly<{
    street?: string;
    houseNumber?: string;
    postcode?: string;
    city?: string;
  }>;
  readonly matchMethod: MatchMethod;
  readonly sourceRecordURL: string;
  readonly sourceObservedAt: string;
  readonly fetchedAt: string;
}

export interface OpenStreetMapFoodPOIQuarantine {
  readonly sequenceNumber: number;
  readonly osmType?: OSMType;
  readonly osmId?: number;
  readonly issueCodes: readonly string[];
}

export interface ParsedOpenStreetMapFoodPOIs {
  readonly records: readonly OpenStreetMapFoodPOIRecord[];
  readonly quarantines: readonly OpenStreetMapFoodPOIQuarantine[];
}

interface NodeEntity {
  readonly type: "node";
  readonly id: number;
  readonly lat: number;
  readonly lon: number;
  readonly tags?: Readonly<Record<string, string>>;
}

interface WayEntity {
  readonly type: "way";
  readonly id: number;
  readonly refs: readonly number[];
  readonly tags?: Readonly<Record<string, string>>;
}

interface RelationEntity {
  readonly type: "relation";
  readonly id: number;
  readonly members: readonly Readonly<{
    type: "node" | "way" | "relation";
    ref: number;
    role: string;
  }>[];
  readonly tags?: Readonly<Record<string, string>>;
}

type OSMEntity = NodeEntity | WayEntity | RelationEntity;

interface TargetBase {
  readonly osmType: OSMType;
  readonly osmId: number;
  readonly tags: Readonly<Record<string, string>>;
  readonly chain: OpenStreetMapFoodChain;
  readonly matchMethod: MatchMethod;
}

type Target =
  | (TargetBase & Readonly<{ osmType: "node"; coordinate: CoordinateTuple }>)
  | (TargetBase & Readonly<{ osmType: "way"; refs: readonly number[] }>)
  | (TargetBase &
      Readonly<{
        osmType: "relation";
        members: readonly Readonly<{ ref: number; role: string }>[];
      }>);

export async function readOpenStreetMapFoodPOIs(
  artifacts: readonly GeofabrikDatasetArtifact[],
): Promise<ParsedOpenStreetMapFoodPOIs> {
  const bySourceKey = new Map<string, OpenStreetMapFoodPOIRecord>();
  const quarantines: OpenStreetMapFoodPOIQuarantine[] = [];
  for (const artifact of artifacts) {
    const parsed = await readArtifact(artifact);
    for (const record of parsed.records) {
      const key = `${record.osmType}:${record.osmId}`;
      const existing = bySourceKey.get(key);
      if (existing === undefined || record.sourceObservedAt > existing.sourceObservedAt) {
        bySourceKey.set(key, record);
      }
    }
    for (const quarantine of parsed.quarantines) {
      quarantines.push({
        ...quarantine,
        sequenceNumber: quarantines.length + 1,
      });
    }
  }
  return {
    records: [...bySourceKey.values()].toSorted(compareRecords),
    quarantines,
  };
}

export function classifyFoodPOI(
  tags: Readonly<Record<string, string>>,
): Readonly<{ chain: OpenStreetMapFoodChain; matchMethod: MatchMethod }> | undefined {
  if (!["fast_food", "restaurant", "cafe"].includes(tags.amenity ?? "")) {
    return undefined;
  }
  const wikidataValues = (tags["brand:wikidata"] ?? "")
    .split(";")
    .map((value) => value.trim());
  for (const wikidata of wikidataValues) {
    const chain = chainByWikidata[wikidata];
    if (chain !== undefined) {
      return { chain, matchMethod: "brand_wikidata" };
    }
  }
  const brand = chainByNormalizedAlias[normalizeAlias(tags.brand ?? "")];
  if (brand !== undefined) {
    return { chain: brand, matchMethod: "brand" };
  }
  const name = chainByNormalizedAlias[normalizeAlias(tags.name ?? "")];
  return name === undefined ? undefined : { chain: name, matchMethod: "name" };
}

export function stitchOuterRings(
  memberReferences: readonly (readonly number[])[],
): readonly (readonly number[])[] | undefined {
  const remaining = memberReferences
    .filter((references) => references.length >= 2)
    .map((references) => [...references]);
  const rings: number[][] = [];
  while (remaining.length > 0) {
    const ring = remaining.shift();
    if (ring === undefined) {
      break;
    }
    while (ring[0] !== ring.at(-1)) {
      const first = ring[0];
      const last = ring.at(-1);
      const index = remaining.findIndex((candidate) =>
        [candidate[0], candidate.at(-1)].some((endpoint) => endpoint === first || endpoint === last),
      );
      if (index < 0) {
        return undefined;
      }
      const candidate = remaining.splice(index, 1)[0];
      if (candidate === undefined || first === undefined || last === undefined) {
        return undefined;
      }
      if (candidate[0] === last) {
        ring.push(...candidate.slice(1));
      } else if (candidate.at(-1) === last) {
        ring.push(...candidate.toReversed().slice(1));
      } else if (candidate.at(-1) === first) {
        ring.unshift(...candidate.slice(0, -1));
      } else if (candidate[0] === first) {
        ring.unshift(...candidate.toReversed().slice(0, -1));
      }
    }
    if (ring.length < 4) {
      return undefined;
    }
    rings.push(ring);
  }
  return rings;
}

async function readArtifact(
  artifact: GeofabrikDatasetArtifact,
): Promise<ParsedOpenStreetMapFoodPOIs> {
  const targets: Target[] = [];
  const tagOptions = {
    node: [...relevantTagKeys],
    way: [...relevantTagKeys],
    relation: [...relevantTagKeys],
  };
  for await (const value of createOSMStream(artifact.filePath, {
    withTags: tagOptions,
    withInfo: false,
  })) {
    const entity = parseEntity(value);
    if (entity === undefined || entity.tags === undefined) {
      continue;
    }
    const match = classifyFoodPOI(entity.tags);
    if (match === undefined) {
      continue;
    }
    if (entity.type === "node") {
      targets.push({
        osmType: "node",
        osmId: entity.id,
        tags: entity.tags,
        ...match,
        coordinate: [entity.lon, entity.lat],
      });
    } else if (entity.type === "way") {
      targets.push({
        osmType: "way",
        osmId: entity.id,
        tags: entity.tags,
        ...match,
        refs: entity.refs,
      });
    } else {
      targets.push({
        osmType: "relation",
        osmId: entity.id,
        tags: entity.tags,
        ...match,
        members: entity.members
          .filter((member) => member.type === "way" && member.role !== "inner")
          .map(({ ref, role }) => ({ ref, role })),
      });
    }
  }

  const relationWayIDs = new Set(
    targets.flatMap((target) =>
      target.osmType === "relation" ? target.members.map(({ ref }) => ref) : [],
    ),
  );
  const relationWayReferences = new Map<number, readonly number[]>();
  if (relationWayIDs.size > 0) {
    for await (const value of createOSMStream(artifact.filePath, {
      withTags: false,
      withInfo: false,
    })) {
      const entity = parseEntity(value);
      if (entity?.type === "way" && relationWayIDs.has(entity.id)) {
        relationWayReferences.set(entity.id, entity.refs);
      }
    }
  }

  const requiredNodeIDs = new Set<number>();
  for (const target of targets) {
    if (target.osmType === "way") {
      target.refs.forEach((id) => requiredNodeIDs.add(id));
    } else if (target.osmType === "relation") {
      for (const member of target.members) {
        relationWayReferences.get(member.ref)?.forEach((id) => requiredNodeIDs.add(id));
      }
    }
  }
  const nodeCoordinates = new Map<number, CoordinateTuple>();
  if (requiredNodeIDs.size > 0) {
    for await (const value of createOSMStream(artifact.filePath, {
      withTags: false,
      withInfo: false,
    })) {
      const entity = parseEntity(value);
      if (entity?.type === "node" && requiredNodeIDs.has(entity.id)) {
        nodeCoordinates.set(entity.id, [entity.lon, entity.lat]);
      }
    }
  }

  const records: OpenStreetMapFoodPOIRecord[] = [];
  const quarantines: OpenStreetMapFoodPOIQuarantine[] = [];
  for (const target of targets) {
    const geometry = geometryFor(target, relationWayReferences, nodeCoordinates);
    const issues = validateTarget(target, geometry);
    if (issues.length > 0 || geometry === undefined) {
      quarantines.push({
        sequenceNumber: quarantines.length + 1,
        osmType: target.osmType,
        osmId: target.osmId,
        issueCodes: issues.length === 0 ? ["invalid_geometry"] : issues,
      });
      continue;
    }
    const name = boundedOptional(target.tags.name, 200) ?? chainDisplayName[target.chain];
    records.push({
      osmType: target.osmType,
      osmId: target.osmId,
      chain: target.chain,
      name,
      geometry,
      ...optionalString("openingHours", boundedOptional(target.tags.opening_hours, 500)),
      address: {
        ...optionalString("street", boundedOptional(target.tags["addr:street"], 200)),
        ...optionalString("houseNumber", boundedOptional(target.tags["addr:housenumber"], 50)),
        ...optionalString("postcode", boundedOptional(target.tags["addr:postcode"], 20)),
        ...optionalString("city", boundedOptional(target.tags["addr:city"], 200)),
      },
      matchMethod: target.matchMethod,
      sourceRecordURL: `https://www.openstreetmap.org/${target.osmType}/${target.osmId}`,
      sourceObservedAt: artifact.observedAt,
      fetchedAt: artifact.fetchedAt,
    });
  }
  return { records, quarantines };
}

function geometryFor(
  target: Target,
  relationWayReferences: ReadonlyMap<number, readonly number[]>,
  nodeCoordinates: ReadonlyMap<number, CoordinateTuple>,
): FoodPOIGeometry | undefined {
  if (target.osmType === "node") {
    return validCoordinate(target.coordinate)
      ? { type: "Point", coordinates: target.coordinate }
      : undefined;
  }
  if (target.osmType === "way") {
    const ring = coordinatesForRing(target.refs, nodeCoordinates);
    return ring === undefined ? undefined : { type: "Polygon", coordinates: [ring] };
  }
  const references = target.members.flatMap((member) => {
    const value = relationWayReferences.get(member.ref);
    return value === undefined ? [] : [value];
  });
  const rings = stitchOuterRings(references);
  if (rings === undefined) {
    return undefined;
  }
  const polygons = rings.flatMap((ring) => {
    const coordinates = coordinatesForRing(ring, nodeCoordinates);
    return coordinates === undefined ? [] : [[coordinates] as const];
  });
  return polygons.length === 0
    ? undefined
    : { type: "MultiPolygon", coordinates: polygons };
}

function coordinatesForRing(
  references: readonly number[],
  nodeCoordinates: ReadonlyMap<number, CoordinateTuple>,
): readonly CoordinateTuple[] | undefined {
  if (references.length < 4 || references[0] !== references.at(-1)) {
    return undefined;
  }
  const coordinates = references.map((id) => nodeCoordinates.get(id));
  if (coordinates.some((coordinate) => coordinate === undefined)) {
    return undefined;
  }
  return coordinates as readonly CoordinateTuple[];
}

function validateTarget(target: Target, geometry: FoodPOIGeometry | undefined): string[] {
  const issues: string[] = [];
  if (!Number.isSafeInteger(target.osmId) || target.osmId <= 0) {
    issues.push("invalid_osm_id");
  }
  if (geometry === undefined) {
    issues.push("invalid_geometry");
  }
  if (target.tags.name !== undefined && boundedOptional(target.tags.name, 200) === undefined) {
    issues.push("invalid_name");
  }
  if (
    target.tags.opening_hours !== undefined &&
    boundedOptional(target.tags.opening_hours, 500) === undefined
  ) {
    issues.push("invalid_opening_hours");
  }
  return issues;
}

function parseEntity(value: unknown): OSMEntity | undefined {
  if (typeof value !== "object" || value === null || !("type" in value)) {
    return undefined;
  }
  const type = value.type;
  if (!(type === "node" || type === "way" || type === "relation")) {
    return undefined;
  }
  if (!("id" in value) || !Number.isSafeInteger(value.id) || Number(value.id) <= 0) {
    return undefined;
  }
  const id = Number(value.id);
  const tags = parseTags("tags" in value ? value.tags : undefined);
  if (type === "node") {
    if (!("lat" in value) || !("lon" in value)) {
      return undefined;
    }
    const lat = Number(value.lat);
    const lon = Number(value.lon);
    return validCoordinate([lon, lat]) ? { type, id, lat, lon, ...optionalTags(tags) } : undefined;
  }
  if (type === "way") {
    const refs = "refs" in value ? parsePositiveIDs(value.refs) : undefined;
    return refs === undefined ? undefined : { type, id, refs, ...optionalTags(tags) };
  }
  if (!("members" in value) || !Array.isArray(value.members)) {
    return undefined;
  }
  const rawMembers: unknown[] = value.members as unknown[];
  const members: RelationEntity["members"][number][] = rawMembers.flatMap((member) => {
    if (
      typeof member !== "object" ||
      member === null ||
      !("type" in member) ||
      !("ref" in member) ||
      !("role" in member) ||
      !(member.type === "node" || member.type === "way" || member.type === "relation") ||
      !Number.isSafeInteger(member.ref) ||
      Number(member.ref) <= 0 ||
      typeof member.role !== "string"
    ) {
      return [];
    }
    const memberType = member.type;
    return [{ type: memberType, ref: Number(member.ref), role: member.role }];
  });
  return { type, id, members, ...optionalTags(tags) };
}

function parseTags(value: unknown): Readonly<Record<string, string>> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  const tags: Record<string, string> = {};
  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "string" && relevantTagKeys.includes(key as never)) {
      tags[key] = item;
    }
  }
  return tags;
}

function parsePositiveIDs(value: unknown): readonly number[] | undefined {
  if (
    !Array.isArray(value) ||
    value.some((item) => !Number.isSafeInteger(item) || Number(item) <= 0)
  ) {
    return undefined;
  }
  return value.map(Number);
}

function validCoordinate([longitude, latitude]: CoordinateTuple): boolean {
  return (
    Number.isFinite(longitude) &&
    Number.isFinite(latitude) &&
    longitude >= -180 &&
    longitude <= 180 &&
    latitude >= -90 &&
    latitude <= 90
  );
}

function normalizeAlias(value: string): string {
  return value
    .normalize("NFKD")
    .replaceAll(/\p{Mark}/gu, "")
    .toLowerCase()
    .replaceAll(/[^a-z0-9]/gu, "");
}

function boundedOptional(value: string | undefined, maximumLength: number): string | undefined {
  const trimmed = value?.trim();
  return trimmed === undefined || trimmed.length === 0 || trimmed.length > maximumLength
    ? undefined
    : trimmed;
}

function optionalString<Key extends string>(key: Key, value: string | undefined) {
  return value === undefined ? {} : { [key]: value };
}

function optionalTags(tags: Readonly<Record<string, string>> | undefined) {
  return tags === undefined ? {} : { tags };
}

function compareRecords(
  first: OpenStreetMapFoodPOIRecord,
  second: OpenStreetMapFoodPOIRecord,
): number {
  return first.chain.localeCompare(second.chain)
    || first.osmType.localeCompare(second.osmType)
    || first.osmId - second.osmId;
}
