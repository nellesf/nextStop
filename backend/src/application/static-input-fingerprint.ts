import { createHash } from "node:crypto";

import type { SourceReference } from "../domain/normalized-charging.js";
import type { StaticProviderDataset, StaticProviderRecordResult } from "./static-projection-importer.js";

export interface ParsedStaticProviderDataset extends Omit<StaticProviderDataset, "records"> {
  readonly records: readonly StaticProviderRecordResult[];
}

// Compare validated records rather than file formatting or transport timestamps.
// The complete raw record stays in the comparison, including fields that current
// normalization does not yet use. Array order and duplicate records are retained.
export function staticInputFingerprint(
  datasets: readonly ParsedStaticProviderDataset[],
  unavailableSources: readonly string[],
  projectionPolicyVersion: string,
): string {
  const providerInputs = datasets.map(({ providerId, records }) => ({
    providerId,
    recordHashes: records.map(recordFingerprint).sort(),
  })).sort((first, second) => first.providerId.localeCompare(second.providerId));
  return fingerprint({
    fingerprintVersion: "static-input-v1",
    projectionPolicyVersion,
    providers: providerInputs,
    unavailableSources: [...new Set(unavailableSources)].sort(),
  });
}

function recordFingerprint(record: StaticProviderRecordResult): string {
  if (record.kind === "quarantine") {
    // A row number identifies a position in one source file, not record content.
    // Omitting it allows reordered files to retain the same quarantine multiset.
    const quarantine = Object.fromEntries(
      Object.entries(record.quarantine).filter(([key]) => key !== "rowNumber"),
    );
    return fingerprint({ ...record, quarantine });
  }
  const location = record.observation.location;
  return fingerprint({
    ...record,
    observation: {
      ...record.observation,
      location: {
        ...location,
        sourceReference: comparableSourceReference(location.sourceReference),
        chargingPoints: location.chargingPoints.map((point) => ({
          ...point,
          sourceReference: comparableSourceReference(point.sourceReference),
        })),
      },
    },
  });
}

function comparableSourceReference(reference: SourceReference) {
  return Object.fromEntries(Object.entries(reference).filter(([key]) =>
    key !== "observedAt" && key !== "fetchedAt" && key !== "contentHash",
  ));
}

function fingerprint(value: unknown): string {
  return createHash("sha256").update(canonicalJSON(value)).digest("hex");
}

function canonicalJSON(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (typeof value === "object" && value !== null && Object.getPrototypeOf(value) === Object.prototype) {
    return `{${Object.entries(value).sort(([first], [second]) => first < second ? -1 : first > second ? 1 : 0)
      .map(([key, child]) => `${JSON.stringify(key)}:${canonicalJSON(child)}`).join(",")}}`;
  }
  throw new Error("Static projection input contains a non-JSON value.");
}
