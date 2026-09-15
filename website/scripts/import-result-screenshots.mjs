import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const resultCaptureSpecs = [
  { file: "carplay-results.png", display: "external", ownerApp: "nextStop", width: 800, height: 480 },
  { file: "carplay-result-actions.png", display: "external", ownerApp: "nextStop", width: 800, height: 480 },
  { file: "carplay-charging-places.png", display: "external", ownerApp: "nextStop", width: 800, height: 480 },
  { file: "carplay-restaurant-place.png", display: "external", ownerApp: "Apple Maps", width: 800, height: 480 },
  { file: "carplay-charging-place.png", display: "external", ownerApp: "Apple Maps", width: 800, height: 480 },
  { file: "iphone-results.png", display: "internal", ownerApp: "nextStop", width: 1206, height: 2622 },
  { file: "iphone-restaurant-place.png", display: "internal", ownerApp: "Apple Maps", width: 1206, height: 2622 },
  { file: "iphone-charging-place.png", display: "internal", ownerApp: "Apple Maps", width: 1206, height: 2622 },
];

const repository = fileURLToPath(new URL("../../", import.meta.url));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const git = (...arguments_) => execFileSync("git", arguments_, { cwd: repository });

export async function readResultScreenshots(
  directory,
  expectedCommit,
  manifestName = "result-capture-source.json",
) {
  assert.match(expectedCommit ?? "", /^[0-9a-f]{40}$/, "Supply the full main app commit.");
  const source = JSON.parse(await readFile(join(directory, manifestName), "utf8"));
  assert.equal(source.appCommit, expectedCommit, "The capture must use the requested main commit.");
  const expectedTree = git("rev-parse", `${expectedCommit}:ios/NextStopApp`).toString().trim();
  assert.equal(source.appTree, expectedTree, "The app source tree must match the recorded main commit.");
  assert.match(source.harnessCommit ?? "", /^[0-9a-f]{40}$/);
  const buildCommit = source.buildHarnessCommit ?? source.harnessCommit;
  assert.match(buildCommit, /^[0-9a-f]{40}$/);
  assert.match(source.profileFixtureSHA256 ?? "", /^[0-9a-f]{64}$/);
  const fixtureSource = git("show", `${buildCommit}:ios/NextStopAppTests/ProfileRepositoryTests.swift`);
  assert.equal(sha256(fixtureSource), source.profileFixtureSHA256,
    "The fixture source hash must match the recorded build harness commit.");
  assert.match(source.runURL ?? "", /^https:\/\/github\.com\/nellesf\/nextStop\/actions\/runs\/\d+$/);
  assert.equal(source.appliedEntitlements?.["com.apple.developer.carplay-charging"], true);
  assert.ok(source.fixture && typeof source.fixture === "object" && !Array.isArray(source.fixture)
    && Object.keys(source.fixture).length > 0, "MapKit places and example data require fixture provenance.");
  assert.ok(typeof source.data === "string" && source.data.trim(), "Describe the capture data.");
  assert.ok(Array.isArray(source.screenshots));
  assert.deepEqual(source.screenshots.map((capture) => capture.file).sort(),
    resultCaptureSpecs.map((capture) => capture.file).sort(), "Import exactly the eight expected result screens.");

  const captures = await Promise.all(resultCaptureSpecs.map(async (expected) => {
    const capture = source.screenshots.find((item) => item.file === expected.file);
    for (const field of ["display", "ownerApp", "width", "height"]) {
      assert.equal(capture[field], expected[field], `${expected.file}: incorrect ${field}.`);
    }
    assert.match(capture.sha256 ?? "", /^[0-9a-f]{64}$/);
    assert.ok(Number.isFinite(Date.parse(capture.capturedAt)), `${expected.file}: invalid capture time.`);
    const bytes = await readFile(join(directory, expected.file));
    assert.ok(bytes.length >= 33, `${expected.file}: truncated PNG.`);
    assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
    assert.equal(bytes.toString("ascii", 12, 16), "IHDR");
    assert.equal(bytes.readUInt32BE(16), expected.width);
    assert.equal(bytes.readUInt32BE(20), expected.height);
    assert.equal(sha256(bytes), capture.sha256, `${expected.file}: original image hash mismatch.`);
    return { bytes, metadata: capture };
  }));
  return { source, captures };
}

export async function importResultScreenshots(
  directory,
  expectedCommit,
  output = fileURLToPath(new URL("../public/screenshots/", import.meta.url)),
) {
  // Finish every provenance and image check before touching website assets.
  const { source, captures } = await readResultScreenshots(directory, expectedCommit);
  await mkdir(output, { recursive: true });
  for (const capture of captures) {
    await writeFile(join(output, capture.metadata.file), capture.bytes);
  }
  await writeFile(join(output, "result-provenance.json"), `${JSON.stringify({
    ...source,
    processing: "Original Simulator internal and external display PNG files, copied without pixel modifications",
    screenshots: captures.map((capture) => capture.metadata),
  }, null, 2)}\n`);
  return captures.length;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [directory, expectedCommit] = process.argv.slice(2);
  assert.ok(directory && expectedCommit,
    "Usage: node website/scripts/import-result-screenshots.mjs <capture directory> <full main SHA>");
  const count = await importResultScreenshots(directory, expectedCommit);
  console.log(`Imported ${count} original result screenshots from main ${expectedCommit}.`);
}
