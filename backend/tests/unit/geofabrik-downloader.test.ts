import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

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
