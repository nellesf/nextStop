import type { NormalizedChargingLocation } from "./normalized-charging.js";

export const passengerCarAccessPolicyVersion = "passenger-car-access-v1";

export interface PassengerCarAccessPolicy {
  readonly operatorName: string;
  readonly access: "forbidden";
  readonly evidenceURL: string;
  readonly reviewedAt: string;
}

export type PassengerCarAccessDecision =
  | Readonly<{
      status: "forbidden";
      policy: PassengerCarAccessPolicy;
    }>
  | Readonly<{ status: "unknown" }>;

const passengerCarAccessPolicies: readonly PassengerCarAccessPolicy[] = [
  {
    operatorName: "Milence Germany GmbH",
    access: "forbidden",
    evidenceURL: "https://milence.com/faq/",
    reviewedAt: "2026-08-24",
  },
];

const policyByExactOperatorName = new Map(
  passengerCarAccessPolicies.map((policy) => [policy.operatorName, policy]),
);

export function passengerCarAccessDecision(
  location: NormalizedChargingLocation,
): PassengerCarAccessDecision {
  const policy = policyByExactOperatorName.get(location.operatorName);
  return policy === undefined
    ? { status: "unknown" }
    : { status: policy.access, policy };
}

export function passengerCarSearchLocations(
  locations: readonly NormalizedChargingLocation[],
): readonly NormalizedChargingLocation[] {
  return locations.filter(
    (location) => passengerCarAccessDecision(location).status !== "forbidden",
  );
}
