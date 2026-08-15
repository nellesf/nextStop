import assert from "node:assert/strict";
import test from "node:test";

import { downloadIchTankeStromFeed } from "../../src/providers/ich-tanke-strom/feed-client.js";

const liveURL =
  "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/status/oicp/ch.bfe.ladestellen-elektromobilitaet.json";

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

function response(body: string, headers: Readonly<Record<string, string>> = {}): Response {
  const result = new Response(body, {
    headers: { "content-type": "application/json", ...headers },
  });
  Object.defineProperty(result, "url", { value: liveURL });
  return result;
}
