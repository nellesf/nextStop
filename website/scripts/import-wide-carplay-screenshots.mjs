import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readCarPlayResultScreenshots } from "./import-result-screenshots.mjs";

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const files = ["carplay-results.png", "carplay-result-actions.png", "carplay-charging-places.png"];
const normalize = (text) => text.toLowerCase().replace(/\s+/g, " ").trim();

// Recovery is deliberately scoped to the completed CarPlay sequence followed
// by the observed iPhone Maps introduction timeout. It does not turn a failed
// six-screen run into a passing test or a complete result capture.
export async function importWideCarPlayScreenshots(directory, expectedCommit, archive,
  output = fileURLToPath(new URL("../public/screenshots/carplay-wide/", import.meta.url))) {
  const runBytes = await readFile(join(directory, "run-evidence.json"));
  const artifactBytes = await readFile(join(directory, "artifact-evidence.json"));
  const logBytes = await readFile(join(directory, "capture-run.log"));
  const run = JSON.parse(runBytes);
  const artifact = JSON.parse(artifactBytes);
  const log = logBytes.toString();
  assert.equal(run.status, "completed");
  assert.equal(run.conclusion, "failure");
  assert.equal(artifact.workflow_run.id, run.id);
  assert.equal(artifact.workflow_run.head_sha, run.head_sha);
  assert.equal(artifact.name, "carplay-captures");
  assert.equal(`sha256:${sha256(await readFile(archive))}`, artifact.digest,
    "The archive must match GitHub's artifact digest.");
  const original = (file) => execFileSync("unzip", ["-p", archive, file], { maxBuffer: 20 * 1024 * 1024 });
  const json = (file) => JSON.parse(original(file));
  const source = json("capture-source-base.json");
  const preflight = json("preflight.json");
  const fixture = json("website-capture-fixture.json");
  assert.equal(source.appCommit, expectedCommit);
  assert.equal(source.harnessCommit, run.head_sha);
  assert.equal(source.runURL, run.html_url);
  assert.deepEqual(source.carplayDisplay, { variant: "wide", width: 1920, height: 720, scale: 3 });
  assert.deepEqual(preflight.carplayDisplay, source.carplayDisplay);
  assert.equal(preflight.configuration.runSubmitted, true);
  assert.equal(preflight.configuration.runtimeScale, 3);
  assert.deepEqual(preflight.configuration.framebufferSize, [1920, 720]);
  assert.match(log, /RuntimeError: Native iphone-restaurant-place\.png did not show/);
  assert.match(log, /maps may show local ads based/);
  const phonePhase = log.indexOf("Hosted capture phase: {'action': 'activate-app'");
  assert.ok(phonePhase > 0, "The runner must have advanced beyond all CarPlay phases.");

  const staging = await mkdtemp(join(tmpdir(), "nextstop-wide-import-"));
  try {
    await mkdir(join(staging, "evidence"));
    const evidence = [];
    const preserve = async (file, bytes) => {
      await writeFile(join(staging, "evidence", file), bytes);
      evidence.push({ file: `evidence/${file}`, sha256: sha256(bytes) });
    };
    await preserve("run-evidence.json", runBytes);
    await preserve("artifact-evidence.json", artifactBytes);
    await preserve("capture-run.log", logBytes);
    for (const file of ["capture-source-base.json", "preflight.json", "website-capture-fixture.json"]) {
      await preserve(file, original(file));
    }
    const screenshots = [];
    for (const file of files) {
      const phaseFile = `phase-${file.replace(".png", ".json")}`;
      const phase = json(phaseFile);
      const ocrFile = file.replace(".png", ".ocr.json");
      const ocr = json(ocrFile);
      assert.equal(phase.file, file);
      assert.equal(phase.display, "external");
      assert.equal(phase.ownerApp, "nextStop");
      const text = normalize(ocr.text.map((row) => row.text).join(" "));
      assert.ok(phase.expected.length > 0);
      for (const expected of phase.expected) assert.ok(text.includes(normalize(expected)));
      const captureLines = log.split("\n").filter((line) => line.includes("'screenshot', '--display=external'")
        && line.endsWith(`'CarPlay-Captures/${file}']`));
      assert.equal(captureLines.length, 1, "Expect one final screenshot invocation per image.");
      assert.ok(log.indexOf(captureLines[0]) < phonePhase);
      const capturedAt = captureLines[0].match(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z/)?.[0];
      assert.ok(Number.isFinite(Date.parse(capturedAt)));
      const bytes = original(file);
      await writeFile(join(staging, file), bytes);
      await preserve(phaseFile, original(phaseFile));
      await preserve(ocrFile, original(ocrFile));
      screenshots.push({ file, display: "external", ownerApp: "nextStop", width: 1920, height: 720,
        capturedAt, timestampSource: "GitHub log timestamp of the final native screenshot invocation",
        sha256: sha256(bytes) });
    }
    const provenance = {
      ...source,
      captureScope: "carplay-results-only",
      runEvidence: run,
      artifactEvidence: artifact,
      hostedTestPassed: false,
      failure: { phase: "iphone-restaurant-place",
        reason: "After the completed CarPlay sequence, the iPhone Apple Maps introduction exceeded its capture deadline. The hosted test was terminated; no passing test summary or complete six-screen manifest exists." },
      data: "Example EVSE counts and power at live MapKit places; unchanged main app routing, filtering and presentation.",
      fixtureSnapshotScope: "The unchanged fixture snapshot was saved during the later iPhone sequence. Its renderedResults field describes the iPhone calculation (89/90 km). The earlier CarPlay calculation displays 89/92 km, as recorded in the original CarPlay PNG and its separate OCR evidence.",
      fixture,
      limitations: [...fixture.captureLimitations,
        "Only the three completed CarPlay views are imported from this failed overall run. Earlier iPhone originals remain on the website.",
        "The wide Simulator's native sidebar does not show time or connection/battery indicators in these captures."],
      processing: "Original PNG bytes extracted from the GitHub-digest-verified artifact without pixel modifications",
      evidence, screenshots,
    };
    await writeFile(join(staging, "carplay-result-provenance.json"), `${JSON.stringify(provenance, null, 2)}\n`);
    await readCarPlayResultScreenshots(staging, expectedCommit);
    await cp(staging, output, { recursive: true });
    return screenshots.length;
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [directory, expectedCommit, archive, output] = process.argv.slice(2);
  assert.ok(directory && expectedCommit && archive,
    "Usage: node website/scripts/import-wide-carplay-screenshots.mjs <artifact directory> <full main SHA> <original artifact ZIP> [output directory]");
  console.log(`Imported ${await importWideCarPlayScreenshots(directory, expectedCommit, archive, output)} original wide CarPlay screenshots.`);
}
