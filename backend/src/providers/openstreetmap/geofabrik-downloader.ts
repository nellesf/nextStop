import { createHash, randomUUID } from "node:crypto";
import { access, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, isAbsolute, join, resolve } from "node:path";

const defaultDatasetURLs = [
  "https://download.geofabrik.de/europe/germany-latest.osm.pbf",
  "https://download.geofabrik.de/europe/switzerland-latest.osm.pbf",
] as const;
const defaultMaximumDatasetBytes = 8 * 1_024 * 1_024 * 1_024;
const requestTimeoutMilliseconds = 30 * 60 * 1_000;
const userAgent = "nextStop-backend/0.1 (+https://github.com/nellesf/nextStop)";

export interface GeofabrikDatasetArtifact {
  readonly filePath: string;
  readonly sha256: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly sourceURL: string;
  readonly etag?: string;
  readonly lastModified?: string;
  cleanup(): Promise<void>;
}

interface CacheMetadata {
  readonly version: 1;
  readonly sha256: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly sourceURL: string;
  readonly etag?: string;
  readonly lastModified?: string;
}

export interface GeofabrikDownloadOptions {
  readonly datasetURLs?: readonly string[];
  readonly cacheDirectory?: string;
  readonly fetchImplementation?: typeof fetch;
  readonly maximumDatasetBytes?: number;
  readonly now?: () => Date;
}

export async function downloadConfiguredGeofabrikDatasets(
  options: GeofabrikDownloadOptions = {},
): Promise<readonly GeofabrikDatasetArtifact[]> {
  const urls = options.datasetURLs ?? configuredDatasetURLs();
  if (urls.length === 0 || new Set(urls).size !== urls.length) {
    throw new Error("At least one unique Geofabrik PBF URL is required.");
  }
  const cacheDirectory = resolve(
    options.cacheDirectory ??
      nonEmpty(process.env.OSM_CACHE_DIRECTORY) ??
      join(tmpdir(), "nextstop-osm-cache"),
  );
  if (!isAbsolute(cacheDirectory)) {
    throw new Error("OSM cache directory must be absolute.");
  }
  await mkdir(cacheDirectory, { recursive: true, mode: 0o700 });

  const artifacts: GeofabrikDatasetArtifact[] = [];
  for (const rawURL of urls) {
    const url = validateDatasetURL(rawURL);
    artifacts.push(await downloadOne(url, cacheDirectory, options));
  }
  return artifacts;
}

function nonEmpty(value: string | undefined): string | undefined {
  return value === undefined || value.trim().length === 0 ? undefined : value.trim();
}

export function configuredDatasetURLs(
  value: string | undefined = process.env.OSM_GEOFABRIK_PBF_URLS,
): readonly string[] {
  if (value === undefined || value.trim().length === 0) {
    return defaultDatasetURLs;
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

async function downloadOne(
  url: URL,
  cacheDirectory: string,
  options: GeofabrikDownloadOptions,
): Promise<GeofabrikDatasetArtifact> {
  const key = createHash("sha256").update(url.href).digest("hex");
  const filePath = join(cacheDirectory, `${key}-${basename(url.pathname)}`);
  const metadataPath = `${filePath}.json`;
  const cached = await readMetadata(metadataPath, url.href);
  const hasCachedFile = await fileExists(filePath);
  const headers: Record<string, string> = {
    accept: "application/octet-stream,*/*",
    "user-agent": userAgent,
  };
  if (hasCachedFile && cached?.etag !== undefined) {
    headers["if-none-match"] = cached.etag;
  }
  if (hasCachedFile && cached?.lastModified !== undefined) {
    headers["if-modified-since"] = cached.lastModified;
  }

  const fetchImplementation = options.fetchImplementation ?? fetch;
  let response = await fetchImplementation(url, {
    headers,
    redirect: "follow",
    signal: AbortSignal.timeout(requestTimeoutMilliseconds),
  });
  if (response.status === 304 && hasCachedFile && cached !== undefined) {
    return artifactFromCache(filePath, cached);
  }
  if (response.status === 304) {
    response = await fetchImplementation(url, {
      headers: {
        accept: "application/octet-stream,*/*",
        "user-agent": userAgent,
      },
      redirect: "follow",
      signal: AbortSignal.timeout(requestTimeoutMilliseconds),
    });
  }
  validateDatasetURL(response.url);
  if (!response.ok) {
    throw new Error(`Geofabrik dataset returned HTTP ${response.status}.`);
  }
  requireContentType(response);
  const maximumDatasetBytes = options.maximumDatasetBytes ?? defaultMaximumDatasetBytes;
  validateContentLength(response, maximumDatasetBytes);

  const temporaryPath = `${filePath}.part-${randomUUID()}`;
  try {
    const { sha256, size } = await writeLimitedBody(
      response,
      temporaryPath,
      maximumDatasetBytes,
    );
    if (size === 0) {
      throw new Error("Geofabrik dataset is empty.");
    }
    await rename(temporaryPath, filePath);
    const fetchedAt = (options.now ?? (() => new Date()))().toISOString();
    const lastModified = response.headers.get("last-modified") ?? undefined;
    const observedAt = parseObservedAt(lastModified) ?? fetchedAt;
    const metadata: CacheMetadata = {
      version: 1,
      sha256,
      observedAt,
      fetchedAt,
      sourceURL: url.href,
      ...optionalValue("etag", response.headers.get("etag")),
      ...optionalValue("lastModified", lastModified),
    };
    await writeFile(metadataPath, `${JSON.stringify(metadata)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    return artifactFromCache(filePath, metadata);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

function validateDatasetURL(value: string | URL): URL {
  const url = value instanceof URL ? value : new URL(value);
  if (
    url.protocol !== "https:" ||
    !(url.hostname === "download.geofabrik.de" || url.hostname.endsWith(".geofabrik.de")) ||
    url.port.length > 0 ||
    url.username.length > 0 ||
    url.password.length > 0 ||
    url.search.length > 0 ||
    url.hash.length > 0 ||
    !/^\/[a-z0-9/-]+-latest\.osm\.pbf$/u.test(url.pathname)
  ) {
    throw new Error("Unexpected Geofabrik dataset URL.");
  }
  return url;
}

async function readMetadata(
  metadataPath: string,
  sourceURL: string,
): Promise<CacheMetadata | undefined> {
  try {
    const value: unknown = JSON.parse(await readFile(metadataPath, "utf8"));
    if (!isCacheMetadata(value) || value.sourceURL !== sourceURL) {
      return undefined;
    }
    return value;
  } catch {
    return undefined;
  }
}

function isCacheMetadata(value: unknown): value is CacheMetadata {
  return (
    typeof value === "object" &&
    value !== null &&
    "version" in value &&
    value.version === 1 &&
    "sha256" in value &&
    typeof value.sha256 === "string" &&
    /^[0-9a-f]{64}$/u.test(value.sha256) &&
    "observedAt" in value &&
    typeof value.observedAt === "string" &&
    Number.isFinite(Date.parse(value.observedAt)) &&
    "fetchedAt" in value &&
    typeof value.fetchedAt === "string" &&
    Number.isFinite(Date.parse(value.fetchedAt)) &&
    "sourceURL" in value &&
    typeof value.sourceURL === "string" &&
    (!("etag" in value) || typeof value.etag === "string") &&
    (!("lastModified" in value) || typeof value.lastModified === "string")
  );
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function artifactFromCache(
  filePath: string,
  metadata: CacheMetadata,
): GeofabrikDatasetArtifact {
  return {
    filePath,
    sha256: metadata.sha256,
    observedAt: metadata.observedAt,
    fetchedAt: metadata.fetchedAt,
    sourceURL: metadata.sourceURL,
    ...(metadata.etag === undefined ? {} : { etag: metadata.etag }),
    ...(metadata.lastModified === undefined
      ? {}
      : { lastModified: metadata.lastModified }),
    cleanup: () => Promise.resolve(),
  };
}

function requireContentType(response: Response): void {
  const value = response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (
    value !== undefined &&
    ![
      "application/octet-stream",
      "application/x-protobuf",
      "binary/octet-stream",
    ].includes(value)
  ) {
    throw new Error("Geofabrik dataset returned an unexpected content type.");
  }
}

function validateContentLength(response: Response, maximumBytes: number): void {
  const value = response.headers.get("content-length");
  if (value === null) {
    return;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > maximumBytes) {
    throw new Error(`Geofabrik dataset exceeds ${maximumBytes} bytes.`);
  }
}

async function writeLimitedBody(
  response: Response,
  filePath: string,
  maximumBytes: number,
): Promise<Readonly<{ sha256: string; size: number }>> {
  if (response.body === null) {
    throw new Error("Geofabrik dataset response body is missing.");
  }
  const file = await open(filePath, "wx", 0o600);
  const hash = createHash("sha256");
  let total = 0;
  try {
    for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
      const buffer = Buffer.from(chunk);
      total += buffer.length;
      if (total > maximumBytes) {
        throw new Error(`Geofabrik dataset exceeds ${maximumBytes} bytes.`);
      }
      hash.update(buffer);
      await file.write(buffer);
    }
  } finally {
    await file.close();
  }
  return { sha256: hash.digest("hex"), size: total };
}

function parseObservedAt(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : undefined;
}

function optionalValue<Key extends string>(key: Key, value: string | null | undefined) {
  return value === null || value === undefined || value.length === 0
    ? {}
    : { [key]: value };
}
