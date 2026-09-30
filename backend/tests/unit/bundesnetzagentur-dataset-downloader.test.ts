import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";

import { downloadLatestBundesnetzagenturDataset } from "../../src/providers/bundesnetzagentur/dataset-downloader.js";

const pageURL =
  "https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenkarte/start.html";
const oldDatasetURL =
  "https://data.bundesnetzagentur.de/Bundesnetzagentur/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenregister_BNetzA_2026-06-01.csv";
const currentDatasetURL =
  "https://data.bundesnetzagentur.de/Bundesnetzagentur/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenregister_BNetzA_2026-07-28.csv";

void test("discovers, validates, hashes, and cleans up the latest official dataset", async (t) => {
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
    cacheDirectory: await temporaryCache(t),
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

void test("rejects a dataset link outside the strict official allowlist", async (t) => {
  const fetchImplementation: typeof fetch = () =>
    Promise.resolve(
      response(
        '<a href="https://example.com/Ladesaeulenregister_BNetzA_2026-07-28.csv">bad</a>',
        pageURL,
        "text/html",
      ),
    );

  await assert.rejects(
    downloadLatestBundesnetzagenturDataset({ fetchImplementation, cacheDirectory: await temporaryCache(t) }),
    /contains no approved/u,
  );
});

void test("rejects oversized datasets before creating a usable artifact", async (t) => {
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
      cacheDirectory: await temporaryCache(t),
    }),
    /exceeds 8 bytes/u,
  );
});

void test("rejects an unexpected content type", async (t) => {
  const fetchImplementation: typeof fetch = (input) => {
    const url = requestURL(input);
    return Promise.resolve(
      url === pageURL
        ? response(`<a href="${currentDatasetURL}">current</a>`, pageURL, "text/html")
        : response("<html>error</html>", currentDatasetURL, "text/html"),
    );
  };

  await assert.rejects(
    downloadLatestBundesnetzagenturDataset({ fetchImplementation, cacheDirectory: await temporaryCache(t) }),
    /unexpected content type/u,
  );
});

void test("reuses a validated cached CSV after 304 and keeps each artifact private", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory,
    now: () => new Date("2026-08-15T12:00:00.000Z"),
    fetchImplementation: csvFetcher("first\n", '"first"'),
  });
  await first.cleanup();
  const second = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory,
    now: () => new Date("2026-08-16T12:00:00.000Z"),
    fetchImplementation: (input, init) => {
      if (requestURL(input) === pageURL) return Promise.resolve(datasetPage());
      const headers = new Headers(init?.headers);
      assert.equal(headers.get("if-none-match"), '"first"');
      assert.equal(headers.get("if-modified-since"), "Tue, 28 Jul 2026 00:00:00 GMT");
      return Promise.resolve(response(null, currentDatasetURL, "text/csv", {}, 304));
    },
  });
  assert.equal(second.sha256, first.sha256);
  assert.equal(second.observedAt, first.observedAt);
  assert.equal(second.fetchedAt, "2026-08-16T12:00:00.000Z");
  assert.equal(await readFile(second.filePath, "utf8"), "first\n");
  assert.notEqual(second.filePath, first.filePath);
  await second.cleanup();
});

void test("replaces changed CSV bytes while bounding the cache to one dataset", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory, fetchImplementation: csvFetcher("first\n", '"first"'),
  });
  const second = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory, fetchImplementation: csvFetcher("second\n", '"second"'),
  });
  assert.notEqual(second.sha256, first.sha256);
  assert.equal(await readFile(first.filePath, "utf8"), "first\n");
  assert.equal(await readFile(second.filePath, "utf8"), "second\n");
  assert.deepEqual((await readdir(join(cacheDirectory, "bundesnetzagentur"))).sort(),
    ["body", "metadata.json"]);
  await first.cleanup();
  await second.cleanup();
});

void test("does not reuse a prior URL's validators when discovery selects a newer CSV", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory, fetchImplementation: csvFetcher("old\n", '"old"', oldDatasetURL),
  });
  await first.cleanup();
  const second = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory,
    fetchImplementation: (input, init) => {
      if (requestURL(input) === pageURL) return Promise.resolve(datasetPage());
      assert.equal(new Headers(init?.headers).get("if-none-match"), null);
      return Promise.resolve(response("new\n", currentDatasetURL, "text/csv"));
    },
  });
  assert.equal(second.observedAt, "2026-07-28T00:00:00.000Z");
  await second.cleanup();
});

void test("a rejected or interrupted download does not replace the validated cache", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory, fetchImplementation: csvFetcher("good\n", '"good"'),
  });
  await first.cleanup();
  for (const failure of ["oversized", "interrupted", "redirect"] as const) {
    await assert.rejects(downloadLatestBundesnetzagenturDataset({
      cacheDirectory,
      maximumDatasetBytes: 10,
      fetchImplementation: (input) => {
        if (requestURL(input) === pageURL) return Promise.resolve(datasetPage());
        if (failure === "oversized") {
          return Promise.resolve(response("this body is too long", currentDatasetURL, "text/csv"));
        }
        if (failure === "redirect") {
          return Promise.resolve(response(null, oldDatasetURL, "text/csv", {}, 304));
        }
        const stream = new ReadableStream<Uint8Array>({
          start(controller) { controller.error(new Error("connection interrupted")); },
        });
        return Promise.resolve(response(stream, currentDatasetURL, "text/csv"));
      },
    }));
    assert.equal(await readFile(join(cacheDirectory, "bundesnetzagentur", "body"), "utf8"), "good\n");
  }
});

void test("corrupt cache bytes discard validators and an unsolicited 304 cannot succeed", async (t) => {
  const cacheDirectory = await temporaryCache(t);
  const first = await downloadLatestBundesnetzagenturDataset({
    cacheDirectory, fetchImplementation: csvFetcher("good\n", '"good"'),
  });
  await first.cleanup();
  await writeFile(join(cacheDirectory, "bundesnetzagentur", "body"), "bad!\n");
  await assert.rejects(downloadLatestBundesnetzagenturDataset({
    cacheDirectory,
    fetchImplementation: (input, init) => {
      if (requestURL(input) === pageURL) return Promise.resolve(datasetPage());
      assert.equal(new Headers(init?.headers).get("if-none-match"), null);
      return Promise.resolve(response(null, currentDatasetURL, "text/csv", {}, 304));
    },
  }), /HTTP 304/u);
});

async function temporaryCache(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "nextstop-bnetza-cache-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function datasetPage(url = currentDatasetURL): Response {
  return response(`<a href="${url}">current</a>`, pageURL, "text/html");
}

function csvFetcher(body: string, etag: string, url = currentDatasetURL): typeof fetch {
  return (input) => Promise.resolve(requestURL(input) === pageURL ? datasetPage(url) :
    response(body, url, "text/csv", { etag, "last-modified": "Tue, 28 Jul 2026 00:00:00 GMT" }));
}

function response(
  body: ConstructorParameters<typeof Response>[0],
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
