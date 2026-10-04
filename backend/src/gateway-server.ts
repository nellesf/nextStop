import { createCloudGateway } from "./api/cloud-gateway.js";
import { CloudIdentityTokens } from "./runtime/cloud-identity-tokens.js";
import { deploymentRuntime } from "./runtime/deployment-runtime.js";
import { installHTTPShutdown } from "./runtime/graceful-shutdown.js";

if (deploymentRuntime() !== "cloud-run") throw new Error("Gateway requires the staging Cloud Run runtime.");
const api = process.env.BACKEND_API_ORIGIN;
const auth = process.env.BACKEND_AUTH_ORIGIN;
const apiAudience = process.env.BACKEND_API_AUDIENCE;
const authAudience = process.env.BACKEND_AUTH_AUDIENCE;
if (api === undefined || auth === undefined || apiAudience === undefined || authAudience === undefined) {
  throw new Error("Private service origins and audiences are required.");
}
const tokens = new CloudIdentityTokens();
const app = createCloudGateway({ origins: { api, auth }, audiences: { api: apiAudience, auth: authAudience },
  identityToken: (origin) => tokens.get(origin) });
installHTTPShutdown(app, { graceMilliseconds: 8_000 });
const port = Number(process.env.PORT ?? 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid PORT.");
await app.listen({ host: "0.0.0.0", port });
