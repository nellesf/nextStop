export type DistanceRangeMeters =
  | Readonly<{ minimum: 15_000; maximum: 50_000 }>
  | Readonly<{ minimum: 50_000; maximum: 100_000 }>
  | Readonly<{ minimum: 100_000; maximum: 150_000 }>;

export type MinimumChargingPoints = 2 | 4 | 6 | 8 | 10 | 12 | 16 | 20;
export type MinimumPowerKW = 11 | 22 | 50 | 100 | 150 | 200 | 250 | 300 | 350 | 400;
export type FoodChain = "mcdonalds" | "burger_king" | "kfc" | "subway";
export type QualityTier = "operator" | "authority" | "open_data" | "community";
export type CoverageStatus = "complete" | "degraded" | "stale";
export type LongitudeLatitude = readonly [longitude: number, latitude: number];

export interface SearchRequest {
  readonly requestId: string;
  readonly route: Readonly<{
    type: "LineString";
    coordinates: readonly LongitudeLatitude[];
  }>;
  readonly criteria: Readonly<{
    distanceRangeMeters: DistanceRangeMeters;
    minimumChargingPoints: MinimumChargingPoints;
    minimumPowerKW: MinimumPowerKW;
    foodChain?: FoodChain | null;
  }>;
  readonly page?: Readonly<{
    snapshotToken?: string;
    cursor?: string;
  }>;
}

export interface SearchResponse {
  readonly snapshotToken: string;
  readonly nextCursor?: string | null;
  readonly generatedAt: string;
  readonly candidates: readonly ChargingParkCandidate[];
  readonly coverage: Coverage;
  readonly attributions: readonly DataAttribution[];
}

export interface ChargingParkCandidate {
  readonly id: string;
  readonly name: string;
  readonly coordinate: Coordinate;
  readonly navigationCoordinate: Coordinate;
  readonly distanceFromRouteMeters: number;
  readonly preliminaryRouteProgressMeters?: number;
  readonly straightLineLowerBoundMeters: number;
  readonly chargingPoints: number;
  readonly availability: ParkAvailability;
  readonly maximumPowerKW: number;
  readonly operators: readonly string[];
  readonly operatorChargingPoints: readonly OperatorChargingPoints[];
  readonly sources: readonly SourceSummary[];
  readonly dataUpdatedAt: string;
  readonly foodPOI?: FoodPOISummary | null;
}

export interface FoodPOISummary {
  readonly id: string;
  readonly chain: FoodChain;
  readonly name: string;
  readonly coordinate: Coordinate;
  readonly distanceFromChargingParkMeters: number;
  readonly openingHours?: string | null;
  readonly sourceRecordURL: string;
}

export interface DataAttribution {
  readonly id: string;
  readonly name: string;
  readonly notice: string;
  readonly licenseName: string;
  readonly licenseURL: string;
  readonly transportName?: string | null;
  readonly transportURL?: string | null;
}

export interface OperatorChargingPoints {
  readonly name: string;
  readonly chargingPoints: number;
}

export interface Coordinate {
  readonly latitude: number;
  readonly longitude: number;
}

export interface ParkAvailability {
  readonly knownAvailable: number;
  readonly knownUnavailable: number;
  readonly unknown: number;
  readonly total: number;
  readonly complete: boolean;
  readonly observedAt?: string | null;
}

export interface SourceSummary {
  readonly id: string;
  readonly name: string;
  readonly qualityTier: QualityTier;
  readonly staticObservedAt: string;
  readonly liveObservedAt?: string | null;
}

export interface Coverage {
  readonly status: CoverageStatus;
  readonly activeSources: readonly string[];
  readonly unavailableSources: readonly string[];
  readonly projectionUpdatedAt: string;
}
