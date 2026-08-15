import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { downloadLatestBundesnetzagenturDataset } from "../../src/providers/bundesnetzagentur/dataset-downloader.js";

const pageURL =
  "https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenkarte/start.html";
const oldDatasetURL =
  "https://data.bundesnetzagentur.de/Bundesnetzagentur/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenregister_BNetzA_2026-06-01.csv";
const currentDatasetURL =
  "https://data.bundesnetzagentur.de/Bundesnetzagentur/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenregister_BNetzA_2026-07-28.csv";

void test("discovers, validates, hashes, and cleans up the latest official dataset", async () => {
  const requested: string[] = [];
  const fetchImplementation: typeof fetch = (input) => {
    const url = requestURL(input);
    requested.push(url);
    if (url === pageURL) {
      return Promise.resolve(
        response(
          `<a href="${oldDatasetURL}">old</a><a href="${currentDatasetURL}">current</a>`,
          pageURL,
          "text/html; charset=utf-8",
        ),
      );
    }
    if (url === currentDatasetURL) {
      return Promise.resolve(
        response("header\nrecord\n", currentDatasetURL, "text/csv", {
          etag: '"dataset-version"',
          "last-modified": "Tue, 28 Jul 2026 00:00:00 GMT",
        }),
      );
    }
    return Promise.resolve(response("not found", url, "text/plain", {}, 404));
  };

  const artifact = await downloadLatestBundesnetzagenturDataset({
    fetchImplementation,
    now: () => new Date("2026-08-15T12:00:00.000Z"),
  });
  assert.deepEqual(requested, [pageURL, currentDatasetURL]);
  assert.equal(artifact.observedAt, "2026-07-28T00:00:00.000Z");
  assert.equal(artifact.fetchedAt, "2026-08-15T12:00:00.000Z");
  assert.equal(artifact.etag, '"dataset-version"');
  assert.equal(
    artifact.sha256,
    "c6b6848e3f5a79e7d698eb8229845574b616c238124487c1c968fbc05d7fb47e",
  );
  assert.equal(await readFile(artifact.filePath, "utf8"), "header\nrecord\n");

  await artifact.cleanup();
  await assert.rejects(readFile(artifact.filePath), /ENOENT/u);
});

void test("rejects a dataset link outside the strict official allowlist", async () => {
  const fetchImplementation: typeof fetch = () =>
    Promise.resolve(
      response(
        '<a href="https://example.com/Ladesaeulenregister_BNetzA_2026-07-28.csv">bad</a>',
        pageURL,
        "text/html",
      ),
    );

  await assert.rejects(
    downloadLatestBundesnetzagenturDataset({ fetchImplementation }),
    /contains no approved/u,
  );
});

void test("rejects oversized datasets before creating a usable artifact", async () => {
  const fetchImplementation: typeof fetch = (input) => {
    const url = requestURL(input);
    return Promise.resolve(
      url === pageURL
        ? response(`<a href="${currentDatasetURL}">current</a>`, pageURL, "text/html")
        : response("too large", currentDatasetURL, "text/csv", {
            "content-length": "9",
          }),
    );
  };

  await assert.rejects(
    downloadLatestBundesnetzagenturDataset({
      fetchImplementation,
      maximumDatasetBytes: 8,
    }),
    /exceeds 8 bytes/u,
  );
});

void test("rejects an unexpected content type", async () => {
  const fetchImplementation: typeof fetch = (input) => {
    const url = requestURL(input);
    return Promise.resolve(
      url === pageURL
        ? response(`<a href="${currentDatasetURL}">current</a>`, pageURL, "text/html")
        : response("<html>error</html>", currentDatasetURL, "text/html"),
    );
  };

  await assert.rejects(
    downloadLatestBundesnetzagenturDataset({ fetchImplementation }),
    /unexpected content type/u,
  );
});

function response(
  body: string,
  url: string,
  contentType: string,
  headers: Readonly<Record<string, string>> = {},
  status = 200,
): Response {
  const result = new Response(body, {
    status,
    headers: { "content-type": contentType, ...headers },
  });
  Object.defineProperty(result, "url", { value: url });
  return result;
}

function requestURL(input: string | URL | Request): string {
  if (typeof input === "string") {
    return input;
  }
  return input instanceof URL ? input.href : input.url;
}
