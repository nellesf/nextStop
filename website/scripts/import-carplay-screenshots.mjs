import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repository = fileURLToPath(new URL("../../", import.meta.url));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const git = (...args) => execFileSync("git", args, { cwd: repository });
const files = ["carplay-profiles.png", "carplay-ride-summary.png"];

async function validateScreenshots(directory, expectedCommit, source) {
  assert.match(expectedCommit ?? "", /^[0-9a-f]{40}$/);
  assert.equal(source.appCommit, expectedCommit, "The capture must use the requested main commit.");
  assert.equal(source.appTree, git("rev-parse", `${expectedCommit}:ios/NextStopApp`).toString().trim());
  assert.match(source.harnessCommit, /^[0-9a-f]{40}$/);
  const buildCommit = source.buildHarnessCommit ?? source.harnessCommit;
  assert.match(buildCommit, /^[0-9a-f]{40}$/);
  assert.equal(source.profileFixtureSHA256, sha256(git("show", `${buildCommit}:ios/NextStopAppTests/ProfileRepositoryTests.swift`)));
  assert.match(source.runURL, /^https:\/\/github\.com\/nellesf\/nextStop\/actions\/runs\/\d+$/);
  assert.equal(source.appliedEntitlements?.["com.apple.developer.carplay-charging"], true);
  const variants = {
    default: { variant: "default", width: 800, height: 480, scale: 2 },
    wide: { variant: "wide", width: 1920, height: 720, scale: 3 },
  };
  const display = source.carplayDisplay ?? variants.default;
  assert.ok(Object.hasOwn(variants, display.variant));
  assert.deepEqual(display, variants[display.variant]);
  if (display.variant === "wide") {
    const summary = source.profileTestSummary;
    assert.ok(summary, "Wide profile captures require the successful hosted-test summary.");
    assert.equal(summary.totalTestCount, 1);
    assert.equal(summary.passedTests, 1);
    assert.equal(summary.failedTests, 0);
    assert.equal(summary.skippedTests, 0);
    const proof = source.displayProof;
    assert.equal(proof?.runURL, source.runURL);
    assert.equal(proof.harnessCommit, source.harnessCommit);
    assert.equal(proof.runSubmitted, true);
    assert.deepEqual(proof.readback, { width: 1920, height: 720, scale: 3 });
    assert.equal(proof.runtimeScale, 3);
    assert.deepEqual(proof.framebufferSize, [1920, 720]);
  }
  assert.ok(Array.isArray(source.screenshots));
  assert.deepEqual(source.screenshots.map((capture) => capture.file).sort(), [...files].sort());

  const captures = await Promise.all(files.map(async (file) => {
    const matching = source.screenshots.filter((capture) => capture.file === file);
    assert.equal(matching.length, 1, `Expected one verified capture for ${file}.`);
    const capture = matching[0];
    const bytes = await readFile(join(directory, file));
    assert.ok(bytes.length >= 33);
    assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
    assert.equal(bytes.toString("ascii", 12, 16), "IHDR");
    assert.equal(capture.width, display.width);
    assert.equal(capture.height, display.height);
    assert.equal(bytes.readUInt32BE(16), capture.width);
    assert.equal(bytes.readUInt32BE(20), capture.height);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), capture.sha256);
    assert.ok(Number.isFinite(Date.parse(capture.capturedAt)));
    return { bytes, metadata: capture };
  }));
  return { source, captures };
}

export async function readCarPlayScreenshots(directory, expectedCommit, manifestName = "carplay-provenance.json") {
  const source = JSON.parse(await readFile(join(directory, manifestName), "utf8"));
  return validateScreenshots(directory, expectedCommit, source);
}

export async function importCarPlayScreenshots(directory, expectedCommit,
  output = fileURLToPath(new URL("../public/screenshots/", import.meta.url))) {
  const source = JSON.parse(await readFile(join(directory, "capture-source.json"), "utf8"));
  if (source.carplayDisplay?.variant === "wide") {
    const preflight = JSON.parse(await readFile(join(directory, "preflight.json"), "utf8"));
    assert.deepEqual(preflight.carplayDisplay, source.carplayDisplay);
    source.displayProof = preflight.configuration;
    source.profileTestSummary = JSON.parse(await readFile(join(directory, "profile-test-summary.json"), "utf8"));
  }
  const { captures } = await validateScreenshots(directory, expectedCommit, source);
  // Verify the entire set before changing any website assets.
  await mkdir(output, { recursive: true });
  for (const capture of captures) {
    await writeFile(join(output, capture.metadata.file), capture.bytes);
  }
  await writeFile(join(output, "carplay-provenance.json"), `${JSON.stringify({
    ...source,
    processing: "Original Simulator external-display PNG files, copied without pixel modifications",
    screenshots: captures.map((capture) => capture.metadata),
  }, null, 2)}\n`);
  return captures.length;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [directory, expectedCommit, output] = process.argv.slice(2);
  assert.ok(directory && expectedCommit,
    "Usage: node website/scripts/import-carplay-screenshots.mjs <artifact directory> <full main SHA> [output directory]");
  console.log(`Imported ${await importCarPlayScreenshots(directory, expectedCommit, output)} original CarPlay screenshots from main ${expectedCommit}.`);
}
