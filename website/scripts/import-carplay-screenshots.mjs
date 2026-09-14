import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const [directory, expectedCommit] = process.argv.slice(2);
assert.ok(directory && /^[0-9a-f]{40}$/.test(expectedCommit ?? ""),
  "Usage: node scripts/import-carplay-screenshots.mjs <CarPlay-Captures directory> <full main SHA>");

const source = JSON.parse(await readFile(join(directory, "capture-source.json"), "utf8"));
assert.equal(source.appCommit, expectedCommit, "The capture must use the requested main commit.");
assert.match(source.harnessCommit, /^[0-9a-f]{40}$/);
assert.match(source.runURL, /^https:\/\/github\.com\/nellesf\/nextStop\/actions\/runs\/\d+$/);
assert.ok(Array.isArray(source.screenshots));

const captures = await Promise.all([
  "carplay-profiles.png", "carplay-ride-summary.png",
].map(async (file) => {
  const matching = source.screenshots.filter((capture) => capture.file === file);
  assert.equal(matching.length, 1, `Expected one verified capture for ${file}.`);
  const capture = matching[0];
  const bytes = await readFile(join(directory, file));
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  assert.equal(bytes.readUInt32BE(16), capture.width);
  assert.equal(bytes.readUInt32BE(20), capture.height);
  assert.ok(capture.width > capture.height && capture.height >= 400,
    "The website uses full landscape CarPlay display captures.");
  assert.equal(createHash("sha256").update(bytes).digest("hex"), capture.sha256);
  assert.ok(Number.isFinite(Date.parse(capture.capturedAt)));
  return { bytes, metadata: capture };
}));

// Verify the entire set before changing any website assets.
const output = new URL("../public/screenshots/", import.meta.url);
await mkdir(output, { recursive: true });
for (const capture of captures) {
  await writeFile(new URL(capture.metadata.file, output), capture.bytes);
}
await writeFile(new URL("carplay-provenance.json", output), `${JSON.stringify({
  ...source,
  processing: "Original Simulator external-display PNG files, copied without pixel modifications",
  screenshots: captures.map((capture) => capture.metadata),
}, null, 2)}\n`);
console.log(`Imported ${captures.length} original CarPlay screenshots from main ${expectedCommit}.`);
