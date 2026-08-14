const coordinateTupleSchema = {
  type: "array",
  minItems: 2,
  maxItems: 2,
  items: [
    { type: "number", minimum: -180, maximum: 180 },
    { type: "number", minimum: -90, maximum: 90 },
  ],
  additionalItems: false,
} as const;

const distanceRangeSchema = {
  oneOf: [
    {
      type: "object",
      additionalProperties: false,
      required: ["minimum", "maximum"],
      properties: { minimum: { const: 15_000 }, maximum: { const: 50_000 } },
    },
    {
      type: "object",
      additionalProperties: false,
      required: ["minimum", "maximum"],
      properties: { minimum: { const: 50_000 }, maximum: { const: 100_000 } },
    },
    {
      type: "object",
      additionalProperties: false,
      required: ["minimum", "maximum"],
      properties: { minimum: { const: 100_000 }, maximum: { const: 150_000 } },
    },
  ],
} as const;

export const searchRequestSchema = {
  $id: "SearchRequest",
  type: "object",
  additionalProperties: false,
  required: ["requestId", "route", "criteria"],
  properties: {
    requestId: { type: "string", format: "uuid" },
    route: {
      type: "object",
      additionalProperties: false,
      required: ["type", "coordinates"],
      properties: {
        type: { const: "LineString" },
        coordinates: {
          type: "array",
          minItems: 2,
          maxItems: 20_000,
          items: coordinateTupleSchema,
        },
      },
    },
    criteria: {
      type: "object",
      additionalProperties: false,
      required: ["distanceRangeMeters", "minimumChargingPoints", "minimumPowerKW"],
      properties: {
        distanceRangeMeters: distanceRangeSchema,
        minimumChargingPoints: { type: "integer", enum: [2, 4, 6, 8, 10, 12, 16, 20] },
        minimumAvailablePoints: {
          type: ["integer", "null"],
          enum: [null, 1, 2, 4, 6, 8, 10],
        },
        minimumPowerKW: {
          type: "integer",
          enum: [11, 22, 50, 100, 150, 200, 250, 300, 350, 400],
        },
        foodChain: {
          type: ["string", "null"],
          enum: [null, "mcdonalds", "burger_king", "kfc", "subway"],
        },
      },
    },
    page: {
      type: "object",
      additionalProperties: false,
      properties: {
        snapshotToken: { type: "string", maxLength: 512 },
        cursor: { type: "string", maxLength: 512 },
      },
    },
  },
} as const;

const coordinateSchema = {
  type: "object",
  additionalProperties: false,
  required: ["latitude", "longitude"],
  properties: {
    latitude: { type: "number", minimum: -90, maximum: 90 },
    longitude: { type: "number", minimum: -180, maximum: 180 },
  },
} as const;

const availabilitySchema = {
  type: "object",
  additionalProperties: false,
  required: ["knownAvailable", "knownUnavailable", "unknown", "total", "complete"],
  properties: {
    knownAvailable: { type: "integer", minimum: 0 },
    knownUnavailable: { type: "integer", minimum: 0 },
    unknown: { type: "integer", minimum: 0 },
    total: { type: "integer", minimum: 1 },
    complete: { type: "boolean" },
    observedAt: { type: ["string", "null"], format: "date-time" },
  },
} as const;

const sourceSummarySchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "name", "qualityTier", "staticObservedAt"],
  properties: {
    id: { type: "string" },
    name: { type: "string" },
    qualityTier: { type: "string", enum: ["operator", "authority", "open_data", "community"] },
    staticObservedAt: { type: "string", format: "date-time" },
    liveObservedAt: { type: ["string", "null"], format: "date-time" },
  },
} as const;

const candidateSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "id",
    "name",
    "coordinate",
    "navigationCoordinate",
    "distanceFromRouteMeters",
    "straightLineLowerBoundMeters",
    "chargingPoints",
    "availability",
    "maximumPowerKW",
    "operators",
    "sources",
    "dataUpdatedAt",
  ],
  properties: {
    id: { type: "string", format: "uuid" },
    name: { type: "string", minLength: 1, maxLength: 200 },
    coordinate: coordinateSchema,
    navigationCoordinate: coordinateSchema,
    distanceFromRouteMeters: { type: "integer", minimum: 0, maximum: 5_000 },
    preliminaryRouteProgressMeters: { type: "integer", minimum: 0 },
    straightLineLowerBoundMeters: { type: "integer", minimum: 0 },
    chargingPoints: { type: "integer", minimum: 1 },
    availability: availabilitySchema,
    maximumPowerKW: { type: "integer", minimum: 1 },
    operators: { type: "array", uniqueItems: true, items: { type: "string" } },
    sources: { type: "array", minItems: 1, items: sourceSummarySchema },
    dataUpdatedAt: { type: "string", format: "date-time" },
  },
} as const;

const coverageSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "activeSources", "unavailableSources", "projectionUpdatedAt"],
  properties: {
    status: { type: "string", enum: ["complete", "degraded", "stale"] },
    activeSources: { type: "array", items: { type: "string" } },
    unavailableSources: { type: "array", items: { type: "string" } },
    projectionUpdatedAt: { type: "string", format: "date-time" },
  },
} as const;

export const searchResponseSchema = {
  type: "object",
  additionalProperties: false,
  required: ["snapshotToken", "candidates", "coverage", "generatedAt"],
  properties: {
    snapshotToken: { type: "string" },
    nextCursor: { type: ["string", "null"] },
    generatedAt: { type: "string", format: "date-time" },
    candidates: { type: "array", maxItems: 50, items: candidateSchema },
    coverage: coverageSchema,
  },
} as const;

export const problemSchema = {
  type: "object",
  additionalProperties: true,
  required: ["type", "title", "status", "errorId"],
  properties: {
    type: { type: "string" },
    title: { type: "string" },
    status: { type: "integer", minimum: 400, maximum: 599 },
    detail: { type: "string" },
    errorId: { type: "string", format: "uuid" },
  },
} as const;
