import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import {
  importStaticProjection,
  type StaticProjectionImportResult,
  type StaticProviderDataset,
} from "../application/static-projection-importer.js";
import { AvailabilitySnapshotWriter } from "../persistence/availability-snapshot-writer.js";
import { createDatabasePool } from "../persistence/database.js";
import { readBundesnetzagenturCSV } from "../providers/bundesnetzagentur/csv-provider.js";
import {
  downloadLatestBundesnetzagenturDataset,
  type BundesnetzagenturDatasetArtifact,
} from "../providers/bundesnetzagentur/dataset-downloader.js";
import { bundesnetzagenturDescriptor } from "../providers/bundesnetzagentur/descriptor.js";
import { ichTankeStromDescriptor } from "../providers/ich-tanke-strom/descriptor.js";
import {
  downloadIchTankeStromFeed,
  type IchTankeStromFeed,
} from "../providers/ich-tanke-strom/feed-client.js";
import { readIchTankeStromLiveFeed } from "../providers/ich-tanke-strom/live-provider.js";
import { readIchTankeStromStaticFeed } from "../providers/ich-tanke-strom/static-provider.js";
import { ProjectionWriter } from "../persistence/projection-writer.js";

const writeBatchSize = 1_000;

export type StaticRefreshResult =
  | StaticProjectionImportResult
  | Readonly<{
      kind: "retained";
      projectionId: string;
      unavailableSources: readonly string[];
    }>;

export type LiveRefreshResult =
  | Readonly<{ kind: "unchanged"; snapshotId: string }>
  | Readonly<{
      kind: "published";
      snapshotId: string;
      recordCount: number;
      quarantineCount: number;
    }>;

export interface ProviderRefreshDependencies {
  readonly downloadBundesnetzagentur?: () => Promise<BundesnetzagenturDatasetArtifact>;
  readonly downloadSwissFeed?: (kind: "static" | "live") => Promise<IchTankeStromFeed>;
  readonly now?: () => Date;
}

export async function refreshStaticProviders(
  pool: Pool,
  dependencies: ProviderRefreshDependencies = {},
): Promise<StaticRefreshResult> {
  const now = dependencies.now ?? (() => new Date());
  const downloadBundesnetzagentur =
    dependencies.downloadBundesnetzagentur ?? downloadLatestBundesnetzagenturDataset;
  const downloadSwissFeed = dependencies.downloadSwissFeed ?? downloadIchTankeStromFeed;
  let bundesnetzagentur: BundesnetzagenturDatasetArtifact | undefined;
  let swiss: IchTankeStromFeed | undefined;
  const unavailableSources: string[] = [];

  try {
    try {
      bundesnetzagentur = await downloadBundesnetzagentur();
    } catch {
      unavailableSources.push(bundesnetzagenturDescriptor.id);
    }
    try {
      swiss = await downloadSwissFeed("static");
    } catch {
      unavailableSources.push(ichTankeStromDescriptor.id);
    }

    const projectionWriter = new ProjectionWriter(pool);
    if (unavailableSources.length > 0) {
      const activeProjectionId = await projectionWriter.activeProjectionId();
      if (activeProjectionId !== undefined) {
        return {
          kind: "retained",
          projectionId: activeProjectionId,
          unavailableSources: unavailableSources.toSorted(),
        };
      }
    }

    const datasets: StaticProviderDataset[] = [];
    if (bundesnetzagentur !== undefined) {
      datasets.push({
        providerId: bundesnetzagenturDescriptor.id,
        datasetHash: bundesnetzagentur.sha256,
        observedAt: bundesnetzagentur.observedAt,
        records: readBundesnetzagenturCSV({
          filePath: bundesnetzagentur.filePath,
          observedAt: bundesnetzagentur.observedAt,
          fetchedAt: bundesnetzagentur.fetchedAt,
        }),
      });
    }
    if (swiss !== undefined) {
      datasets.push({
        providerId: ichTankeStromDescriptor.id,
        datasetHash: swiss.sha256,
        observedAt: swiss.observedAt,
        records: readIchTankeStromStaticFeed(
          swiss.payload,
          swiss.observedAt,
          swiss.fetchedAt,
        ),
      });
    }
    if (datasets.length === 0) {
      throw new Error("No static charging provider could be refreshed.");
    }
    return await importStaticProjection(pool, datasets, unavailableSources, now);
  } finally {
    await bundesnetzagentur?.cleanup();
  }
}

export async function refreshSwissLiveAvailability(
  pool: Pool,
  dependencies: ProviderRefreshDependencies = {},
): Promise<LiveRefreshResult> {
  const now = dependencies.now ?? (() => new Date());
  const feed = await (dependencies.downloadSwissFeed ?? downloadIchTankeStromFeed)("live");
  if (
    now().getTime() - Date.parse(feed.observedAt) >
    ichTankeStromDescriptor.maximumLiveAgeSeconds * 1_000
  ) {
    throw new Error("ich-tanke-strom live feed is stale.");
  }
  const writer = new AvailabilitySnapshotWriter(pool);
  const activeSnapshotId = await writer.activeSnapshotIdForHash(
    ichTankeStromDescriptor.id,
    feed.sha256,
  );
  if (activeSnapshotId !== undefined) {
    return { kind: "unchanged", snapshotId: activeSnapshotId };
  }
  const parsed = readIchTankeStromLiveFeed(
    feed.payload,
    feed.observedAt,
    feed.fetchedAt,
  );
  const snapshotId = randomUUID();
  await writer.create({
    id: snapshotId,
    providerId: ichTankeStromDescriptor.id,
    sourceHash: feed.sha256,
    observedAt: feed.observedAt,
    fetchedAt: feed.fetchedAt,
  });
  try {
    for (let offset = 0; offset < parsed.observations.length; offset += writeBatchSize) {
      await writer.write(
        snapshotId,
        parsed.observations.slice(offset, offset + writeBatchSize),
      );
    }
    await writer.publish(
      snapshotId,
      parsed.observations.length,
      parsed.quarantines.length,
      now().toISOString(),
    );
    await writer.pruneBefore(
      new Date(
        now().getTime() -
          ichTankeStromDescriptor.liveSnapshotRetentionHours * 60 * 60 * 1_000,
      ).toISOString(),
    );
    return {
      kind: "published",
      snapshotId,
      recordCount: parsed.observations.length,
      quarantineCount: parsed.quarantines.length,
    };
  } catch (error) {
    await writer.fail(snapshotId, failureCode(error));
    throw error;
  }
}

async function main(): Promise<void> {
  const connectionString = process.env.DATABASE_URL;
  if (connectionString === undefined) {
    throw new Error("DATABASE_URL is required.");
  }
  const pool = createDatabasePool(connectionString);
  try {
    const staticResult = await refreshStaticProviders(pool);
    const liveResult = await refreshSwissLiveAvailability(pool);
    process.stdout.write(`${JSON.stringify({ static: staticResult, live: liveResult })}\n`);
  } finally {
    await pool.end();
  }
}

function failureCode(error: unknown): string {
  return error instanceof Error ? error.name.slice(0, 100) : "UnknownImportFailure";
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
