import { AccessTokenCodec } from "./api/access-token.js";
import { createSimulatorTokenApp } from "./api/simulator-token-app.js";
import { deploymentRuntime } from "./runtime/deployment-runtime.js";
import { installHTTPShutdown } from "./runtime/graceful-shutdown.js";

if (deploymentRuntime() !== "cloud-run") throw new Error("Token service requires the staging Cloud Run runtime.");
const key = process.env.SEARCH_ACCESS_TOKEN_SIGNING_KEY;
if (key === undefined) throw new Error("Missing Simulator token signing key.");
const app = createSimulatorTokenApp(new AccessTokenCodec(key));
installHTTPShutdown(app, { graceMilliseconds: 8_000 });
const port = Number(process.env.PORT ?? 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid PORT.");
await app.listen({ host: "0.0.0.0", port });
