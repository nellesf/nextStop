import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  buildChargingParkProjection,
  findEVSEIdentityConflicts,
} from "../domain/charging-park-projection.js";
import type {
  NormalizedChargingLocation,
  NormalizedLocationObservation,
} from "../domain/normalized-charging.js";
import { createDatabasePool } from "../persistence/database.js";
import {
  ProjectionWriter,
  type ProjectionCounts,
  type QuarantineInput,
} from "../persistence/projection-writer.js";
import { readBundesnetzagenturCSV } from "../providers/bundesnetzagentur/csv-provider.js";
import { bundesnetzagenturDescriptor } from "../providers/bundesnetzagentur/descriptor.js";

const writeBatchSize = 250;

async function main(): Promise<void> {
  const connectionString = requiredEnvironment("DATABASE_URL");
  const filePath = requiredEnvironment("BUNDESNETZAGENTUR_CSV_PATH");
  const observedAt = requiredInstant("BUNDESNETZAGENTUR_DATASET_OBSERVED_AT");
  const expectedHash = requiredHash("BUNDESNETZAGENTUR_EXPECTED_SHA256");
  const fetchedAt = new Date().toISOString();
  const actualHash = await hashFile(filePath);
  if (actualHash !== expectedHash) {
    throw new Error("Bundesnetzagentur dataset hash does not match the approved input.");
  }

  const pool = createDatabasePool(connectionString);
  const writer = new ProjectionWriter(pool);
  const projectionId = randomUUID();
  let projectionCreated = false;
  try {
    await writer.create({
      id: projectionId,
      sourceDatasetHash: actualHash,
      sourceObservedAt: observedAt,
      builtAt: fetchedAt,
      coverageStatus: "complete",
      activeSources: [bundesnetzagenturDescriptor.id],
      unavailableSources: [],
    });
    projectionCreated = true;

    const locations: NormalizedChargingLocation[] = [];
    const observations: NormalizedLocationObservation[] = [];
    const quarantines: QuarantineInput[] = [];
    let chargingPointCount = 0;
    let quarantineCount = 0;

    for await (const result of readBundesnetzagenturCSV({
      filePath,
      observedAt,
      fetchedAt,
    })) {
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
          providerId: bundesnetzagenturDescriptor.id,
          summary: result.quarantine,
          rawPayload: result.rawPayload,
        });
        if (quarantines.length >= writeBatchSize) {
          await writer.writeQuarantines(projectionId, quarantines.splice(0));
        }
      }
    }
    await writer.writeObservations(projectionId, observations);
    await writer.writeQuarantines(projectionId, quarantines);

    const parks = buildChargingParkProjection(locations);
    const conflicts = findEVSEIdentityConflicts(locations);
    for (let offset = 0; offset < parks.length; offset += writeBatchSize) {
      await writer.writeParks(projectionId, parks.slice(offset, offset + writeBatchSize));
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
      quarantineCount,
      conflictCount: conflicts.length,
    };
    await writer.publish(projectionId, counts, new Date().toISOString());
    process.stdout.write(`${JSON.stringify({ projectionId, ...counts })}\n`);
  } catch (error) {
    if (projectionCreated) {
      await writer.fail(projectionId, failureCode(error));
    }
    throw error;
  } finally {
    await pool.end();
  }
}

async function hashFile(filePath: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk as Buffer);
  }
  return hash.digest("hex");
}

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`${name} is required.`);
  }
  return value;
}

function requiredInstant(name: string): string {
  const value = requiredEnvironment(name);
  if (!Number.isFinite(Date.parse(value))) {
    throw new Error(`${name} must be an ISO-8601 instant.`);
  }
  return value;
}

function requiredHash(name: string): string {
  const value = requiredEnvironment(name);
  if (!/^[0-9a-f]{64}$/u.test(value)) {
    throw new Error(`${name} must be a lowercase SHA-256 digest.`);
  }
  return value;
}

function failureCode(error: unknown): string {
  if (error instanceof Error) {
    return error.name.slice(0, 100);
  }
  return "UnknownImportFailure";
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
