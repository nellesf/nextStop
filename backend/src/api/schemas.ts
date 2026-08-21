import { minimumPowerOptions } from "../domain/candidate-search.js";
import { searchRequestLimits } from "./search-request-limits.js";

const routeEnvelope = searchRequestLimits.supportedRouteEnvelope;

const coordinateTupleSchema = {
  type: "array",
  minItems: 2,
  maxItems: 2,
  items: [
    {
      type: "number",
      minimum: routeEnvelope.minimumLongitude,
      maximum: routeEnvelope.maximumLongitude,
    },
    {
      type: "number",
      minimum: routeEnvelope.minimumLatitude,
      maximum: routeEnvelope.maximumLatitude,
    },
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
          maxItems: searchRequestLimits.maximumRouteCoordinateCount,
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
        minimumPowerKW: {
          type: "integer",
          enum: minimumPowerOptions,
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

const chargingLocationLookupSchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "operatorName", "coordinate", "address"],
  properties: {
    id: { type: "string", format: "uuid" },
    operatorName: { type: "string", minLength: 1, maxLength: 200 },
    coordinate: coordinateSchema,
    address: {
      type: "object",
      additionalProperties: false,
      properties: {
        street: { type: "string", minLength: 1, maxLength: 200 },
        houseNumber: { type: "string", minLength: 1, maxLength: 50 },
        postalCode: { type: "string", minLength: 1, maxLength: 20 },
        city: { type: "string", minLength: 1, maxLength: 200 },
      },
    },
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
    "operatorChargingPoints",
    "locationLookups",
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
    operatorChargingPoints: {
      type: "array",
      minItems: 1,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["name", "chargingPoints"],
        properties: {
          name: { type: "string", minLength: 1 },
          chargingPoints: { type: "integer", minimum: 1 },
        },
      },
    },
    locationLookups: {
      type: "array",
      minItems: 1,
      items: chargingLocationLookupSchema,
    },
    sources: { type: "array", minItems: 1, items: sourceSummarySchema },
    dataUpdatedAt: { type: "string", format: "date-time" },
    foodPOI: {
      type: ["object", "null"],
      additionalProperties: false,
      required: [
        "id", "chain", "name", "coordinate",
        "distanceFromChargingParkMeters", "sourceRecordURL",
      ],
      properties: {
        id: { type: "string", minLength: 1 },
        chain: { type: "string", enum: ["mcdonalds", "burger_king", "kfc", "subway"] },
        name: { type: "string", minLength: 1, maxLength: 200 },
        coordinate: coordinateSchema,
        distanceFromChargingParkMeters: { type: "integer", minimum: 0, maximum: 500 },
        openingHours: { type: ["string", "null"] },
        sourceRecordURL: { type: "string", format: "uri" },
      },
    },
  },
} as const;

const attributionSchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "name", "notice", "licenseName", "licenseURL"],
  properties: {
    id: { type: "string", minLength: 1 },
    name: { type: "string", minLength: 1 },
    notice: { type: "string", minLength: 1 },
    licenseName: { type: "string", minLength: 1 },
    licenseURL: { type: "string", format: "uri" },
    transportName: { type: ["string", "null"] },
    transportURL: { type: ["string", "null"], format: "uri" },
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
  required: ["snapshotToken", "candidates", "coverage", "generatedAt", "attributions"],
  properties: {
    snapshotToken: { type: "string" },
    nextCursor: { type: ["string", "null"] },
    generatedAt: { type: "string", format: "date-time" },
    candidates: { type: "array", maxItems: 50, items: candidateSchema },
    coverage: coverageSchema,
    attributions: { type: "array", uniqueItems: true, items: attributionSchema },
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
    errorId: {
      type: "string",
      minLength: 16,
      maxLength: 128,
      pattern: "^[A-Za-z0-9_-]+$",
    },
  },
} as const;
