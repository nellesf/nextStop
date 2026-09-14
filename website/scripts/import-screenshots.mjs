import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

const [directory, expectedCommit] = process.argv.slice(2);
assert.ok(directory && /^[0-9a-f]{40}$/.test(expectedCommit ?? ""),
  "Usage: node scripts/import-screenshots.mjs <ios-ui-attachments directory> <full main SHA>");

const source = JSON.parse(await readFile(join(directory, "capture-source.json"), "utf8"));
assert.equal(source.appCommit, expectedCommit, "The capture must use the requested main commit.");
assert.match(source.runURL, /^https:\/\/github\.com\/nellesf\/nextStop\/actions\/runs\/\d+$/);
const manifest = JSON.parse(await readFile(join(directory, "manifest.json"), "utf8"));
const test = manifest.find((entry) =>
  entry.testIdentifier === "ProfileEditorUITests/testWebsiteScreenshots()");
assert.ok(test, "The artifact must contain the website capture test.");

const captures = await Promise.all([
  "iphone-profiles", "iphone-profile-editor", "iphone-profile-filters",
].map(async (name) => {
  const matching = test.attachments.filter((attachment) =>
    attachment.suggestedHumanReadableName.startsWith(`website-${name}_`));
  assert.equal(matching.length, 1, `Expected one capture for ${name}.`);
  const attachment = matching[0];
  assert.equal(attachment.isAssociatedWithFailure, false);
  assert.equal(basename(attachment.exportedFileName), attachment.exportedFileName);
  const bytes = await readFile(join(directory, attachment.exportedFileName));
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  return {
    bytes,
    file: `${name}.png`,
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20),
    sha256: createHash("sha256").update(bytes).digest("hex"),
    capturedAt: new Date(attachment.timestamp * 1000).toISOString(),
    attachment: attachment.exportedFileName,
    device: attachment.deviceName,
  };
}));

const output = new URL("../public/screenshots/", import.meta.url);
await mkdir(output, { recursive: true });
for (const capture of captures) {
  await writeFile(new URL(capture.file, output), capture.bytes);
}
await writeFile(new URL("provenance.json", output), `${JSON.stringify({
  ...source,
  processing: "Original XCTest PNG files, copied without pixel modifications",
  screenshots: captures.map((capture) => ({
    file: capture.file,
    width: capture.width,
    height: capture.height,
    sha256: capture.sha256,
    capturedAt: capture.capturedAt,
    attachment: capture.attachment,
    device: capture.device,
  })),
}, null, 2)}\n`);
console.log(`Imported ${captures.length} original screenshots from main ${expectedCommit}.`);
