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
  { file: "iphone-results.png", display: "internal", ownerApp: "nextStop", width: 1206, height: 2622 },
  { file: "iphone-restaurant-place.png", display: "internal", ownerApp: "Apple Maps", width: 1206, height: 2622 },
  { file: "iphone-charging-place.png", display: "internal", ownerApp: "Apple Maps", width: 1206, height: 2622 },
];

const repository = fileURLToPath(new URL("../../", import.meta.url));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const git = (...arguments_) => execFileSync("git", arguments_, { cwd: repository });

function captureSpecs(source) {
  // Older manifests predate display configuration and used the verified default.
  const display = source.carplayDisplay ?? { variant: "default", width: 800, height: 480, scale: 2 };
  const supported = {
    default: { variant: "default", width: 800, height: 480, scale: 2 },
    wide: { variant: "wide", width: 1920, height: 720, scale: 3 },
  };
  assert.ok(Object.hasOwn(supported, display.variant), "Unsupported CarPlay display variant.");
  assert.deepEqual(display, supported[display.variant], "CarPlay resolution and scale must match the selected variant.");
  return resultCaptureSpecs.map((spec) => spec.display === "external"
    ? { ...spec, width: display.width, height: display.height }
    : spec);
}

export async function readResultScreenshots(
  directory,
  expectedCommit,
  manifestName = "result-capture-source.json",
) {
  return readCheckedScreenshots(directory, expectedCommit, manifestName, "complete");
}

export async function readCarPlayResultScreenshots(
  directory,
  expectedCommit,
  manifestName = "carplay-result-provenance.json",
) {
  return readCheckedScreenshots(directory, expectedCommit, manifestName, "carplay-results-only");
}

async function readCheckedScreenshots(directory, expectedCommit, manifestName, scope) {
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
  let specs = captureSpecs(source);
  if (scope === "carplay-results-only") {
    assert.equal(source.captureScope, scope);
    assert.equal(source.runEvidence.conclusion, "failure");
    assert.equal(source.runEvidence.status, "completed");
    assert.equal(source.runEvidence.head_sha, source.harnessCommit);
    assert.equal(source.runEvidence.html_url, source.runURL);
    assert.equal(source.hostedTestPassed, false);
    assert.equal(source.failure.phase, "iphone-restaurant-place");
    assert.ok(source.failure.reason);
    assert.ok(source.evidence.length >= 6, "The scoped import must retain its native capture evidence.");
    for (const evidence of source.evidence) {
      assert.match(evidence.file, /^evidence\/[a-z0-9.-]+$/);
      assert.equal(sha256(await readFile(join(directory, evidence.file))), evidence.sha256);
    }
    const evidenceJSON = async (name) => JSON.parse(await readFile(join(directory, "evidence", name), "utf8"));
    assert.deepEqual(source.runEvidence, await evidenceJSON("run-evidence.json"));
    assert.deepEqual(source.artifactEvidence, await evidenceJSON("artifact-evidence.json"));
    assert.deepEqual(source.fixture, await evidenceJSON("website-capture-fixture.json"));
    assert.equal(source.artifactEvidence.workflow_run.id, source.runEvidence.id);
    assert.equal(source.artifactEvidence.workflow_run.head_sha, source.harnessCommit);
    assert.ok(source.fixtureSnapshotScope, "Explain the scope of the retained fixture snapshot.");
    specs = specs.filter((spec) => spec.display === "external");
  }
  assert.deepEqual(source.screenshots.map((capture) => capture.file).sort(),
    specs.map((capture) => capture.file).sort(), "Import exactly the expected screens for this capture scope.");

  const captures = await Promise.all(specs.map(async (expected) => {
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
  const [directory, expectedCommit, output] = process.argv.slice(2);
  assert.ok(directory && expectedCommit,
    "Usage: node website/scripts/import-result-screenshots.mjs <capture directory> <full main SHA> [output directory]");
  const count = await importResultScreenshots(directory, expectedCommit, output);
  console.log(`Imported ${count} original result screenshots from main ${expectedCommit}.`);
}
