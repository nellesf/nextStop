import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { ObjectDownloadCache } from "../../src/providers/object-download-cache.js";
import { MemoryObjectStore, streamBytes } from "../fixtures/memory-object-store.js";

import { downloadConfiguredGeofabrikDatasets } from "../../src/providers/openstreetmap/geofabrik-downloader.js";

const latestURL = "https://download.geofabrik.de/europe/germany-latest.osm.pbf";
const datedURL = "https://download.geofabrik.de/europe/germany-260817.osm.pbf";

void test("accepts Geofabrik's same-dataset dated redirect", async () => {
  const directory = await mkdtemp(join(tmpdir(), "nextstop-geofabrik-test-"));
  try {
    const artifacts = await downloadConfiguredGeofabrikDatasets({
      datasetURLs: [latestURL],
      cacheDirectory: directory,
      now: () => new Date("2026-08-18T08:00:00.000Z"),
      fetchImplementation: () =>
        Promise.resolve(response("pbf fixture", datedURL, {
          etag: '"fixture"',
          "last-modified": "Mon, 17 Aug 2026 23:32:13 GMT",
        })),
    });
    assert.equal(artifacts.length, 1);
    assert.equal(await readFile(artifacts[0]?.filePath ?? "", "utf8"), "pbf fixture");
    assert.equal(artifacts[0]?.sourceURL, latestURL);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

void test("rejects a redirect to a different Geofabrik dataset", async () => {
  const directory = await mkdtemp(join(tmpdir(), "nextstop-geofabrik-test-"));
  try {
    await assert.rejects(
      downloadConfiguredGeofabrikDatasets({
        datasetURLs: [latestURL],
        cacheDirectory: directory,
        fetchImplementation: () =>
          Promise.resolve(
            response("wrong pbf", "https://download.geofabrik.de/europe/france-260817.osm.pbf"),
          ),
      }),
      /redirect URL/u,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

const mirrorURL = "https://ftp5.gwdg.de/pub/misc/openstreetmap/download.geofabrik.de/germany-latest.osm.pbf";

for (const mode of ["file", "object"] as const) {
  void test(`${mode} cache follows the exact German mirror and preserves canonical provenance on 200 and 304`, async () => {
    const directory = await mkdtemp(join(tmpdir(), "nextstop-geofabrik-mirror-test-"));
    const cache = new ObjectDownloadCache(new MemoryObjectStore(), "test-osm");
    let conditional = false;
    const requests: string[] = [];
    try {
      const options = { datasetURLs: [latestURL], cacheDirectory: directory,
        ...(mode === "object" ? { objectCache: () => cache } : {}),
        now: () => new Date("2026-10-04T12:00:00.000Z"),
        fetchImplementation: ((input, init) => {
          const url = requestURL(input); requests.push(url);
          assert.equal(init?.redirect, "manual");
          if (conditional) assert.equal(new Headers(init.headers).get("if-none-match"), '"mirror-fixture"');
          if (url === latestURL) return Promise.resolve(redirect(latestURL, mirrorURL));
          assert.equal(url, mirrorURL);
          return Promise.resolve(conditional ? withURL(new Response(null, { status: 304 }), mirrorURL)
            : response("pbf fixture", mirrorURL, { etag: '"mirror-fixture"', "last-modified": "Sun, 04 Oct 2026 00:13:57 GMT" }));
        }) as typeof fetch };
      const first = (await downloadConfiguredGeofabrikDatasets(options))[0]; assert.ok(first);
      assert.equal(first.sourceURL, latestURL); assert.equal(first.observedAt, "2026-10-04T00:13:57.000Z");
      assert.equal(first.openReadStream === undefined ? await readFile(first.filePath!, "utf8")
        : (await streamBytes(first.openReadStream())).toString(), "pbf fixture");
      conditional = true;
      const second = (await downloadConfiguredGeofabrikDatasets(options))[0]; assert.ok(second);
      assert.equal(second.sourceURL, latestURL); assert.equal(second.sha256, first.sha256);
      assert.equal(second.fetchedAt, first.fetchedAt); assert.equal(second.observedAt, first.observedAt);
      assert.deepEqual(requests, [latestURL, mirrorURL, latestURL, mirrorURL]);
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
}

void test("rejects every unapproved mirror/intermediate hop before making its request and cancels its body", async () => {
  const cache = new ObjectDownloadCache(new MemoryObjectStore(), "test-osm");
  for (const target of [
    mirrorURL.replace("ftp5", "ftp6"), mirrorURL.replace("ftp5.gwdg.de", "ftp5.gwdg.de.untrusted.test"),
    mirrorURL.replace("germany-latest", "switzerland-latest"), mirrorURL.replace("germany-latest", "germany-261003"),
    mirrorURL.replace("download.geofabrik.de/", "download.geofabrik.de/europe/"),
    mirrorURL.replace("https:", "http:"), mirrorURL + "?token=untrusted", mirrorURL + "#fragment",
    mirrorURL.replace("https://", "https://user:password@"), mirrorURL.replace("gwdg.de/", "gwdg.de:444/"),
    "http://169.254.169.254/computeMetadata/v1/", "https://untrusted.test/then-back-to-canonical",
  ]) {
    let requests = 0, cancelled = false;
    await assert.rejects(downloadConfiguredGeofabrikDatasets({ datasetURLs: [latestURL], objectCache: () => cache,
      fetchImplementation: () => { requests++; return Promise.resolve(redirect(latestURL, target, () => { cancelled = true; })); } }), /redirect URL/u);
    assert.equal(requests, 1); assert.equal(cancelled, true);
  }
  let requests = 0;
  const swiss = "https://download.geofabrik.de/europe/switzerland-latest.osm.pbf";
  await assert.rejects(downloadConfiguredGeofabrikDatasets({ datasetURLs: [swiss], objectCache: () => cache,
    fetchImplementation: () => { requests++; return Promise.resolve(redirect(swiss, mirrorURL)); } }), /redirect URL/u);
  assert.equal(requests, 1);
});

void test("manual redirects retain Swiss dated URLs and reject loops, missing locations, and more than five hops", async () => {
  const cache = new ObjectDownloadCache(new MemoryObjectStore(), "test-osm");
  const swiss = "https://download.geofabrik.de/europe/switzerland-latest.osm.pbf";
  let requests = 0;
  const swissResult = await downloadConfiguredGeofabrikDatasets({ datasetURLs: [swiss], objectCache: () => cache,
    now: () => new Date("2026-10-04T12:00:00.000Z"), fetchImplementation: (input) => {
      requests++; const url = requestURL(input);
      return Promise.resolve(url === swiss ? redirect(swiss, "switzerland-261003.osm.pbf")
        : response("swiss fixture", url, { "last-modified": "Sun, 04 Oct 2026 00:31:22 GMT" }));
    } });
  assert.equal(swissResult[0]?.sourceURL, swiss); assert.equal(requests, 2);
  for (const kind of ["loop", "missing", "limit"] as const) {
    requests = 0;
    await assert.rejects(downloadConfiguredGeofabrikDatasets({ datasetURLs: [latestURL], objectCache: () => cache,
      fetchImplementation: (input) => {
        requests++;
        return Promise.resolve(redirect(requestURL(input), kind === "loop" ? latestURL : kind === "missing" ? undefined
          : `https://download.geofabrik.de/europe/germany-26100${requests}.osm.pbf`));
      } }), /redirect (loop|is missing)/u);
    assert.equal(requests, kind === "limit" ? 6 : 1);
  }
});

void test("object download cancels the response before consuming a rejected body", async () => {
  for (const headers of [{ "content-type": "text/html" }, { "content-length": "999" },
    { "last-modified": "invalid" }, { "last-modified": "Mon, 05 Oct 2026 00:00:00 GMT" }]) {
    const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm");
    let cancelled = false;
    const value = withURL(new Response(new ReadableStream({ cancel() { cancelled = true; } }), {
      headers: { "content-type": "application/octet-stream", "last-modified": "Sun, 04 Oct 2026 00:13:57 GMT", ...headers },
    }), latestURL);
    await assert.rejects(downloadConfiguredGeofabrikDatasets({ datasetURLs: [latestURL], objectCache: () => cache,
      now: () => new Date("2026-10-04T12:00:00.000Z"), maximumDatasetBytes: 100,
      fetchImplementation: () => Promise.resolve(value) }));
    assert.equal(cancelled, true); assert.equal(store.objects.size, 0);
  }
});

function requestURL(input: Parameters<typeof fetch>[0]): string {
  return input instanceof URL ? input.href : typeof input === "string" ? input : input.url;
}

function withURL(value: Response, url: string): Response {
  Object.defineProperty(value, "url", { value: url }); return value;
}
function redirect(url: string, target?: string, onCancel?: () => void): Response {
  return withURL(new Response(new ReadableStream({ cancel() { onCancel?.(); } }), {
    status: 307, headers: target === undefined ? {} : { location: target },
  }), url);
}

function response(
  body: string,
  url: string,
  headers: Readonly<Record<string, string>> = {},
): Response {
  const result = new Response(body, {
    status: 200,
    headers: { "content-type": "application/octet-stream", ...headers },
  });
  Object.defineProperty(result, "url", { value: url });
  return result;
}
