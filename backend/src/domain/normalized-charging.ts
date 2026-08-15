export type AvailabilityState =
  | "available"
  | "occupied"
  | "out_of_service"
  | "reserved"
  | "unknown";

export type IdentityDecision = "exact" | "unresolved";

export interface SourceReference {
  readonly providerId: string;
  readonly sourceRecordId: string;
  readonly qualityTier: "authority";
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly contentHash: string;
}

export interface NormalizedChargingConnector {
  readonly sourceValue: string;
  readonly maximumPowerKW?: number;
}

export interface NormalizedChargingPoint {
  readonly id: string;
  readonly nativeIdentity?: string;
  readonly providerEVSEKey?: string;
  readonly canonicalEVSEIdentity?: string;
  readonly identityDecision: IdentityDecision;
  readonly connectors: readonly NormalizedChargingConnector[];
  readonly maximumPowerKW: number;
  readonly availability: Readonly<{
    state: AvailabilityState;
    isLive: boolean;
    observedAt?: string;
  }>;
  readonly sourceReference: SourceReference;
}

export interface NormalizedChargingLocation {
  readonly id: string;
  readonly name: string;
  readonly operatorName: string;
  readonly coordinate: Readonly<{
    latitude: number;
    longitude: number;
  }>;
  readonly address: Readonly<{
    street?: string;
    houseNumber?: string;
    postalCode?: string;
    city?: string;
    state?: string;
  }>;
  readonly chargingPoints: readonly NormalizedChargingPoint[];
  readonly active: boolean;
  readonly sourceReference: SourceReference;
}

export interface NormalizedLocationObservation {
  readonly location: NormalizedChargingLocation;
  readonly rawPayload: Readonly<Record<string, unknown>>;
}

export interface QuarantinedProviderRecord {
  readonly rowNumber: number;
  readonly sourceRecordId?: string;
  readonly issueCodes: readonly string[];
}

export interface ChargingParkProjection {
  readonly id: string;
  readonly name: string;
  readonly centroid: Readonly<{
    latitude: number;
    longitude: number;
  }>;
  readonly navigationCoordinate: Readonly<{
    latitude: number;
    longitude: number;
  }>;
  readonly memberLocationIds: readonly string[];
  readonly operators: readonly string[];
  readonly chargingPointCount: number;
  readonly availability: Readonly<{
    knownAvailableCount: number;
    knownUnavailableCount: number;
    unknownCount: number;
    totalCount: number;
    complete: boolean;
    lastLiveObservationAt?: string;
  }>;
  readonly maximumPowerKW: number;
  readonly sourceReferences: readonly SourceReference[];
  readonly lastStaticObservationAt: string;
}

export interface EVSEIdentityConflict {
  readonly id: string;
  readonly type: "evse_coordinate_disagreement";
  readonly canonicalEVSEIdentity: string;
  readonly locationIds: readonly string[];
  readonly chargingPointIds: readonly string[];
  readonly maximumDistanceMeters: number;
  readonly resolution: "kept_distinct";
}
