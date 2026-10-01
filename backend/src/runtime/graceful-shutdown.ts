import type { FastifyInstance } from "fastify";

export interface ShutdownOptions {
  readonly graceMilliseconds?: number;
  readonly onForcedExit?: () => void;
}

/** Fastify stops admission and drains HTTP before its onClose pool hooks run. */
export async function drainHTTPApplication(app: Pick<FastifyInstance, "close">, options: ShutdownOptions = {}): Promise<void> {
  const timeout = setTimeout(() => {
    if (options.onForcedExit !== undefined) options.onForcedExit();
    else process.exit(1);
  }, options.graceMilliseconds ?? 30_000);
  timeout.unref();
  try {
    await app.close();
  } finally {
    clearTimeout(timeout);
  }
}

export function installHTTPShutdown(app: FastifyInstance): void {
  let stopping = false;
  const stop = (): void => {
    if (stopping) return;
    stopping = true;
    void drainHTTPApplication(app).catch(() => {
      process.stderr.write('{"event":"http_shutdown_failed"}\n');
      process.exit(1);
    });
  };
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
}
