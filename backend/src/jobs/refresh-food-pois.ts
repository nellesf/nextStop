import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { createDatabasePool } from "../persistence/database.js";
import { FoodPOIProjectionWriter } from "../persistence/food-poi-projection-writer.js";
import {
  downloadConfiguredGeofabrikDatasets,
  type GeofabrikDatasetArtifact,
} from "../providers/openstreetmap/geofabrik-downloader.js";
import { readOpenStreetMapFoodPOIs } from "../providers/openstreetmap/pbf-provider.js";

const writeBatchSize = 1_000;

export type FoodPOIRefreshResult =
  | Readonly<{ kind: "unchanged"; projectionId: string }>
  | Readonly<{
      kind: "published";
      projectionId: string;
      poiCount: number;
      quarantineCount: number;
    }>;

export interface FoodPOIRefreshDependencies {
  readonly downloadDatasets?: () => Promise<readonly GeofabrikDatasetArtifact[]>;
  readonly now?: () => Date;
}

export async function refreshFoodPOIs(
  pool: Pool,
  dependencies: FoodPOIRefreshDependencies = {},
): Promise<FoodPOIRefreshResult> {
  const now = dependencies.now ?? (() => new Date());
  const artifacts = await (
    dependencies.downloadDatasets ?? downloadConfiguredGeofabrikDatasets
  )();
  try {
    const sourceDatasetHash = createHash("sha256")
      .update(
        artifacts
          .map(({ sourceURL, sha256 }) => `${sourceURL}\0${sha256}`)
          .toSorted()
          .join("\n"),
      )
      .digest("hex");
    const writer = new FoodPOIProjectionWriter(pool);
    const active = await writer.activeProjectionIdForHash(sourceDatasetHash);
    if (active !== undefined) {
      return { kind: "unchanged", projectionId: active };
    }

    const parsed = await readOpenStreetMapFoodPOIs(artifacts);
    const projectionId = randomUUID();
    await writer.create({
      id: projectionId,
      sourceDatasetHash,
      sourceObservedAt: minimumInstant(artifacts.map(({ observedAt }) => observedAt)),
      fetchedAt: maximumInstant(artifacts.map(({ fetchedAt }) => fetchedAt)),
      builtAt: now().toISOString(),
      sourceURLs: artifacts.map(({ sourceURL }) => sourceURL).toSorted(),
    });
    try {
      for (let offset = 0; offset < parsed.records.length; offset += writeBatchSize) {
        await writer.writeRecords(
          projectionId,
          parsed.records.slice(offset, offset + writeBatchSize),
        );
      }
      for (let offset = 0; offset < parsed.quarantines.length; offset += writeBatchSize) {
        await writer.writeQuarantines(
          projectionId,
          parsed.quarantines.slice(offset, offset + writeBatchSize),
        );
      }
      await writer.publish(
        projectionId,
        parsed.records.length,
        parsed.quarantines.length,
        now().toISOString(),
      );
      return {
        kind: "published",
        projectionId,
        poiCount: parsed.records.length,
        quarantineCount: parsed.quarantines.length,
      };
    } catch (error) {
      await writer.fail(projectionId, failureCode(error));
      throw error;
    }
  } finally {
    await Promise.all(artifacts.map((artifact) => artifact.cleanup()));
  }
}

function minimumInstant(values: readonly string[]): string {
  const value = values.toSorted().at(0);
  if (value === undefined) throw new Error("No OSM dataset was downloaded.");
  return value;
}

function maximumInstant(values: readonly string[]): string {
  const value = values.toSorted().at(-1);
  if (value === undefined) throw new Error("No OSM dataset was downloaded.");
  return value;
}

function failureCode(error: unknown): string {
  return error instanceof Error ? error.name.slice(0, 100) : "UnknownOSMImportFailure";
}

async function main(): Promise<void> {
  const connectionString = process.env.DATABASE_URL;
  if (connectionString === undefined) throw new Error("DATABASE_URL is required.");
  const pool = createDatabasePool(connectionString);
  try {
    process.stdout.write(`${JSON.stringify(await refreshFoodPOIs(pool))}\n`);
  } finally {
    await pool.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
