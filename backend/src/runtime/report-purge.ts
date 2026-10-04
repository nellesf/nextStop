import { userErrorReportLimits, type UserErrorReportRepository } from "../application/user-error-reports.js";
import type { DeploymentRuntime } from "./deployment-runtime.js";

interface ReportPurgeDependencies {
  readonly now?: () => Date;
  readonly failure?: () => void;
  readonly schedule?: (work: () => void, milliseconds: number) => (() => void);
}

/** Cloud deployments require the independent hourly purge job under ADR 0017. */
export async function startReportPurge(
  repository: Pick<UserErrorReportRepository, "purge"> | undefined,
  runtime: DeploymentRuntime,
  dependencies: ReportPurgeDependencies = {},
): Promise<() => void> {
  if (repository === undefined || runtime === "cloud-run") return () => {};
  const now = dependencies.now ?? (() => new Date());
  await repository.purge(now());
  let active = false;
  return (dependencies.schedule ?? scheduleInterval)(() => {
    if (active) return;
    active = true;
    void repository.purge(now()).catch(() => dependencies.failure?.()).finally(() => { active = false; });
  }, userErrorReportLimits.purgeIntervalMilliseconds);
}

function scheduleInterval(work: () => void, milliseconds: number): () => void {
  const timer = setInterval(work, milliseconds);
  timer.unref();
  return () => { clearInterval(timer); };
}
