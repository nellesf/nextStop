import { createHash } from "node:crypto";

import {
  normalizeOICPEVSEIdentity,
  normalizeProviderEVSEKey,
} from "../../domain/evse-identity.js";
import type {
  NormalizedChargingConnector,
  NormalizedChargingLocation,
  NormalizedLocationObservation,
  QuarantinedProviderRecord,
  SourceReference,
} from "../../domain/normalized-charging.js";
import { stableId } from "../../domain/stable-id.js";
import { ichTankeStromDescriptor } from "./descriptor.js";

const maximumOperatorBatches = 1_000;
const maximumRecords = 100_000;

export type IchTankeStromStaticRecordResult =
  | Readonly<{ kind: "observation"; observation: NormalizedLocationObservation }>
  | Readonly<{
      kind: "quarantine";
      quarantine: QuarantinedProviderRecord;
      rawPayload: Readonly<Record<string, unknown>>;
    }>;

export function readIchTankeStromStaticFeed(
  payload: unknown,
  observedAt: string,
  fetchedAt: string,
): readonly IchTankeStromStaticRecordResult[] {
  validateInstant(observedAt, "observedAt");
  validateInstant(fetchedAt, "fetchedAt");
  const root = requireRecord(payload, "ich-tanke-strom static root");
  const batches = requireArray(root.EVSEData, "EVSEData");
  if (batches.length > maximumOperatorBatches) {
    throw new Error("ich-tanke-strom static feed contains too many operator batches.");
  }

  const results: IchTankeStromStaticRecordResult[] = [];
  const seenSourceRecords = new Set<string>();
  let rowNumber = 0;
  for (const batchValue of batches) {
    const batch = requireRecord(batchValue, "EVSEData batch");
    const operatorName = stringValue(batch.OperatorName)?.trim() ?? "";
    const records = requireArray(batch.EVSEDataRecord, "EVSEDataRecord");
    for (const recordValue of records) {
      rowNumber += 1;
      if (rowNumber > maximumRecords) {
        throw new Error("ich-tanke-strom static feed contains too many EVSE records.");
      }
      const record = requireRecord(recordValue, "EVSEDataRecord item");
      const sourceRecordId = stringValue(record.EvseID)?.trim() ?? "";
      const issues: string[] = [];
      if (sourceRecordId.length === 0) {
        issues.push("missing_evse_id");
      } else if (seenSourceRecords.has(sourceRecordId)) {
        issues.push("duplicate_evse_id");
      }
      if (operatorName.length === 0) {
        issues.push("missing_operator");
      }
      const providerEVSEKey = normalizeProviderEVSEKey(sourceRecordId);
      if (providerEVSEKey === undefined) {
        issues.push("invalid_provider_evse_key");
      }
      const coordinate = parseCoordinate(record.GeoCoordinates);
      if (coordinate === undefined) {
        issues.push("implausible_swiss_coordinate");
      }
      const maximumPowerKW = parseMaximumPower(record.ChargingFacilities);
      if (maximumPowerKW === undefined) {
        issues.push("missing_positive_power");
      }
      const plugs = parsePlugs(record.Plugs);
      if (plugs.length === 0) {
        issues.push("missing_plug");
      }
      if (issues.length > 0) {
        results.push({
          kind: "quarantine",
          quarantine: {
            rowNumber,
            ...(sourceRecordId.length === 0 ? {} : { sourceRecordId }),
            issueCodes: issues,
          },
          rawPayload: record,
        });
        continue;
      }
      seenSourceRecords.add(sourceRecordId);
      const sourceReference: SourceReference = {
        providerId: ichTankeStromDescriptor.id,
        sourceRecordId,
        qualityTier: ichTankeStromDescriptor.qualityTier,
        observedAt,
        fetchedAt,
        contentHash: createHash("sha256")
          .update(JSON.stringify(record))
          .digest("hex"),
      };
      const connectors: readonly NormalizedChargingConnector[] = plugs.map(
        (sourceValue) => ({ sourceValue }),
      );
      const location: NormalizedChargingLocation = {
        id: stableId("charging-location", [ichTankeStromDescriptor.id, sourceRecordId]),
        name: parseName(record.ChargingStationNames, operatorName),
        operatorName,
        coordinate: coordinate as Readonly<{ latitude: number; longitude: number }>,
        address: parseAddress(record.Address),
        chargingPoints: [
          {
            id: stableId("charging-point", [ichTankeStromDescriptor.id, sourceRecordId]),
            nativeIdentity: sourceRecordId,
            providerEVSEKey: providerEVSEKey as string,
            ...optionalCanonicalIdentity(sourceRecordId),
            identityDecision:
              normalizeOICPEVSEIdentity(sourceRecordId) === undefined
                ? "unresolved"
                : "exact",
            connectors,
            maximumPowerKW: maximumPowerKW as number,
            availability: { state: "unknown", isLive: false },
            sourceReference,
          },
        ],
        active: true,
        sourceReference,
      };
      results.push({ kind: "observation", observation: { location, rawPayload: record } });
    }
  }
  if (rowNumber === 0) {
    throw new Error("ich-tanke-strom static feed contains no EVSE records.");
  }
  return results;
}

function parseCoordinate(
  value: unknown,
): Readonly<{ latitude: number; longitude: number }> | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const google = stringValue(value.Google)?.trim();
  if (google === undefined) {
    return undefined;
  }
  const match = /^(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)$/u.exec(google);
  if (match === null) {
    return undefined;
  }
  const latitude = Number(match[1]);
  const longitude = Number(match[2]);
  return latitude >= 45 && latitude <= 48.5 && longitude >= 5 && longitude <= 11.5
    ? { latitude, longitude }
    : undefined;
}

function parseMaximumPower(value: unknown): number | undefined {
  if (!Array.isArray(value)) {
    return undefined;
  }
  const powers = value.flatMap((facility) => {
    if (!isRecord(facility)) {
      return [];
    }
    const raw = facility.power;
    const parsed = typeof raw === "number" ? raw : Number(stringValue(raw));
    return Number.isFinite(parsed) && parsed > 0 ? [parsed] : [];
  });
  const maximum = Math.max(...powers);
  return Number.isFinite(maximum) ? Math.max(1, Math.floor(maximum)) : undefined;
}

function parsePlugs(value: unknown): readonly string[] {
  return Array.isArray(value)
    ? [...new Set(value.flatMap((plug) => {
        const parsed = stringValue(plug)?.trim();
        return parsed === undefined || parsed.length === 0 ? [] : [parsed];
      }))].toSorted()
    : [];
}

function parseName(value: unknown, fallback: string): string {
  if (!Array.isArray(value)) {
    return fallback;
  }
  const names = value.flatMap((item) => {
    if (!isRecord(item)) {
      return [];
    }
    const language = stringValue(item.lang)?.toLowerCase();
    const name = stringValue(item.value)?.trim();
    return name === undefined || name.length === 0 ? [] : [{ language, name }];
  });
  return (
    names.find(({ language }) => language === "de")?.name ??
    names.find(({ language }) => language === "en")?.name ??
    names[0]?.name ??
    fallback
  );
}

function parseAddress(value: unknown): NormalizedChargingLocation["address"] {
  if (!isRecord(value)) {
    return {};
  }
  const entries = {
    street: stringValue(value.Street)?.trim(),
    postalCode: stringValue(value.PostalCode)?.trim(),
    city: stringValue(value.City)?.trim(),
    state: stringValue(value.Region)?.trim(),
  };
  return Object.fromEntries(
    Object.entries(entries).filter((entry): entry is [string, string] => {
      const current = entry[1];
      return current !== undefined && current.length > 0;
    }),
  );
}

function optionalCanonicalIdentity(value: string) {
  const canonicalEVSEIdentity = normalizeOICPEVSEIdentity(value);
  return canonicalEVSEIdentity === undefined ? {} : { canonicalEVSEIdentity };
}

function requireRecord(value: unknown, label: string): Readonly<Record<string, unknown>> {
  if (!isRecord(value)) {
    throw new Error(`${label} must be an object.`);
  }
  return value;
}

function requireArray(value: unknown, label: string): readonly unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${label} must be an array.`);
  }
  return value;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function validateInstant(value: string, field: string): void {
  if (!Number.isFinite(Date.parse(value))) {
    throw new Error(`${field} must be an ISO-8601 instant.`);
  }
}
