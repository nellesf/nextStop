import {
  buildChargingCampusProjection,
  buildChargingParkProjection,
  findEVSEIdentityConflicts,
} from "./charging-park-projection.js";
import type {
  ChargingCampusProjection,
  ChargingParkProjection,
  EVSEIdentityConflict,
  NormalizedChargingLocation,
} from "./normalized-charging.js";
import { passengerCarSearchLocations } from "./passenger-car-access.js";

export interface PassengerCarChargingProjection {
  readonly parks: readonly ChargingParkProjection[];
  readonly campuses: readonly ChargingCampusProjection[];
  readonly conflicts: readonly EVSEIdentityConflict[];
}

export function buildPassengerCarChargingProjection(
  locations: readonly NormalizedChargingLocation[],
): PassengerCarChargingProjection {
  const eligibleLocations = passengerCarSearchLocations(locations);
  const eligibleConflictIdentities = new Set(
    findEVSEIdentityConflicts(eligibleLocations).map(
      ({ canonicalEVSEIdentity }) => canonicalEVSEIdentity,
    ),
  );
  const parks = buildChargingParkProjection(eligibleLocations);
  return {
    parks,
    campuses: buildChargingCampusProjection(eligibleLocations, parks),
    conflicts: findEVSEIdentityConflicts(locations).map(
      (conflict): EVSEIdentityConflict =>
        eligibleConflictIdentities.has(conflict.canonicalEVSEIdentity)
          ? conflict
          : { ...conflict, resolution: "audit_only" },
    ),
  };
}
