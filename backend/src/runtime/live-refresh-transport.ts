import { HTTPRefreshSignal, type LiveRefreshSignaling } from "../application/candidate-availability.js";
import type { DeploymentRuntime, RuntimeEnvironment } from "./deployment-runtime.js";

export async function liveRefreshTransport(runtime: DeploymentRuntime, environment: RuntimeEnvironment = process.env): Promise<{
  readonly signal: LiveRefreshSignaling;
  readonly close: () => Promise<void>;
}> {
  const expected = runtime === "cloud-run" ? "cloud-tasks" : "vm-http";
  if ((environment.LIVE_REFRESH_TRANSPORT ?? expected) !== expected) {
    throw new Error("LIVE_REFRESH_TRANSPORT must match the selected deployment runtime.");
  }
  if (runtime === "vm") return {
    signal: new HTTPRefreshSignal(environment.LIVE_REFRESH_URL ?? "http://worker:8091/refresh", environment.LIVE_REFRESH_TOKEN ?? ""),
    close: () => Promise.resolve(),
  };
  // Keep the cloud SDK out of the default VM startup path.
  const { CloudTasksRefreshSignal, cloudLiveRefreshConfiguration } = await import("../application/cloud-tasks-refresh-signal.js");
  const signal = new CloudTasksRefreshSignal(cloudLiveRefreshConfiguration(environment));
  return { signal, close: () => signal.close() };
}
