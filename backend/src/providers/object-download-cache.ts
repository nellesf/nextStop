import { createHash, randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { rm, stat } from "node:fs/promises";
import { Storage } from "@google-cloud/storage";
import { deploymentRuntime, type RuntimeEnvironment } from "../runtime/deployment-runtime.js";
import { isStaticFeedCacheMetadata, type StaticFeedCacheMetadata } from "./static-feed-cache.js";

export interface CacheObjectInfo { readonly generation: string; readonly size: number }
export interface CacheObjectStore {
  info(name: string, generation?: string): Promise<CacheObjectInfo | undefined>;
  read(name: string, generation: string): Readable;
  write(name: string, source: Readable, previousGeneration: string | 0): Promise<CacheObjectInfo>;
  delete(name: string, generation: string): Promise<void>;
}
interface Manifest extends StaticFeedCacheMetadata {
  readonly version: 1;
  readonly object: string;
  readonly generation: string;
  readonly size: number;
}
export interface CachedDownload extends StaticFeedCacheMetadata {
  readonly size: number;
  openReadStream(): Readable;
  cleanup(): Promise<void>;
}

/** Immutable body generations plus a small conditional manifest replace. No PBF-sized local file. */
export class ObjectDownloadCache {
  private readonly prefix: string;
  private readonly manifestName: string;
  constructor(private readonly store: CacheObjectStore, slot: string) {
    if (!/^[a-z][a-z0-9-]{1,100}$/u.test(slot)) throw new Error("Invalid download cache slot.");
    this.prefix = `provider-cache/v1/${slot}/`;
    this.manifestName = `${this.prefix}manifest.json`;
  }

  async read(sourceURL: string, maximumBytes: number): Promise<CachedDownload | undefined> {
    const prior = await this.manifest();
    if (prior.value === undefined || prior.value.sourceURL !== sourceURL || prior.value.size > maximumBytes) return undefined;
    const info = await this.store.info(prior.value.object, prior.value.generation);
    if (info === undefined || info.size !== prior.value.size || info.generation !== prior.value.generation) return undefined;
    return this.artifact(prior.value);
  }

  async write(source: Readable, metadata: Omit<StaticFeedCacheMetadata, "sha256">,
    maximumBytes: number, expectedHash?: string): Promise<CachedDownload> {
    const prior = await this.manifest();
    const object = `${this.prefix}body-${randomUUID()}`;
    const hash = createHash("sha256");
    let size = 0;
    const checked = Readable.from((async function* () {
      for await (const chunk of source as AsyncIterable<Uint8Array>) {
        size += chunk.length;
        if (size > maximumBytes) throw new Error("Download exceeds its cache size limit.");
        hash.update(chunk); yield chunk;
      }
      if (size === 0) throw new Error("Downloaded cache body is empty.");
    })());
    let body: CacheObjectInfo | undefined;
    let committed = false;
    try {
      body = await this.store.write(object, checked, 0);
      const sha256 = hash.digest("hex");
      const value: Manifest = { ...metadata, sha256, version: 1, object, generation: body.generation, size };
      if (body.size !== size || !isStaticFeedCacheMetadata(value) ||
          (expectedHash !== undefined && expectedHash !== sha256)) throw new Error("Downloaded cache integrity mismatch.");
      const manifest = Buffer.from(JSON.stringify(value));
      if (manifest.length > 16_384) throw new Error("Cache manifest exceeds its limit.");
      await this.store.write(this.manifestName, Readable.from([manifest]), prior.generation ?? 0);
      committed = true;
      return this.artifact(value, prior.value);
    } finally {
      source.destroy(); checked.destroy();
      if (!committed && body !== undefined) {
        // A lost upload acknowledgement may still have published the manifest.
        // Never delete its body unless a fresh read proves it is unreferenced.
        try {
          if ((await this.manifest()).value?.object !== object) await this.store.delete(object, body.generation);
        } catch { /* Unknown state retains a possible live body for lifecycle cleanup. */ }
      }
      // A process killed during upload can leave an unreferenced object. The
      // dedicated cache bucket must also have bounded lifecycle retention.
    }
  }

  private async manifest(): Promise<{ generation?: string; value?: Manifest }> {
    const info = await this.store.info(this.manifestName);
    if (info === undefined) return {};
    if (info.size < 1 || info.size > 16_384) return { generation: info.generation };
    const bytes = await readBounded(this.store.read(this.manifestName, info.generation), 16_384);
    let value: unknown;
    try { value = JSON.parse(bytes.toString("utf8")); } catch { return { generation: info.generation }; }
    if (!isStaticFeedCacheMetadata(value) || !("version" in value) || value.version !== 1 ||
        !("object" in value) || typeof value.object !== "string" ||
        !new RegExp(`^${this.prefix}body-[0-9a-f-]{36}$`, "u").test(value.object) ||
        !("generation" in value) || typeof value.generation !== "string" || !/^[1-9][0-9]*$/u.test(value.generation) ||
        !("size" in value) || !Number.isSafeInteger(value.size) || Number(value.size) <= 0) return { generation: info.generation };
    return { generation: info.generation, value: value as Manifest };
  }

  private artifact(value: Manifest, previous?: Manifest): CachedDownload {
    const store = this.store;
    return { sourceURL: value.sourceURL, sha256: value.sha256, observedAt: value.observedAt,
      fetchedAt: value.fetchedAt, size: value.size,
      ...(value.etag === undefined ? {} : { etag: value.etag }),
      ...(value.lastModified === undefined ? {} : { lastModified: value.lastModified }),
      openReadStream: () => Readable.from((async function* () {
        const source = store.read(value.object, value.generation), hash = createHash("sha256");
        let size = 0;
        try {
          for await (const chunk of source as AsyncIterable<Uint8Array>) {
            size += chunk.length;
            if (size > value.size) throw new Error("Cached object exceeds its declared size.");
            hash.update(chunk); yield chunk;
          }
          if (size !== value.size || hash.digest("hex") !== value.sha256) throw new Error("Cached object integrity mismatch.");
        } finally { source.destroy(); }
      })()),
      cleanup: async () => {
        if (previous !== undefined && previous.object !== value.object) {
          await store.delete(previous.object, previous.generation);
        }
      },
    };
  }
}

export class GCSCacheObjectStore implements CacheObjectStore {
  private readonly bucket;
  constructor(bucket: string, storage = new Storage({ retryOptions: { autoRetry: false } })) {
    this.bucket = storage.bucket(bucket);
  }
  async info(name: string, generation?: string): Promise<CacheObjectInfo | undefined> {
    try {
      const [metadata] = await this.bucket.file(name, generation === undefined ? {} : { generation }).getMetadata();
      const size = Number(metadata.size), revision = String(metadata.generation);
      if (!Number.isSafeInteger(size) || size < 0 || !/^[1-9][0-9]*$/u.test(revision) || typeof metadata.crc32c !== "string") {
        throw new Error("Invalid cache object metadata.");
      }
      return { size, generation: revision };
    } catch (error) { if (isNotFound(error)) return undefined; throw error; }
  }
  read(name: string, generation: string): Readable {
    return this.bucket.file(name, { generation }).createReadStream({ validation: "crc32c", decompress: false });
  }
  async write(name: string, source: Readable, previousGeneration: string | 0): Promise<CacheObjectInfo> {
    const file = this.bucket.file(name);
    await pipeline(source, file.createWriteStream({ resumable: false, validation: "crc32c", timeout: 30 * 60 * 1_000,
      preconditionOpts: { ifGenerationMatch: previousGeneration },
      metadata: { contentType: "application/octet-stream", cacheControl: "no-store" } }));
    const info = await this.info(name);
    if (info === undefined) throw new Error("Completed cache upload is missing.");
    return info;
  }
  async delete(name: string, generation: string): Promise<void> {
    try { await this.bucket.file(name, { generation }).delete({ ifGenerationMatch: generation }); }
    catch (error) { if (!isNotFound(error)) throw error; }
  }
}

export function configuredObjectDownloadCache(slot: string, environment: RuntimeEnvironment = process.env): ObjectDownloadCache | undefined {
  const bucket = objectDownloadCacheBucket(environment);
  return bucket === undefined ? undefined : new ObjectDownloadCache(new GCSCacheObjectStore(bucket), slot);
}

export function objectDownloadCacheBucket(environment: RuntimeEnvironment = process.env): string | undefined {
  const backend = environment.DOWNLOAD_CACHE_BACKEND ?? "file";
  if (backend === "file") return undefined;
  if (backend !== "gcs" || deploymentRuntime(environment) !== "cloud-run") {
    throw new Error("GCS download caching requires the explicit staging Cloud Run runtime.");
  }
  const bucket = environment.DOWNLOAD_CACHE_BUCKET ?? "";
  if (!/^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$/u.test(bucket)) throw new Error("DOWNLOAD_CACHE_BUCKET is invalid.");
  return bucket;
}

/** Static CSV/JSON are already bounded to at most100MiB and retain their existing private parsing artifacts. */
export class ObjectStaticFeedCache {
  constructor(private readonly cache: ObjectDownloadCache, private readonly maximumBytes: number) {}
  async readInto(sourceURL: string, filePath: string, maximumBytes: number): Promise<StaticFeedCacheMetadata | undefined> {
    const cached = await this.cache.read(sourceURL, Math.min(maximumBytes, this.maximumBytes));
    if (cached === undefined) return undefined;
    try { await pipeline(cached.openReadStream(), createWriteStream(filePath, { flags: "w", mode: 0o600 })); }
    catch (error) { await rm(filePath, { force: true }); throw error; }
    return cached;
  }
  async write(filePath: string, metadata: StaticFeedCacheMetadata): Promise<void> {
    if ((await stat(filePath)).size > this.maximumBytes) throw new Error("Static cache artifact is too large.");
    const artifact = await this.cache.write(createReadStream(filePath), metadata, this.maximumBytes, metadata.sha256);
    await artifact.cleanup();
  }
}

async function readBounded(source: Readable, maximum: number): Promise<Buffer> {
  const chunks: Buffer[] = []; let size = 0;
  try {
    for await (const chunk of source as AsyncIterable<Uint8Array>) {
      size += chunk.length;
      if (size > maximum) throw new Error("Cache manifest exceeds its limit.");
      chunks.push(Buffer.from(chunk));
    }
    return Buffer.concat(chunks, size);
  } finally { source.destroy(); }
}
function isNotFound(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === 404;
}
