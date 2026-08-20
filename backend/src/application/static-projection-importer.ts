import { createHash, randomUUID } from "node:crypto";

import type { Pool } from "pg";

import {
  buildChargingCampusProjection,
  buildChargingParkProjection,
  findEVSEIdentityConflicts,
} from "../domain/charging-park-projection.js";
import type {
  NormalizedChargingLocation,
  NormalizedLocationObservation,
  QuarantinedProviderRecord,
} from "../domain/normalized-charging.js";
import {
  ProjectionWriter,
  type ProjectionCounts,
  type QuarantineInput,
} from "../persistence/projection-writer.js";

const writeBatchSize = 250;
const projectionPolicyVersion = "conditional-charging-campus-v1";

export type StaticProviderRecordResult =
  | Readonly<{ kind: "observation"; observation: NormalizedLocationObservation }>
  | Readonly<{
      kind: "quarantine";
      quarantine: QuarantinedProviderRecord;
      rawPayload: Readonly<Record<string, unknown>>;
    }>;

export interface StaticProviderDataset {
  readonly providerId: string;
  readonly datasetHash: string;
  readonly observedAt: string;
  readonly records:
    | Iterable<StaticProviderRecordResult>
    | AsyncIterable<StaticProviderRecordResult>;
}

export type StaticProjectionImportResult =
  | Readonly<{ kind: "unchanged"; projectionId: string }>
  | Readonly<{ kind: "published"; projectionId: string; counts: ProjectionCounts }>;

export async function importStaticProjection(
  pool: Pool,
  datasets: readonly StaticProviderDataset[],
  unavailableSources: readonly string[],
  now: () => Date = () => new Date(),
): Promise<StaticProjectionImportResult> {
  validateDatasets(datasets);
  const activeSources = datasets.map(({ providerId }) => providerId).toSorted();
  const sortedUnavailableSources = [...new Set(unavailableSources)].toSorted();
  const sourceDatasetHash = combinedDatasetHash(datasets, sortedUnavailableSources);
  const writer = new ProjectionWriter(pool);
  const activeProjectionId = await writer.activeProjectionIdForHash(sourceDatasetHash);
  if (activeProjectionId !== undefined) {
    return { kind: "unchanged", projectionId: activeProjectionId };
  }

  const projectionId = randomUUID();
  const builtAt = now().toISOString();
  await writer.create({
    id: projectionId,
    sourceDatasetHash,
    sourceObservedAt: datasets.map(({ observedAt }) => observedAt).toSorted().at(-1) as string,
    builtAt,
    coverageStatus: sortedUnavailableSources.length === 0 ? "complete" : "degraded",
    activeSources,
    unavailableSources: sortedUnavailableSources,
  });
  try {
    const locations: NormalizedChargingLocation[] = [];
    const observations: NormalizedLocationObservation[] = [];
    const quarantines: QuarantineInput[] = [];
    let chargingPointCount = 0;
    let quarantineCount = 0;

    for (const dataset of datasets) {
      for await (const result of dataset.records) {
        if (result.kind === "observation") {
          observations.push(result.observation);
          locations.push(result.observation.location);
          chargingPointCount += result.observation.location.chargingPoints.length;
          if (observations.length >= writeBatchSize) {
            await writer.writeObservations(projectionId, observations.splice(0));
          }
        } else {
          quarantineCount += 1;
          quarantines.push({
            providerId: dataset.providerId,
            summary: result.quarantine,
            rawPayload: result.rawPayload,
          });
          if (quarantines.length >= writeBatchSize) {
            await writer.writeQuarantines(projectionId, quarantines.splice(0));
          }
        }
      }
    }
    await writer.writeObservations(projectionId, observations);
    await writer.writeQuarantines(projectionId, quarantines);

    const parks = buildChargingParkProjection(locations);
    const campuses = buildChargingCampusProjection(locations, parks);
    const conflicts = findEVSEIdentityConflicts(locations);
    for (let offset = 0; offset < parks.length; offset += writeBatchSize) {
      await writer.writeParks(projectionId, parks.slice(offset, offset + writeBatchSize));
    }
    for (let offset = 0; offset < campuses.length; offset += writeBatchSize) {
      await writer.writeCampuses(
        projectionId,
        campuses.slice(offset, offset + writeBatchSize),
      );
    }
    for (let offset = 0; offset < conflicts.length; offset += writeBatchSize) {
      await writer.writeConflicts(
        projectionId,
        conflicts.slice(offset, offset + writeBatchSize),
      );
    }
    const counts: ProjectionCounts = {
      locationCount: locations.length,
      chargingPointCount,
      parkCount: parks.length,
      campusCount: campuses.length,
      quarantineCount,
      conflictCount: conflicts.length,
    };
    await writer.publish(projectionId, counts, now().toISOString());
    return { kind: "published", projectionId, counts };
  } catch (error) {
    await writer.fail(projectionId, failureCode(error));
    throw error;
  }
}

function combinedDatasetHash(
  datasets: readonly StaticProviderDataset[],
  unavailableSources: readonly string[],
): string {
  return createHash("sha256")
    .update(
      JSON.stringify({
        projectionPolicyVersion,
        datasets: datasets
          .map(({ providerId, datasetHash }) => ({ providerId, datasetHash }))
          .toSorted((first, second) => first.providerId.localeCompare(second.providerId)),
        unavailableSources,
      }),
    )
    .digest("hex");
}

function validateDatasets(datasets: readonly StaticProviderDataset[]): void {
  if (datasets.length === 0) {
    throw new Error("At least one static provider dataset is required.");
  }
  const providerIds = new Set<string>();
  for (const dataset of datasets) {
    if (dataset.providerId.length === 0 || providerIds.has(dataset.providerId)) {
      throw new Error("Static provider IDs must be non-empty and unique.");
    }
    providerIds.add(dataset.providerId);
    if (!/^[0-9a-f]{64}$/u.test(dataset.datasetHash)) {
      throw new Error(`Static provider ${dataset.providerId} has an invalid dataset hash.`);
    }
    if (!Number.isFinite(Date.parse(dataset.observedAt))) {
      throw new Error(`Static provider ${dataset.providerId} has an invalid observation time.`);
    }
  }
}

function failureCode(error: unknown): string {
  return error instanceof Error ? error.name.slice(0, 100) : "UnknownImportFailure";
}
