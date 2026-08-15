import { createHash } from "node:crypto";

import { normalizeProviderEVSEKey } from "../../domain/evse-identity.js";
import type {
  AvailabilityState,
  QuarantinedProviderRecord,
  SourceReference,
} from "../../domain/normalized-charging.js";
import { ichTankeStromDescriptor } from "./descriptor.js";

const maximumOperatorBatches = 1_000;
const maximumRecords = 100_000;

export interface NormalizedAvailabilityObservation {
  readonly providerEVSEKey: string;
  readonly nativeIdentity: string;
  readonly state: AvailabilityState;
  readonly observedAt: string;
  readonly sourceReference: SourceReference;
}

export interface IchTankeStromLiveFeedResult {
  readonly observations: readonly NormalizedAvailabilityObservation[];
  readonly quarantines: readonly Readonly<{
    summary: QuarantinedProviderRecord;
    rawPayload: Readonly<Record<string, unknown>>;
  }>[];
}

export function readIchTankeStromLiveFeed(
  payload: unknown,
  observedAt: string,
  fetchedAt: string,
): IchTankeStromLiveFeedResult {
  validateInstant(observedAt, "observedAt");
  validateInstant(fetchedAt, "fetchedAt");
  const root = requireRecord(payload, "ich-tanke-strom live root");
  const batches = requireArray(root.EVSEStatuses, "EVSEStatuses");
  if (batches.length > maximumOperatorBatches) {
    throw new Error("ich-tanke-strom live feed contains too many operator batches.");
  }

  const byEVSEKey = new Map<string, NormalizedAvailabilityObservation>();
  const quarantines: {
    summary: QuarantinedProviderRecord;
    rawPayload: Readonly<Record<string, unknown>>;
  }[] = [];
  let rowNumber = 0;
  for (const batchValue of batches) {
    const batch = requireRecord(batchValue, "EVSEStatuses batch");
    const records = requireArray(batch.EVSEStatusRecord, "EVSEStatusRecord");
    for (const recordValue of records) {
      rowNumber += 1;
      if (rowNumber > maximumRecords) {
        throw new Error("ich-tanke-strom live feed contains too many status records.");
      }
      const record = requireRecord(recordValue, "EVSEStatusRecord item");
      const nativeIdentity = stringValue(record.EvseID)?.trim() ?? "";
      const providerEVSEKey = normalizeProviderEVSEKey(nativeIdentity);
      const state = mapState(record.EVSEStatus);
      const issues: string[] = [];
      if (nativeIdentity.length === 0) {
        issues.push("missing_evse_id");
      }
      if (providerEVSEKey === undefined) {
        issues.push("invalid_provider_evse_key");
      }
      if (state === undefined) {
        issues.push("unknown_availability_state");
      }
      if (issues.length > 0) {
        quarantines.push({
          summary: {
            rowNumber,
            ...(nativeIdentity.length === 0 ? {} : { sourceRecordId: nativeIdentity }),
            issueCodes: issues,
          },
          rawPayload: record,
        });
        continue;
      }
      const sourceReference: SourceReference = {
        providerId: ichTankeStromDescriptor.id,
        sourceRecordId: nativeIdentity,
        qualityTier: ichTankeStromDescriptor.qualityTier,
        observedAt,
        fetchedAt,
        contentHash: createHash("sha256")
          .update(JSON.stringify(record))
          .digest("hex"),
      };
      const observation: NormalizedAvailabilityObservation = {
        providerEVSEKey: providerEVSEKey as string,
        nativeIdentity,
        state: state as AvailabilityState,
        observedAt,
        sourceReference,
      };
      const existing = byEVSEKey.get(observation.providerEVSEKey);
      if (existing === undefined) {
        byEVSEKey.set(observation.providerEVSEKey, observation);
      } else {
        quarantines.push({
          summary: {
            rowNumber,
            sourceRecordId: nativeIdentity,
            issueCodes: ["duplicate_evse_id"],
          },
          rawPayload: record,
        });
        if (existing.state !== observation.state) {
          byEVSEKey.set(observation.providerEVSEKey, {
            ...existing,
            state: "unknown",
            sourceReference: {
              ...existing.sourceReference,
              contentHash: createHash("sha256")
                .update(
                  [existing.sourceReference.contentHash, observation.sourceReference.contentHash]
                    .toSorted()
                    .join(":"),
                )
                .digest("hex"),
            },
          });
        }
      }
    }
  }
  if (rowNumber === 0) {
    throw new Error("ich-tanke-strom live feed contains no status records.");
  }
  return {
    observations: [...byEVSEKey.values()].toSorted((first, second) =>
      first.providerEVSEKey.localeCompare(second.providerEVSEKey),
    ),
    quarantines,
  };
}

function mapState(value: unknown): AvailabilityState | undefined {
  switch (value) {
    case "Available":
      return "available";
    case "Occupied":
      return "occupied";
    case "OutOfService":
      return "out_of_service";
    case "Reserved":
      return "reserved";
    case "Unknown":
    case "EvseNotFound":
      return "unknown";
    default:
      return undefined;
  }
}

function requireRecord(value: unknown, label: string): Readonly<Record<string, unknown>> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object.`);
  }
  return value as Readonly<Record<string, unknown>>;
}

function requireArray(value: unknown, label: string): readonly unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${label} must be an array.`);
  }
  return value;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function validateInstant(value: string, field: string): void {
  if (!Number.isFinite(Date.parse(value))) {
    throw new Error(`${field} must be an ISO-8601 instant.`);
  }
}
