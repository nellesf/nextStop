import { cp, mkdir, rm, writeFile } from "node:fs/promises";

const clientBuild = new URL("../dist/client/", import.meta.url);
const staticOutput = new URL("../firebase-public/", import.meta.url);

await rm(staticOutput, { recursive: true, force: true });
await mkdir(staticOutput, { recursive: true });
await cp(clientBuild, staticOutput, { recursive: true });
await Promise.all([
  rm(new URL(".assetsignore", staticOutput), { force: true }),
  rm(new URL(".vite/", staticOutput), { recursive: true, force: true }),
  rm(new URL("_headers", staticOutput), { force: true }),
  rm(new URL("vinext-client-entry-manifest.json", staticOutput), { force: true }),
]);

const workerUrl = new URL("../dist/server/index.js", import.meta.url);
workerUrl.searchParams.set("firebase-export", `${Date.now()}`);
const { default: worker } = await import(workerUrl.href);

const response = await worker.fetch(
  new Request("https://nextstop.tech/", {
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

if (!response.ok) {
  throw new Error(`Static rendering failed with HTTP ${response.status}.`);
}

const html = await response.text();
if (!html.includes("Hunger auf der Strecke?")) {
  throw new Error("Static rendering did not contain the expected landing page.");
}
if (html.includes("/_next/image?")) {
  throw new Error("Static rendering still depends on the Next.js image endpoint.");
}

await writeFile(new URL("index.html", staticOutput), html, "utf8");
console.log("Firebase static export written to firebase-public/.");
