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

const routes = [
  { pathname: "/", locale: "de", output: "index.html" },
  { pathname: "/en/", locale: "en", output: "en/index.html" },
];
for (const route of routes) {
  const response = await worker.fetch(
    new Request(`https://nextstop.tech${route.pathname}`, {
      headers: { accept: "text/html" },
    }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
  if (!response.ok) {
    throw new Error(`Static rendering ${route.pathname} failed with HTTP ${response.status}.`);
  }
  const html = await response.text();
  const requiredSections = ["hero-title", "journey-title", "profil", "losfahren", "stopp"];
  if (!requiredSections.every((id) => html.includes(`id="${id}"`)) ||
      !html.includes(`<html lang="${route.locale}">`)) {
    throw new Error(`Static rendering did not contain the expected ${route.locale} landing page.`);
  }
  if (html.includes("/_next/image?")) {
    throw new Error("Static rendering still depends on the Next.js image endpoint.");
  }
  const output = new URL(route.output, staticOutput);
  await mkdir(new URL("./", output), { recursive: true });
  await writeFile(output, html, "utf8");
}
console.log("German and English static exports written to firebase-public/.");
