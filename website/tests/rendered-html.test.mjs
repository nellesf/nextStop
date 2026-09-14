import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

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
  assert.match(html, /<title>nextStop – Ladepause und Essenspause verbinden<\/title>/i);
  assert.match(html, /Hunger auf der Strecke\?/);
  assert.match(html, /Ein Stopp, der beides kann\./);
  assert.match(html, /Zwei sind frei\./);
  assert.match(html, /2 \/ 12 frei/);
  assert.match(html, /5 \/ 8 frei/);
  assert.match(html, /3 \/ 6 frei/);
  assert.match(html, /Auslastung ist eine Momentaufnahme, wird je nach verfügbarer Datenlage angezeigt/);
  assert.doesNotMatch(html, /Status unbekannt/);
  assert.match(html, /Profile und Vorlieben/);
  assert.match(html, /Route nur für die Suche/);
  assert.doesNotMatch(html, /Backend|Cloud-Sync|Analyse-SDK|App-Logs|im MVP/);
  assert.match(html, /Vorbereiten\.<br\/>Nur auf dem iPhone\./);
  assert.match(html, /vor der Fahrt ausschließlich auf dem iPhone ein/);
  assert.doesNotMatch(html, /Vorbereiten geht/);
  assert.match(html, /Designvorschau · CarPlay/);
  assert.match(html, /App-Aufnahme · Meine Profile/);
  assert.match(html, /App-Aufnahme · Profil bearbeiten/);
  assert.match(html, /echte Aufnahmen der unveröffentlichten App mit Beispielprofilen/);
  assert.doesNotMatch(html, /Designvorschau · (?:iPhone|Profil bearbeiten|Ergebnis auf dem iPhone)/);
  for (const filename of ["iphone-profiles.png", "iphone-profile-editor.png"]) {
    assert.ok(html.includes(`src="/screenshots/${filename}"`));
  }
  assert.ok(!html.includes('src="/screenshots/iphone-profile-filters.png"'));
  assert.match(html, /© OpenStreetMap-Mitwirkende/);
  assert.match(html, /Angaben gemäß § 5 DDG und § 18 Abs\. 1 MStV/);
  assert.match(html, /Anonyme Platzhalter/);
  assert.match(html, /name@example\.invalid/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
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
  assert.match(page, /mockup-disclaimer/);
  assert.match(css, /prefers-reduced-motion/);
  assert.doesNotMatch(page, /_sites-preview|SkeletonPreview/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(imprint, /placeholdersActive: true/);
  assert.match(imprint, /fullName: "VORNAME NACHNAME"/);
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
