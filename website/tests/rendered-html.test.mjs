import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { readResultScreenshots, resultCaptureSpecs } from "../scripts/import-result-screenshots.mjs";

async function render(pathname = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request(`https://nextstop.tech${pathname}`, {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the complete German nextStop landing page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<html lang="de">/i);
  assert.match(html, /<title>nextStop – Deine Pause\. Deine Entscheidung\.<\/title>/i);
  assert.match(html, /Dein Auto lädt\.<br\/><em>Du machst Pause\.<\/em>/);
  assert.match(html, /Lass dir nicht vom Auto vorschreiben, wann und wo du Pause machst/);
  assert.match(html, /eine gemeinsame Pause/);
  assert.match(html, /Ein Ladepunkt ist belegt, der andere defekt/);
  assert.match(html, /Restaurant oder Ladeanbieter desselben Pausenstopps/);
  assert.match(html, /Beide gehören zu deinem gewählten Pausenstopp/);
  assert.match(html, /Profile und Vorlieben/);
  assert.match(html, /Route nur für die Suche/);
  assert.doesNotMatch(html, /MapKit|geodesisch|Backend|Cloud-Sync|Analyse-SDK|App-Logs|im MVP|in Laufnähe/);
  assert.doesNotMatch(html, /food-node|charge-node|hero-result-card|Designvorschau · CarPlay/);
  assert.match(html, /Ein gemeinsamer Stopp zum Laden und Essen/);
  assert.deepEqual([...html.matchAll(/<li[^>]*id="(profil|losfahren|stopp)"/g)].map((match) => match[1]),
    ["profil", "losfahren", "stopp"]);
  const profile = html.indexOf('id="profil"');
  const drive = html.indexOf('id="losfahren"');
  const find = html.indexOf('id="stopp"');
  assert.ok(profile < drive && drive < find);
  for (const file of ["iphone-profile-editor.png", "iphone-profiles.png"]) {
    assert.ok(html.slice(profile, drive).includes(`src="/screenshots/${file}"`));
    assert.ok(!html.slice(find).includes(`src="/screenshots/${file}"`));
  }
  for (const file of ["carplay-profiles.png", "carplay-ride-summary.png"]) {
    assert.ok(html.slice(drive, find).includes(`src="/screenshots/${file}"`));
  }
  for (const { file } of resultCaptureSpecs) {
    assert.ok(html.slice(find).includes(`src="/screenshots/${file}"`));
  }
  for (const filename of [
    "iphone-profiles.png", "iphone-profile-editor.png",
    "carplay-profiles.png", "carplay-ride-summary.png",
  ]) {
    assert.ok(html.includes(`src="/screenshots/${filename}"`));
    assert.match(html, new RegExp(`<a[^>]+href="/screenshots/${filename}"[^>]+aria-label="[^"]*in Originalgröße öffnen"`));
  }
  assert.ok(!html.includes('src="/screenshots/iphone-profile-filters.png"'));
  assert.match(html, /© OpenStreetMap-Mitwirkende/);
  assert.match(html, /Angaben gemäß § 5 DDG und § 18 Abs\. 1 MStV/);
  assert.match(html, /Anonyme Platzhalter/);
  assert.match(html, /name@example\.invalid/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
});

test("uses unchanged original CarPlay captures of the same main app as the iPhone images", async () => {
  const directory = new URL("../public/screenshots/", import.meta.url);
  const iphone = JSON.parse(await readFile(new URL("provenance.json", directory), "utf8"));
  const carplay = JSON.parse(await readFile(new URL("carplay-provenance.json", directory), "utf8"));
  assert.equal(carplay.appCommit, iphone.appCommit);
  assert.equal(carplay.appTree, iphone.appTree);
  assert.equal(carplay.appliedEntitlements["com.apple.developer.carplay-charging"], true);
  assert.match(carplay.runURL, /^https:\/\/github\.com\/nellesf\/nextStop\/actions\/runs\/\d+$/);
  assert.deepEqual(carplay.screenshots.map((capture) => capture.file), [
    "carplay-profiles.png", "carplay-ride-summary.png",
  ]);
  for (const capture of carplay.screenshots) {
    const bytes = await readFile(new URL(capture.file, directory));
    assert.equal(createHash("sha256").update(bytes).digest("hex"), capture.sha256);
    assert.equal(bytes.readUInt32BE(16), capture.width);
    assert.equal(bytes.readUInt32BE(20), capture.height);
  }
});

test("keeps metadata, navigation, legal data, and source assets production-ready", async () => {
  const [page, layout, css, packageJson, imprint] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../content/imprint.ts", import.meta.url), "utf8"),
  ]);

  assert.match(layout, /metadataBase: new URL\("https:\/\/nextstop\.tech"\)/);
  assert.match(layout, /<html lang="de">/);
  assert.match(page, /aria-label="Hauptnavigation"/);
  assert.match(page, /href="#privacy"/);
  assert.match(page, /href="#impressum"/);
  assert.match(page, /image-note/);
  assert.match(css, /prefers-reduced-motion/);
  assert.doesNotMatch(page, /_sites-preview|SkeletonPreview/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(imprint, /placeholdersActive: true/);
  assert.match(imprint, /fullName: "VORNAME NACHNAME"/);
});

test("publishes result captures only with checked originals and accurate ownership", async () => {
  const directory = new URL("../public/screenshots/", import.meta.url);
  const html = await (await render()).text();
  assert.doesNotMatch(html, /carplay-(?:restaurant|charging)-place\.png/);
  try {
    await access(new URL("result-provenance.json", directory));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    for (const { file } of resultCaptureSpecs) {
      assert.ok(!html.includes(`src="/screenshots/${file}"`));
    }
    return;
  }
  const iphone = JSON.parse(await readFile(new URL("provenance.json", directory), "utf8"));
  await readResultScreenshots(fileURLToPath(directory), iphone.appCommit, "result-provenance.json");
  for (const { file, ownerApp } of resultCaptureSpecs) {
    const image = html.match(new RegExp(`<img[^>]+src="/screenshots/${file}"[^>]*>`));
    assert.ok(image, `${file} must appear after the reviewed result set is activated.`);
    assert.match(html, new RegExp(`<a[^>]+href="/screenshots/${file}"[^>]+aria-label="[^"]*in Originalgröße öffnen"`));
    if (ownerApp === "Apple Maps") assert.match(image[0], /alt="[^"]*Apple Maps/);
  }
  assert.match(html, /Ladepunktzahlen und Ladeleistungen in nextStop sind Beispielwerte/);
  assert.match(html, /Eine aktuelle Belegung wird in diesen Bildern nicht gezeigt/);
  assert.match(html, /Apple Maps zeigt seine eigenen Ortsangaben/);
});

test("exports a self-contained Firebase Hosting document", async () => {
  const html = await readFile(
    new URL("../firebase-public/index.html", import.meta.url),
    "utf8",
  );

  assert.match(html, /property="og:image" content="https:\/\/nextstop\.tech\/og\.png"/);
  assert.doesNotMatch(html, /\/_next\/image\?/);

  const localAssets = [
    ...html.matchAll(/(?:src|href)="(\/(?:_next|app-icon|og|screenshots\/)[^"?]*)/g),
  ].map((match) => match[1]);

  assert.ok(localAssets.length > 0);
  await Promise.all(
    [...new Set(localAssets)].map((asset) =>
      access(new URL(`../firebase-public${asset}`, import.meta.url)),
    ),
  );

  await assert.rejects(
    access(new URL("../firebase-public/.assetsignore", import.meta.url)),
  );
  await assert.rejects(
    access(new URL("../firebase-public/.vite/manifest.json", import.meta.url)),
  );
});
