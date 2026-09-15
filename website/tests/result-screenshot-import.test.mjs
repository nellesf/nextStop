import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { importResultScreenshots, resultCaptureSpecs } from "../scripts/import-result-screenshots.mjs";

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "nextstop-result-import-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const originals = new URL("../public/screenshots/", import.meta.url);
  const source = JSON.parse(await readFile(new URL("carplay-provenance.json", originals), "utf8"));
  source.fixture = { testOnly: "Existing screenshot bytes stand in for the input files in importer tests." };
  source.screenshots = await Promise.all(resultCaptureSpecs.map(async (spec) => {
    const original = spec.display === "external" ? "carplay-profiles.png" : "iphone-profiles.png";
    const bytes = await readFile(new URL(original, originals));
    await writeFile(join(directory, spec.file), bytes);
    return {
      ...spec,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      capturedAt: "2026-09-15T00:00:00Z",
    };
  }));
  const writeManifest = () => writeFile(join(directory, "result-capture-source.json"), JSON.stringify(source));
  await writeManifest();
  return { directory, output: join(directory, "output"), source, writeManifest };
}

test("imports the complete checked set byte-for-byte and preserves fixture provenance", async (t) => {
  const { directory, output, source } = await fixture(t);
  assert.equal(await importResultScreenshots(directory, source.appCommit, output), 6);
  for (const capture of source.screenshots) {
    assert.deepEqual(await readFile(join(output, capture.file)), await readFile(join(directory, capture.file)));
  }
  const result = JSON.parse(await readFile(join(output, "result-provenance.json"), "utf8"));
  assert.deepEqual(result.fixture, source.fixture);
  assert.deepEqual(result.screenshots, source.screenshots);
});

test("rejects incomplete, modified or misattributed sets before writing assets", async (t) => {
  const mutations = {
    "missing image": (source) => source.screenshots.pop(),
    "duplicate image": (source) => source.screenshots.push(source.screenshots[0]),
    "unsupported CarPlay place image": (source) => source.screenshots.push({
      ...source.screenshots[0], file: "carplay-restaurant-place.png", ownerApp: "Apple Maps",
    }),
    "wrong source tree": (source) => { source.appTree = "0".repeat(40); },
    "wrong fixture hash": (source) => { source.profileFixtureSHA256 = "0".repeat(64); },
    "wrong owner": (source) => { source.screenshots.at(-1).ownerApp = "nextStop"; },
    "wrong display": (source) => { source.screenshots.at(-1).display = "external"; },
    "wrong dimensions": (source) => { source.screenshots.at(-1).width = 800; },
    "wrong image hash": (source) => { source.screenshots.at(-1).sha256 = "0".repeat(64); },
    "missing place provenance": (source) => { delete source.fixture; },
  };
  for (const [name, mutate] of Object.entries(mutations)) {
    await t.test(name, async (subtest) => {
      const { directory, output, source, writeManifest } = await fixture(subtest);
      mutate(source);
      await writeManifest();
      await assert.rejects(importResultScreenshots(directory, source.appCommit, output));
      await assert.rejects(access(output), { code: "ENOENT" });
    });
  }
});
