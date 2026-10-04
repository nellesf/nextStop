import { createHash } from "node:crypto";
import { CloudTasksClient, type protos } from "@google-cloud/tasks";
import type { LiveRefreshSignaling } from "./candidate-availability.js";
import type { RuntimeEnvironment } from "../runtime/deployment-runtime.js";

export const cloudLiveRefreshLimits = {
  enqueueMilliseconds: 1_000,
  taskWindowMilliseconds: 60_000,
  dispatchSeconds: 300,
} as const;

export interface CloudLiveRefreshConfiguration {
  readonly queue: string;
  readonly target: string;
  readonly serviceAccount: string;
  readonly audience: string;
}

export function cloudLiveRefreshConfiguration(environment: RuntimeEnvironment): CloudLiveRefreshConfiguration {
  const queue = environment.LIVE_REFRESH_TASK_QUEUE ?? "";
  const serviceAccount = environment.LIVE_REFRESH_TASK_SERVICE_ACCOUNT ?? "";
  const match = /^projects\/([a-z][a-z0-9-]{4,61}[a-z0-9])\/locations\/[a-z]+-[a-z]+[0-9]\/queues\/[A-Za-z0-9_-]{1,100}$/u.exec(queue);
  const account = /^[a-z][a-z0-9-]{4,28}[a-z0-9]@([a-z][a-z0-9-]{4,61}[a-z0-9])\.iam\.gserviceaccount\.com$/u.exec(serviceAccount);
  if (match === null || account === null || match[1] !== account[1]) {
    throw new Error("Live task queue and invoker service account must be configured in the same project.");
  }
  let url: URL;
  try { url = new URL(environment.LIVE_REFRESH_TASK_TARGET ?? ""); }
  catch { throw new Error("LIVE_REFRESH_TASK_TARGET must be the fixed HTTPS Cloud Run refresh endpoint."); }
  if (url.protocol !== "https:" || !/^[a-z0-9][a-z0-9.-]*\.run\.app$/u.test(url.hostname) ||
      url.username !== "" || url.password !== "" || url.port !== "" ||
      url.pathname !== "/refresh" || url.search !== "" || url.hash !== "") {
    throw new Error("LIVE_REFRESH_TASK_TARGET must be the fixed HTTPS Cloud Run refresh endpoint.");
  }
  return { queue, target: url.toString(), serviceAccount, audience: url.origin };
}

type TaskCreation = Promise<unknown> & { cancel?: () => void };
export interface LiveTaskCreating {
  createTask(request: protos.google.cloud.tasks.v2.ICreateTaskRequest,
    options: { readonly timeout: number; readonly retry: null }): TaskCreation;
  close(): Promise<void>;
}

/** Only the fixed public provider identifier enters the durable queue. ADC supplies short-lived credentials. */
export class CloudTasksRefreshSignal implements LiveRefreshSignaling {
  constructor(private readonly configuration: CloudLiveRefreshConfiguration,
    private readonly client: LiveTaskCreating = new CloudTasksClient(), private readonly now: () => number = Date.now) {}

  async signal(): Promise<boolean> {
    const window = Math.floor(this.now() / cloudLiveRefreshLimits.taskWindowMilliseconds);
    const id = createHash("sha256").update(`ich_tanke_strom\0${this.configuration.queue}\0${window}`).digest("hex");
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const operation = this.client.createTask({
        parent: this.configuration.queue,
        responseView: "BASIC",
        task: {
          name: `${this.configuration.queue}/tasks/${id}`,
          dispatchDeadline: { seconds: cloudLiveRefreshLimits.dispatchSeconds },
          httpRequest: {
            httpMethod: "POST", url: this.configuration.target,
            headers: { "Content-Type": "application/json" },
            body: Buffer.from('{"providerId":"ich_tanke_strom"}'),
            oidcToken: { serviceAccountEmail: this.configuration.serviceAccount, audience: this.configuration.audience },
          },
        },
      }, { timeout: cloudLiveRefreshLimits.enqueueMilliseconds, retry: null });
      // The outer deadline also covers lazy ADC/client initialization. A late,
      // ambiguous enqueue is safe because its deterministic task name is reused.
      await Promise.race([operation, new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => {
          try { operation.cancel?.(); } catch { /* Cancellation is best effort. */ }
          reject(new Error("Live task enqueue timed out."));
        }, cloudLiveRefreshLimits.enqueueMilliseconds);
      })]);
      return true;
    } catch (error) {
      // gRPC ALREADY_EXISTS includes tasks completed recently. Repeated calls
      // must neither create another job nor reveal task metadata to the app.
      return typeof error === "object" && error !== null && "code" in error && error.code === 6;
    } finally { if (timer !== undefined) clearTimeout(timer); }
  }

  async close(): Promise<void> { await this.client.close(); }
}
