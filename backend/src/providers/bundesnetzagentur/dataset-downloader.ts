import { createHash } from "node:crypto";
import { open, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

const officialPageURL =
  "https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenkarte/start.html";
const datasetHost = "data.bundesnetzagentur.de";
const datasetPathPattern =
  /^\/Bundesnetzagentur\/DE\/Fachthemen\/ElektrizitaetundGas\/E-Mobilitaet\/Ladesaeulenregister_BNetzA_(\d{4})-(\d{2})-(\d{2})\.csv$/u;
const maximumPageBytes = 2 * 1024 * 1024;
const defaultMaximumDatasetBytes = 100 * 1024 * 1024;
const pageTimeoutMilliseconds = 20_000;
const datasetTimeoutMilliseconds = 180_000;
const userAgent = "nextStop-backend/0.1 (+https://github.com/)";

export interface BundesnetzagenturDatasetArtifact {
  readonly filePath: string;
  readonly sha256: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly sourceURL: string;
  readonly etag?: string;
  readonly lastModified?: string;
  cleanup(): Promise<void>;
}

export interface BundesnetzagenturDownloadOptions {
  readonly fetchImplementation?: typeof fetch;
  readonly now?: () => Date;
  readonly pageURL?: string;
  readonly maximumDatasetBytes?: number;
}

export async function downloadLatestBundesnetzagenturDataset(
  options: BundesnetzagenturDownloadOptions = {},
): Promise<BundesnetzagenturDatasetArtifact> {
  const fetchImplementation = options.fetchImplementation ?? fetch;
  const pageURL = options.pageURL ?? officialPageURL;
  validateOfficialPageURL(pageURL);

  const pageResponse = await fetchWithTimeout(
    fetchImplementation,
    pageURL,
    pageTimeoutMilliseconds,
  );
  validateOfficialPageURL(pageResponse.url);
  requireSuccessfulResponse(pageResponse, "Bundesnetzagentur dataset page");
  requireContentType(pageResponse, ["text/html"], "Bundesnetzagentur dataset page");
  const page = (await readLimitedBody(pageResponse, maximumPageBytes)).toString("utf8");
  const dataset = selectLatestDatasetURL(page, pageResponse.url);

  const response = await fetchWithTimeout(
    fetchImplementation,
    dataset.url.href,
    datasetTimeoutMilliseconds,
  );
  validateDatasetURL(new URL(response.url));
  if (response.url !== dataset.url.href) {
    throw new Error("Bundesnetzagentur dataset redirected unexpectedly.");
  }
  requireSuccessfulResponse(response, "Bundesnetzagentur dataset");
  requireContentType(
    response,
    ["text/csv", "text/plain", "application/csv", "application/octet-stream"],
    "Bundesnetzagentur dataset",
  );

  const maximumDatasetBytes =
    options.maximumDatasetBytes ?? defaultMaximumDatasetBytes;
  validateContentLength(response, maximumDatasetBytes);
  const directory = await mkdtemp(join(tmpdir(), "nextstop-bnetza-"));
  const filePath = join(directory, basename(dataset.url.pathname));
  try {
    const digest = await writeLimitedBody(response, filePath, maximumDatasetBytes);
    const fetchedAt = (options.now ?? (() => new Date()))().toISOString();
    return {
      filePath,
      sha256: digest,
      observedAt: dataset.observedAt,
      fetchedAt,
      sourceURL: dataset.url.href,
      ...optionalHeader("etag", response.headers.get("etag")),
      ...optionalHeader("lastModified", response.headers.get("last-modified")),
      cleanup: async () => rm(directory, { recursive: true, force: true }),
    };
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
}

function selectLatestDatasetURL(
  page: string,
  baseURL: string,
): Readonly<{ url: URL; observedAt: string }> {
  const hrefPattern = /href\s*=\s*["']([^"']+)["']/giu;
  const matches = new Map<string, Readonly<{ url: URL; observedAt: string }>>();
  for (const match of page.matchAll(hrefPattern)) {
    const rawHref = match[1];
    if (rawHref === undefined) {
      continue;
    }
    const decodedHref = decodeHTMLAttribute(rawHref);
    let candidate: URL;
    try {
      candidate = new URL(decodedHref, baseURL);
      const observedAt = validateDatasetURL(candidate);
      matches.set(candidate.href, { url: candidate, observedAt });
    } catch {
      // Other links on the authority page are intentionally ignored.
    }
  }
  const latest = [...matches.values()].toSorted((first, second) =>
    second.observedAt.localeCompare(first.observedAt),
  )[0];
  if (latest === undefined) {
    throw new Error("The official page contains no approved Bundesnetzagentur CSV link.");
  }
  return latest;
}

function validateOfficialPageURL(value: string): void {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.hostname !== "www.bundesnetzagentur.de" ||
    url.username.length > 0 ||
    url.password.length > 0
  ) {
    throw new Error("Unexpected Bundesnetzagentur dataset page URL.");
  }
}

function validateDatasetURL(url: URL): string {
  if (
    url.protocol !== "https:" ||
    url.hostname !== datasetHost ||
    url.port.length > 0 ||
    url.username.length > 0 ||
    url.password.length > 0 ||
    url.search.length > 0 ||
    url.hash.length > 0
  ) {
    throw new Error("Unexpected Bundesnetzagentur dataset URL.");
  }
  const match = datasetPathPattern.exec(url.pathname);
  if (match === null) {
    throw new Error("Unexpected Bundesnetzagentur dataset path.");
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    throw new Error("Bundesnetzagentur dataset filename contains an invalid date.");
  }
  return date.toISOString();
}

async function fetchWithTimeout(
  fetchImplementation: typeof fetch,
  url: string,
  timeoutMilliseconds: number,
): Promise<Response> {
  return fetchImplementation(url, {
    headers: { accept: "*/*", "user-agent": userAgent },
    redirect: "follow",
    signal: AbortSignal.timeout(timeoutMilliseconds),
  });
}

function requireSuccessfulResponse(response: Response, label: string): void {
  if (!response.ok) {
    throw new Error(`${label} returned HTTP ${response.status}.`);
  }
}

function requireContentType(
  response: Response,
  allowed: readonly string[],
  label: string,
): void {
  const value = response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (value === undefined || !allowed.includes(value)) {
    throw new Error(`${label} returned an unexpected content type.`);
  }
}

function validateContentLength(response: Response, maximumBytes: number): void {
  const value = response.headers.get("content-length");
  if (value === null) {
    return;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > maximumBytes) {
    throw new Error(`Bundesnetzagentur dataset exceeds ${maximumBytes} bytes.`);
  }
}

async function readLimitedBody(response: Response, maximumBytes: number): Promise<Buffer> {
  if (response.body === null) {
    throw new Error("HTTP response body is missing.");
  }
  const chunks: Buffer<ArrayBufferLike>[] = [];
  let total = 0;
  for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
    const buffer = Buffer.from(chunk);
    total += buffer.length;
    if (total > maximumBytes) {
      throw new Error(`HTTP response exceeds ${maximumBytes} bytes.`);
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks, total);
}

async function writeLimitedBody(
  response: Response,
  filePath: string,
  maximumBytes: number,
): Promise<string> {
  if (response.body === null) {
    throw new Error("Bundesnetzagentur dataset response body is missing.");
  }
  const file = await open(filePath, "wx", 0o600);
  const hash = createHash("sha256");
  let total = 0;
  try {
    for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
      const buffer = Buffer.from(chunk);
      total += buffer.length;
      if (total > maximumBytes) {
        throw new Error(`Bundesnetzagentur dataset exceeds ${maximumBytes} bytes.`);
      }
      hash.update(buffer);
      await file.write(buffer);
    }
  } finally {
    await file.close();
  }
  if (total === 0) {
    throw new Error("Bundesnetzagentur dataset is empty.");
  }
  return hash.digest("hex");
}

function decodeHTMLAttribute(value: string): string {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&#38;", "&")
    .replaceAll("&#x26;", "&");
}

function optionalHeader<Key extends string>(key: Key, value: string | null) {
  return value === null || value.length === 0 ? {} : { [key]: value };
}
