import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execute = promisify(execFile);

/** Uses the operator's existing Google login; no signing key is copied to the developer machine. */
export async function mintCloudRunToken(configuration, dependencies = {}) {
  if (configuration.name !== "staging" || configuration.project !== "nextstop-tech-testing" ||
      configuration.region !== "europe-west1" || configuration.service !== "nextstop-broker") {
    throw new Error("Cloud token minting is restricted to the staging broker.");
  }
  const run = dependencies.execute ?? execute;
  const transport = dependencies.fetch ?? fetch;
  try {
    const options = { encoding: "utf8", maxBuffer: 16 * 1024, timeout: 20_000 };
    const { stdout: endpoint } = await run("gcloud", ["run", "services", "describe", configuration.service,
      `--project=${configuration.project}`, `--region=${configuration.region}`, "--format=value(status.url)"], options);
    const url = new URL(endpoint.trim());
    if (url.protocol !== "https:" || !/^nextstop-broker-[a-z0-9.-]+\.run\.app$/u.test(url.hostname) ||
        url.port !== "" || url.username !== "" || url.password !== "" || url.pathname !== "/" ||
        url.search !== "" || url.hash !== "") throw new Error("Invalid broker origin.");
    const { stdout: identity } = await run("gcloud", ["auth", "print-identity-token"], options);
    const response = await transport(`${url.origin}/token`, { method: "POST", redirect: "error",
      headers: { Authorization: `Bearer ${identity.trim()}` }, signal: AbortSignal.timeout(20_000) });
    if (!response.ok || response.body === null) throw new Error("Broker unavailable.");
    const reader = response.body.getReader();
    let body = "";
    try {
      for (;;) {
        const item = await reader.read();
        if (item.done) break;
        body += Buffer.from(item.value).toString("utf8");
        if (Buffer.byteLength(body) > 8_192) throw new Error("Invalid broker reply.");
      }
    } finally { await reader.cancel(); }
    return body;
  } catch {
    // gcloud errors can include subprocess output; never print credentials.
    throw new Error("Cloud staging broker unavailable; verify Google login and Cloud Run invocation access.");
  }
}
