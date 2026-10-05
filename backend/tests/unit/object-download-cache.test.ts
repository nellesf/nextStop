import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { Readable, Writable } from "node:stream";
import type { Storage } from "@google-cloud/storage";
import test from "node:test";
import { GCSCacheObjectStore, ObjectDownloadCache, objectDownloadCacheBucket } from "../../src/providers/object-download-cache.js";
import { downloadConfiguredGeofabrikDatasets } from "../../src/providers/openstreetmap/geofabrik-downloader.js";
import { downloadIchTankeStromFeed } from "../../src/providers/ich-tanke-strom/feed-client.js";
import { MemoryObjectStore, streamBytes } from "../fixtures/memory-object-store.js";

const sourceURL = "https://download.geofabrik.de/europe/germany-latest.osm.pbf";
const metadata = { sourceURL, observedAt: "2026-10-01T00:00:00.000Z", fetchedAt: "2026-10-02T00:00:00.000Z",
  etag: '"one"', lastModified: "Thu, 01 Oct 2026 00:00:00 GMT" };
const payload = Buffer.from("bounded synthetic provider bytes");

void test("object cache streams once, pins every read to its generation and preserves provenance", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  let chunks = 0;
  const source = Readable.from((function* () {
    for (const value of [payload.subarray(0, 5), payload.subarray(5)]) { chunks++; yield value; }
  })());
  const artifact = await cache.write(source, metadata, 100);
  assert.equal(chunks, 2); assert.equal(artifact.sha256, createHash("sha256").update(payload).digest("hex"));
  assert.equal(artifact.observedAt, metadata.observedAt);
  const cached = await cache.read(sourceURL, 100); assert.ok(cached);
  for (let pass = 0; pass < 3; pass++) assert.deepEqual(await streamBytes(cached.openReadStream()), payload);
  const bodyReads = store.reads.filter(({ name }) => name.includes("/body-"));
  assert.equal(bodyReads.length, 3); assert.equal(new Set(bodyReads.map(({ generation }) => generation)).size, 1);
  assert.equal(await cache.read("https://wrong.test/file", 100), undefined);
  assert.equal(await cache.read(sourceURL, 1), undefined);
});

void test("interrupted, empty, oversized and wrong-hash downloads never replace the complete manifest", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  await cache.write(Readable.from([payload]), metadata, 100);
  const interrupted = Readable.from((function* () { yield Buffer.from("partial"); throw new Error("transport"); })());
  for (const [source, maximum, expected] of [
    [interrupted, 100, undefined], [Readable.from([]), 100, undefined],
    [Readable.from([payload]), 1, undefined], [Readable.from([payload]), 100, "0".repeat(64)],
  ] as const) {
    await assert.rejects(cache.write(source, metadata, maximum, expected));
    const cached = await cache.read(sourceURL, 100); assert.ok(cached);
    assert.deepEqual(await streamBytes(cached.openReadStream()), payload);
  }
  assert.equal([...store.objects.keys()].filter((name) => name.includes("/body-")).length, 1);
});

void test("manifest compare-and-swap failure retains old body; ambiguous committed acknowledgement retains new body", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  await cache.write(Readable.from([payload]), metadata, 100);
  store.beforeManifest = () => { throw new Error("CAS rejected."); };
  await assert.rejects(cache.write(Readable.from(["replacement"]), metadata, 100));
  assert.deepEqual(await streamBytes((await cache.read(sourceURL, 100))!.openReadStream()), payload);
  delete store.beforeManifest; store.loseManifestAcknowledgement = true;
  await assert.rejects(cache.write(Readable.from(["replacement"]), metadata, 100), /Acknowledgement/u);
  assert.equal((await streamBytes((await cache.read(sourceURL, 100))!.openReadStream())).toString(), "replacement");
});

void test("concurrent manifest replacement publishes one whole body and removes only the losing unreferenced upload", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  const results = await Promise.allSettled(["one", "two"].map((text) => cache.write(Readable.from([text]), metadata, 100)));
  assert.equal(results.filter(({ status }) => status === "fulfilled").length, 1);
  const cached = await cache.read(sourceURL, 100); assert.ok(cached);
  assert.ok(["one", "two"].includes((await streamBytes(cached.openReadStream())).toString()));
  assert.equal([...store.objects.keys()].filter((name) => name.includes("/body-")).length, 1);
});

void test("malformed, excessive and cross-slot manifests are cache misses, not trusted object references", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  await cache.write(Readable.from([payload]), metadata, 100);
  const manifest = store.objects.get("provider-cache/v1/test-osm/manifest.json")!;
  const original = JSON.parse(manifest.bytes.toString()) as Record<string, unknown>;
  for (const bytes of [Buffer.from("invalid"), Buffer.alloc(16_385),
    Buffer.from(JSON.stringify({ ...original, object: "unrelated/private-object" })),
    Buffer.from(JSON.stringify({ ...original, generation: "-1" })),
    Buffer.from(JSON.stringify({ ...original, size: -1 }))]) {
    manifest.bytes = bytes; assert.equal(await cache.read(sourceURL, 100), undefined);
  }
  assert.equal(store.reads.some(({ name }) => name === "unrelated/private-object"), false);
});

void test("GCS adapter pins generations, validates CRC, uses write/delete preconditions and treats only404 as missing", async () => {
  const files: { name: string; generation?: string }[] = [], reads: unknown[] = [], writes: unknown[] = [], deletions: unknown[] = [];
  let metadataFailure: number | undefined;
  const storage = { bucket: (name: string) => {
    assert.equal(name, "private-cache");
    return { file: (file: string, options: { generation?: string } = {}) => {
      files.push({ name: file, ...options });
      return {
        getMetadata: () => metadataFailure === undefined
          ? Promise.resolve([{ generation: "17", size: "4", crc32c: "AAAAAA==" }]) : Promise.reject(Object.assign(new Error("Synthetic metadata failure"), { code: metadataFailure })),
        createReadStream: (options: unknown) => { reads.push(options); return Readable.from(["data"]); },
        createWriteStream: (options: unknown) => { writes.push(options); return new Writable({ write(_chunk, _encoding, done) { done(); } }); },
        delete: (options: unknown) => { deletions.push(options); return Promise.resolve(); },
      };
    } };
  } } as unknown as Storage;
  const store = new GCSCacheObjectStore("private-cache", storage);
  assert.deepEqual(await store.info("body", "17"), { generation: "17", size: 4 });
  assert.equal((await streamBytes(store.read("body", "17"))).toString(), "data");
  await store.write("manifest", Readable.from(["data"]), "16"); await store.delete("old-body", "15");
  assert.ok(files.some(({ name, generation }) => name === "body" && generation === "17"));
  assert.deepEqual(reads, [{ validation: "crc32c", decompress: false }]);
  assert.deepEqual(writes, [{ resumable: false, validation: "crc32c", timeout: 1_800_000,
    preconditionOpts: { ifGenerationMatch: "16" }, metadata: { contentType: "application/octet-stream", cacheControl: "no-store" } }]);
  assert.deepEqual(deletions, [{ ifGenerationMatch: "15" }]);
  metadataFailure = 404; assert.equal(await store.info("missing"), undefined);
  for (const code of [403, 429, 500]) { metadataFailure = code; await assert.rejects(store.info("inaccessible")); }
});

void test("old generation is retained until consumer cleanup; tampered body and unsafe headers fail closed", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  const first = await cache.write(Readable.from([payload]), metadata, 100);
  const second = await cache.write(Readable.from(["replacement"]), metadata, 100);
  assert.deepEqual(await streamBytes(first.openReadStream()), payload);
  await second.cleanup(); assert.equal(store.deletions.length, 1);
  await assert.rejects(streamBytes(first.openReadStream()), /Missing/u);
  const body = [...store.objects].find(([name]) => name.includes("/body-"))![1];
  body.bytes[0] = 0;
  await assert.rejects(streamBytes(second.openReadStream()), /integrity/u);
  await assert.rejects(cache.write(Readable.from([payload]), { ...metadata, etag: "bad\r\nheader" }, 100), /integrity/u);
});

void test("cloud cache is explicit and staging-only; VM retains its existing file cache", () => {
  assert.equal(objectDownloadCacheBucket({}), undefined);
  const cloud = { NEXTSTOP_RUNTIME: "cloud-run", NEXTSTOP_ENVIRONMENT: "staging", DOWNLOAD_CACHE_BACKEND: "gcs",
    DOWNLOAD_CACHE_BUCKET: "nextstop-testing-cache" };
  assert.equal(objectDownloadCacheBucket(cloud), cloud.DOWNLOAD_CACHE_BUCKET);
  for (const override of [{ NEXTSTOP_RUNTIME: "vm" }, { NEXTSTOP_ENVIRONMENT: "production" },
    { DOWNLOAD_CACHE_BUCKET: "gs://invalid" }, { DOWNLOAD_CACHE_BACKEND: "unknown" }]) {
    assert.throws(() => objectDownloadCacheBucket({ ...cloud, ...override }));
  }
});

void test("Geofabrik object cache sends validators and 304 reuses exact source/hash/time without a temp PBF", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
  const first = await downloadConfiguredGeofabrikDatasets({ datasetURLs: [sourceURL], objectCache: () => cache,
    now: () => new Date(metadata.fetchedAt), fetchImplementation: () => Promise.resolve(response(payload, sourceURL)) });
  const second = await downloadConfiguredGeofabrikDatasets({ datasetURLs: [sourceURL], objectCache: () => cache,
    now: () => new Date("2026-10-03T00:00:00Z"), fetchImplementation: (_url, options) => {
      assert.equal(new Headers(options?.headers).get("if-none-match"), metadata.etag);
      assert.equal(new Headers(options?.headers).get("if-modified-since"), metadata.lastModified);
      return Promise.resolve(response(null, sourceURL, 304));
    } });
  assert.equal(first[0]?.filePath, undefined); assert.equal(second[0]?.sha256, first[0]?.sha256);
  assert.equal(second[0]?.fetchedAt, first[0]?.fetchedAt); assert.equal(second[0]?.observedAt, first[0]?.observedAt);
  assert.deepEqual(await streamBytes(second[0]!.openReadStream!()), payload);
  for (const bad of [response(payload, "https://untrusted.test/file"), response(payload, sourceURL, 200, { "content-type": "text/html" }),
    response(payload, sourceURL, 200, { "last-modified": "invalid" }), response(payload, sourceURL, 200, { "content-length": "9999" })]) {
    await assert.rejects(downloadConfiguredGeofabrikDatasets({ datasetURLs: [sourceURL], objectCache: () => cache,
      maximumDatasetBytes: 100, now: () => new Date(metadata.fetchedAt), fetchImplementation: () => Promise.resolve(bad) }));
  }
  assert.deepEqual(await streamBytes((await cache.read(sourceURL, 100))!.openReadStream()), payload);
});

void test("Swiss static JSON uses object validators while live stays uncached and cannot fake freshness through 304", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-swiss");
  const staticURL = "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/data/oicp/ch.bfe.ladestellen-elektromobilitaet.json";
  const first = await downloadIchTankeStromFeed("static", { objectCache: cache, now: () => new Date(metadata.fetchedAt),
    fetchImplementation: () => Promise.resolve(response(Buffer.from('{"EVSEData":[]}'), staticURL, 200, { "content-type": "application/json" })) });
  const second = await downloadIchTankeStromFeed("static", { objectCache: cache, now: () => new Date(metadata.fetchedAt),
    fetchImplementation: (_url, options) => { assert.equal(new Headers(options?.headers).get("if-none-match"), metadata.etag);
      return Promise.resolve(response(null, staticURL, 304)); } });
  assert.equal(second.sha256, first.sha256); assert.equal(second.observedAt, first.observedAt);
  const before = store.reads.length;
  await assert.rejects(downloadIchTankeStromFeed("live", { objectCache: cache, fetchImplementation: (url, options) => {
    assert.equal(new Headers(options?.headers).has("if-none-match"), false);
    return Promise.resolve(response(null, typeof url === "string" ? url : url instanceof URL ? url.href : url.url, 304));
  } }), /HTTP 304/u);
  assert.equal(store.reads.length, before);
});

function response(body: Buffer | null, url: string, status = 200, headers: Record<string, string> = {}): Response {
  const value = new Response(body, { status, headers: { "content-type": "application/octet-stream",
    etag: metadata.etag, "last-modified": metadata.lastModified, ...headers } });
  Object.defineProperty(value, "url", { value: url }); return value;
}
