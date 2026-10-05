export type DeploymentRuntime = "vm" | "cloud-run";
export type RuntimeEnvironment = Readonly<Record<string, string | undefined>>;

/** Explicit staging opt-in. Existing VM and production deployments keep their defaults. */
export function deploymentRuntime(environment: RuntimeEnvironment = process.env): DeploymentRuntime {
  const value = environment.NEXTSTOP_RUNTIME ?? "vm";
  if (value !== "vm" && value !== "cloud-run") throw new Error("NEXTSTOP_RUNTIME must be vm or cloud-run.");
  if (value === "cloud-run" && environment.NEXTSTOP_ENVIRONMENT !== "staging") {
    throw new Error("Cloud Run runtime is currently enabled only for staging.");
  }
  return value;
}

export function httpShutdownGraceMilliseconds(runtime: DeploymentRuntime): number {
  return runtime === "cloud-run" ? 8_000 : 30_000;
}
