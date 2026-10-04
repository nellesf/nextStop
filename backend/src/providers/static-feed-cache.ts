import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { copyFile, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export interface StaticFeedCacheMetadata {
  readonly sourceURL: string;
  readonly sha256: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly etag?: string;
  readonly lastModified?: string;
}

// One replaceable slot per static provider bounds retention independently of how
// often the provider changes its URL. Returned artifacts are private temp copies.
export class StaticFeedCache {
  private readonly directory: string;

  constructor(
    provider: "bundesnetzagentur" | "ich-tanke-strom-static",
    cacheDirectory?: string,
  ) {
    this.directory = join(resolve(
      cacheDirectory ?? (process.env.PROVIDER_CACHE_DIRECTORY?.trim() ||
        join(tmpdir(), "nextstop-provider-cache")),
    ), provider);
  }

  async readInto(
    sourceURL: string,
    filePath: string,
    maximumBytes: number,
  ): Promise<StaticFeedCacheMetadata | undefined> {
    try {
      const metadataPath = join(this.directory, "metadata.json");
      if ((await stat(metadataPath)).size > 16_384) return undefined;
      const metadata: unknown = JSON.parse(await readFile(metadataPath, "utf8"));
      if (!isStaticFeedCacheMetadata(metadata) || metadata.sourceURL !== sourceURL) return undefined;
      const bodyPath = join(this.directory, "body");
      const size = (await stat(bodyPath)).size;
      if (size === 0 || size > maximumBytes) return undefined;
      await copyFile(bodyPath, filePath);
      const hash = createHash("sha256");
      let bytes = 0;
      for await (const value of createReadStream(filePath)) {
        const chunk = value as Buffer;
        bytes += chunk.length;
        if (bytes > maximumBytes) throw new Error("Cached static feed exceeds its limit.");
        hash.update(chunk);
      }
      if (bytes !== size || hash.digest("hex") !== metadata.sha256) {
        throw new Error("Cached static feed integrity mismatch.");
      }
      return metadata;
    } catch {
      await rm(filePath, { force: true });
      return undefined;
    }
  }

  async write(filePath: string, metadata: StaticFeedCacheMetadata): Promise<void> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const suffix = randomUUID();
    const bodyTemporaryPath = join(this.directory, `body-${suffix}.tmp`);
    const metadataTemporaryPath = join(this.directory, `metadata-${suffix}.tmp`);
    try {
      await copyFile(filePath, bodyTemporaryPath);
      await writeFile(metadataTemporaryPath, JSON.stringify(metadata), { mode: 0o600 });
      await rename(bodyTemporaryPath, join(this.directory, "body"));
      await rename(metadataTemporaryPath, join(this.directory, "metadata.json"));
    } finally {
      await rm(bodyTemporaryPath, { force: true });
      await rm(metadataTemporaryPath, { force: true });
    }
  }
}

export function conditionalHeaders(
  cached: StaticFeedCacheMetadata | undefined,
): Readonly<Record<string, string>> {
  return {
    ...(cached?.etag === undefined ? {} : { "if-none-match": cached.etag }),
    ...(cached?.lastModified === undefined ? {} : { "if-modified-since": cached.lastModified }),
  };
}

export function isStaticFeedCacheMetadata(value: unknown): value is StaticFeedCacheMetadata {
  if (typeof value !== "object" || value === null) return false;
  return "sourceURL" in value && typeof value.sourceURL === "string" &&
    "sha256" in value && typeof value.sha256 === "string" && /^[0-9a-f]{64}$/u.test(value.sha256) &&
    "observedAt" in value && typeof value.observedAt === "string" &&
    Number.isFinite(Date.parse(value.observedAt)) &&
    "fetchedAt" in value && typeof value.fetchedAt === "string" &&
    Number.isFinite(Date.parse(value.fetchedAt)) &&
    (!("etag" in value) || validValidator(value.etag)) &&
    (!("lastModified" in value) || validValidator(value.lastModified));
}

function validValidator(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 8_192 &&
    !/[\r\n]/u.test(value);
}
