import { cloudLiveRefreshConfiguration } from "./application/cloud-tasks-refresh-signal.js";
import { CloudLiveRefresh, createCloudLiveRefreshApp, GoogleTaskAuthenticator } from "./jobs/cloud-live-refresh.js";
import { refreshSwissLiveAvailability } from "./jobs/refresh-providers.js";
import { createDatabasePool } from "./persistence/database.js";
import { PostgresLiveRefreshControl } from "./persistence/live-refresh-control.js";
import { deploymentRuntime, httpShutdownGraceMilliseconds } from "./runtime/deployment-runtime.js";
import { installHTTPShutdown } from "./runtime/graceful-shutdown.js";

// Deployed as a separate IAM-private service, never as a public-origin sidecar.
const runtime = deploymentRuntime();
if (runtime !== "cloud-run") throw new Error("The task live worker requires the staging Cloud Run runtime.");
const configuration = cloudLiveRefreshConfiguration(process.env);
const databaseURL = process.env.DATABASE_URL;
if (databaseURL === undefined) throw new Error("DATABASE_URL is required.");
const port = Number(process.env.PORT ?? "8080");
if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("PORT is invalid.");
const pool = createDatabasePool(databaseURL, {
  applicationName: "nextstop-live-task", maxConnections: 2,
  queryTimeoutMilliseconds: 35_000, statementTimeoutMilliseconds: 30_000,
});
const controlPool = createDatabasePool(databaseURL, {
  applicationName: "nextstop-live-task-control", maxConnections: 1,
  queryTimeoutMilliseconds: 5_000, statementTimeoutMilliseconds: 3_000,
});
const controller = new CloudLiveRefresh(new PostgresLiveRefreshControl(controlPool),
  (lease) => refreshSwissLiveAvailability(pool, { liveRefreshLease: lease, inlineLiveRetention: false }));
const app = createCloudLiveRefreshApp(controller, new GoogleTaskAuthenticator(configuration), () => {
  process.stderr.write('{"event":"live_task_refresh_failed"}\n');
});
app.addHook("onClose", async () => { await controlPool.end(); await pool.end(); });
installHTTPShutdown(app, { graceMilliseconds: httpShutdownGraceMilliseconds(runtime) });
await app.listen({ host: "0.0.0.0", port });
