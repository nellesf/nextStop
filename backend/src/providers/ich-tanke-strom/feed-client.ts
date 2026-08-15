import { createHash } from "node:crypto";

const staticFeedURL =
  "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/data/oicp/ch.bfe.ladestellen-elektromobilitaet.json";
const liveFeedURL =
  "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/status/oicp/ch.bfe.ladestellen-elektromobilitaet.json";
const maximumBytes = {
  static: 50 * 1024 * 1024,
  live: 5 * 1024 * 1024,
} as const;
const timeoutMilliseconds = {
  static: 120_000,
  live: 30_000,
} as const;

export type IchTankeStromFeedKind = keyof typeof maximumBytes;

export interface IchTankeStromFeed {
  readonly kind: IchTankeStromFeedKind;
  readonly payload: unknown;
  readonly sha256: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly etag?: string;
  readonly lastModified: string;
}

export interface IchTankeStromFeedOptions {
  readonly fetchImplementation?: typeof fetch;
  readonly now?: () => Date;
  readonly maximumBytes?: number;
}

export async function downloadIchTankeStromFeed(
  kind: IchTankeStromFeedKind,
  options: IchTankeStromFeedOptions = {},
): Promise<IchTankeStromFeed> {
  const url = kind === "static" ? staticFeedURL : liveFeedURL;
  const response = await (options.fetchImplementation ?? fetch)(url, {
    headers: {
      accept: "application/json",
      "user-agent": "nextStop-backend/0.1 (+https://github.com/)",
    },
    redirect: "follow",
    signal: AbortSignal.timeout(timeoutMilliseconds[kind]),
  });
  if (response.url !== url) {
    throw new Error(`ich-tanke-strom ${kind} feed redirected unexpectedly.`);
  }
  if (!response.ok) {
    throw new Error(`ich-tanke-strom ${kind} feed returned HTTP ${response.status}.`);
  }
  const contentType = response.headers
    .get("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    throw new Error(`ich-tanke-strom ${kind} feed returned an unexpected content type.`);
  }
  const limit = options.maximumBytes ?? maximumBytes[kind];
  const body = await readLimitedBody(response, limit);
  const lastModified = response.headers.get("last-modified");
  if (lastModified === null || !Number.isFinite(Date.parse(lastModified))) {
    throw new Error(`ich-tanke-strom ${kind} feed has no valid Last-Modified value.`);
  }
  const observedAt = new Date(lastModified).toISOString();
  const now = (options.now ?? (() => new Date()))();
  if (Date.parse(observedAt) > now.getTime() + 5 * 60 * 1000) {
    throw new Error(`ich-tanke-strom ${kind} feed observation is in the future.`);
  }
  let payload: unknown;
  try {
    payload = JSON.parse(body.toString("utf8")) as unknown;
  } catch {
    throw new Error(`ich-tanke-strom ${kind} feed is not valid JSON.`);
  }
  const etag = response.headers.get("etag");
  return {
    kind,
    payload,
    sha256: createHash("sha256").update(body).digest("hex"),
    observedAt,
    fetchedAt: now.toISOString(),
    ...(etag === null || etag.length === 0 ? {} : { etag }),
    lastModified,
  };
}

async function readLimitedBody(response: Response, maximum: number): Promise<Buffer> {
  if (response.body === null) {
    throw new Error("ich-tanke-strom response body is missing.");
  }
  const chunks: Buffer<ArrayBufferLike>[] = [];
  let total = 0;
  for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
    const buffer = Buffer.from(chunk);
    total += buffer.length;
    if (total > maximum) {
      throw new Error(`ich-tanke-strom response exceeds ${maximum} bytes.`);
    }
    chunks.push(buffer);
  }
  if (total === 0) {
    throw new Error("ich-tanke-strom response is empty.");
  }
  return Buffer.concat(chunks, total);
}
