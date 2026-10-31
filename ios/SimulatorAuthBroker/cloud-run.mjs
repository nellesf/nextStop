import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { cloudRunBrokerOrigin } from "./configuration.mjs";

const execute = promisify(execFile);

/** Uses the operator's existing Google login; no signing key is copied to the developer machine. */
export async function mintCloudRunToken(configuration, dependencies = {}) {
  const origin = cloudRunBrokerOrigin(configuration);
  const run = dependencies.execute ?? execute;
  const transport = dependencies.fetch ?? fetch;
  try {
    const options = { encoding: "utf8", maxBuffer: 16 * 1024, timeout: 20_000 };
    const { stdout: identity } = await run("gcloud", ["auth", "print-identity-token"], options);
    const response = await transport(`${origin}/token`, { method: "POST", redirect: "error",
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
    throw new Error("Cloud broker unavailable; verify Google login and Cloud Run invocation access.");
  }
}
