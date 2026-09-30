import type { Pool } from "pg";

import {
  refreshStaticProviders,
  refreshSwissLiveAvailability,
} from "./refresh-providers.js";
import { refreshFoodPOIs } from "./refresh-food-pois.js";
import { pruneRetiredChargingSearchProjections } from "../persistence/projection-retention.js";

const staticSuccessIntervalMilliseconds = 24 * 60 * 60 * 1_000;
const staticRetryIntervalMilliseconds = 15 * 60 * 1_000;
const liveSuccessIntervalMilliseconds = 60 * 1_000;
const liveRetryIntervalMilliseconds = 30 * 1_000;
const foodSuccessIntervalMilliseconds = 24 * 60 * 60 * 1_000;
const foodRetryIntervalMilliseconds = 30 * 60 * 1_000;
const retentionIntervalMilliseconds = 2 * 60 * 1_000;

export interface IngestionLogger {
  info(details: Readonly<Record<string, unknown>>, message: string): void;
  warn(details: Readonly<Record<string, unknown>>, message: string): void;
}

export class ProviderIngestionCoordinator {
  private stopped = true;
  private staticTimer: NodeJS.Timeout | undefined;
  private liveTimer: NodeJS.Timeout | undefined;
  private foodTimer: NodeJS.Timeout | undefined;
  private retentionTimer: NodeJS.Timeout | undefined;

  constructor(
    private readonly pool: Pool,
    private readonly logger: IngestionLogger,
    private readonly foodPOIIngestionEnabled = true,
  ) {}

  start(): void {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    this.staticTimer = setTimeout(() => void this.refreshStatic(), 0);
    this.liveTimer = setTimeout(() => void this.refreshLive(), 0);
    if (this.foodPOIIngestionEnabled) {
      this.foodTimer = setTimeout(() => void this.refreshFood(), 0);
    }
    this.retentionTimer = setTimeout(() => void this.pruneSearchHistory(), retentionIntervalMilliseconds);
  }

  stop(): void {
    this.stopped = true;
    if (this.staticTimer !== undefined) {
      clearTimeout(this.staticTimer);
    }
    if (this.liveTimer !== undefined) {
      clearTimeout(this.liveTimer);
    }
    if (this.foodTimer !== undefined) {
      clearTimeout(this.foodTimer);
    }
    if (this.retentionTimer !== undefined) {
      clearTimeout(this.retentionTimer);
    }
  }

  private async refreshStatic(): Promise<void> {
    let nextDelay = staticSuccessIntervalMilliseconds;
    try {
      const result = await refreshStaticProviders(this.pool, {
        onProgress: (progress) => this.logger.info(
          { event: "static-projection-stage", ...progress },
          "Static charging projection build progress.",
        ),
      });
      this.logger.info(
        { event: "static-provider-refresh", result: result.kind },
        "Static charging providers refreshed.",
      );
    } catch (error) {
      nextDelay = staticRetryIntervalMilliseconds;
      this.logger.warn(
        { event: "static-provider-refresh-failed", failure: failureCode(error) },
        "Static charging provider refresh failed; the active projection was retained.",
      );
    }
    if (!this.stopped) {
      this.staticTimer = setTimeout(() => void this.refreshStatic(), nextDelay);
    }
  }

  private async refreshLive(): Promise<void> {
    let nextDelay = liveSuccessIntervalMilliseconds;
    try {
      const result = await refreshSwissLiveAvailability(this.pool);
      this.logger.info(
        { event: "live-provider-refresh", result: result.kind },
        "Live charging availability refreshed.",
      );
    } catch (error) {
      nextDelay = liveRetryIntervalMilliseconds;
      this.logger.warn(
        { event: "live-provider-refresh-failed", failure: failureCode(error) },
        "Live charging availability refresh failed; availability will age to unknown.",
      );
    }
    if (!this.stopped) {
      this.liveTimer = setTimeout(() => void this.refreshLive(), nextDelay);
    }
  }

  private async refreshFood(): Promise<void> {
    let nextDelay = foodSuccessIntervalMilliseconds;
    try {
      const result = await refreshFoodPOIs(this.pool);
      this.logger.info(
        { event: "osm-food-poi-refresh", result: result.kind },
        "OpenStreetMap food POIs refreshed.",
      );
    } catch (error) {
      nextDelay = foodRetryIntervalMilliseconds;
      this.logger.warn(
        { event: "osm-food-poi-refresh-failed", failure: failureCode(error) },
        "OpenStreetMap food POI refresh failed; the active projection was retained.",
      );
    }
    if (!this.stopped) {
      this.foodTimer = setTimeout(() => void this.refreshFood(), nextDelay);
    }
  }

  private async pruneSearchHistory(): Promise<void> {
    try {
      const result = await pruneRetiredChargingSearchProjections(this.pool);
      if (result.deletedRows > 0 || result.completedVersions > 0) {
        this.logger.info({ event: "search-projection-retention", ...result }, "Old derived search rows pruned in bounded batches.");
      }
    } catch (error) {
      this.logger.warn({ event: "search-projection-retention-failed", failure: failureCode(error) }, "Search projection retention will retry on its next bounded run.");
    }
    if (!this.stopped) {
      this.retentionTimer = setTimeout(() => void this.pruneSearchHistory(), retentionIntervalMilliseconds);
    }
  }
}

function failureCode(error: unknown): string {
  return error instanceof Error ? error.name : "UnknownRefreshFailure";
}
