import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";

import { downloadIchTankeStromFeed } from "../../src/providers/ich-tanke-strom/feed-client.js";

const liveURL =
  "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/status/oicp/ch.bfe.ladestellen-elektromobilitaet.json";
const staticURL = liveURL.replace("/status/", "/data/");

void test("accepts an official JSON feed with an authoritative observation time", async () => {
  const payload = '{"EVSEStatuses":[]}';
  const feed = await downloadIchTankeStromFeed("live", {
    fetchImplementation: () =>
      Promise.resolve(
        response(payload, {
          "last-modified": "Sat, 15 Aug 2026 12:00:00 GMT",
          etag: '"live-version"',
        }),
      ),
    now: () => new Date("2026-08-15T12:00:05.000Z"),
  });

  assert.deepEqual(feed.payload, { EVSEStatuses: [] });
  assert.equal(feed.observedAt, "2026-08-15T12:00:00.000Z");
  assert.equal(feed.fetchedAt, "2026-08-15T12:00:05.000Z");
  assert.equal(feed.etag, '"live-version"');
  assert.match(feed.sha256, /^[0-9a-f]{64}$/u);
});

void test("rejects missing Last-Modified rather than inventing live freshness", async () => {
  await assert.rejects(
    downloadIchTankeStromFeed("live", {
      fetchImplementation: () => Promise.resolve(response("{}")),
    }),
    /no valid Last-Modified/u,
  );
});

void test("rejects a decompressed body over the configured limit", async () => {
  await assert.rejects(
    downloadIchTankeStromFeed("live", {
      fetchImplementation: () =>
        Promise.resolve(
          response("12345", { "last-modified": "Sat, 15 Aug 2026 12:00:00 GMT" }),
        ),
      maximumBytes: 4,
    }),
    /exceeds 4 bytes/u,
  );
});

void test("static 304 preserves the source timestamp and hash while refreshing fetchedAt", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadIchTankeStromFeed("static", {
    cacheDirectory,
    now: () => new Date("2026-08-15T12:00:05.000Z"),
    fetchImplementation: () => Promise.resolve(staticResponse('{"EVSEData":[]}', '"static-v1"')),
  });
  const second = await downloadIchTankeStromFeed("static", {
    cacheDirectory,
    now: () => new Date("2026-08-16T12:00:05.000Z"),
    fetchImplementation: (_input, init) => {
      const headers = new Headers(init?.headers);
      assert.equal(headers.get("if-none-match"), '"static-v1"');
      assert.equal(headers.get("if-modified-since"), "Sat, 15 Aug 2026 12:00:00 GMT");
      return Promise.resolve(response(null, {}, staticURL, 304));
    },
  });
  assert.deepEqual(second.payload, first.payload);
  assert.equal(second.sha256, first.sha256);
  assert.equal(second.observedAt, first.observedAt);
  assert.equal(second.fetchedAt, "2026-08-16T12:00:05.000Z");
});

void test("changed static JSON replaces the cached body and validators", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadIchTankeStromFeed("static", {
    cacheDirectory,
    fetchImplementation: () => Promise.resolve(staticResponse('{"version":1}', '"v1"')),
  });
  const second = await downloadIchTankeStromFeed("static", {
    cacheDirectory,
    fetchImplementation: () => Promise.resolve(staticResponse('{"version":2}', '"v2"')),
  });
  assert.notEqual(second.sha256, first.sha256);
  assert.equal(second.etag, '"v2"');
  assert.deepEqual(second.payload, { version: 2 });
  assert.equal(await readFile(join(cacheDirectory, "ich-tanke-strom-static", "body"), "utf8"),
    '{"version":2}');
  assert.deepEqual((await readdir(join(cacheDirectory, "ich-tanke-strom-static"))).sort(),
    ["body", "metadata.json"]);
});

void test("invalid JSON, source timestamps, redirects, and oversize never poison the static cache", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  await downloadIchTankeStromFeed("static", {
    cacheDirectory,
    fetchImplementation: () => Promise.resolve(staticResponse('{"valid":true}', '"good"')),
  });
  const badResponses = [
    staticResponse("invalid JSON", '"bad"'),
    response("{}", {}, staticURL),
    response("{}", { "last-modified": "Sat, 15 Aug 2099 12:00:00 GMT" }, staticURL),
    response(null, {}, liveURL, 304),
    staticResponse('{"muchTooLong":true}', '"bad"'),
  ];
  for (const badResponse of badResponses) {
    await assert.rejects(downloadIchTankeStromFeed("static", {
      cacheDirectory,
      maximumBytes: 15,
      fetchImplementation: () => Promise.resolve(badResponse),
    }));
    assert.equal(await readFile(join(cacheDirectory, "ich-tanke-strom-static", "body"), "utf8"),
      '{"valid":true}');
  }
});

void test("live requests remain unconditional and cannot consume the static cache", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  await downloadIchTankeStromFeed("static", {
    cacheDirectory,
    fetchImplementation: () => Promise.resolve(staticResponse("{}", '"static"')),
  });
  await assert.rejects(downloadIchTankeStromFeed("live", {
    cacheDirectory,
    fetchImplementation: (_input, init) => {
      const headers = new Headers(init?.headers);
      assert.equal(headers.get("if-none-match"), null);
      assert.equal(headers.get("if-modified-since"), null);
      return Promise.resolve(response(null, {}, liveURL, 304));
    },
  }), /HTTP 304/u);
});

void test("a static 304 without a valid local cache is rejected", async (t) => {
  await assert.rejects(downloadIchTankeStromFeed("static", {
    cacheDirectory: await temporaryCache(t),
    fetchImplementation: () => Promise.resolve(response(null, {}, staticURL, 304)),
  }), /HTTP 304/u);
});

async function temporaryCache(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "nextstop-swiss-cache-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function staticResponse(body: string, etag: string): Response {
  return response(body, { "last-modified": "Sat, 15 Aug 2026 12:00:00 GMT", etag }, staticURL);
}

function response(
  body: string | null,
  headers: Readonly<Record<string, string>> = {},
  url = liveURL,
  status = 200,
): Response {
  const result = new Response(body, {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
  Object.defineProperty(result, "url", { value: url });
  return result;
}
