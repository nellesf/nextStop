export type DeploymentRuntime = "vm" | "cloud-run";
export type RuntimeEnvironment = Readonly<Record<string, string | undefined>>;

/** VM is the default until the operator selects a named Cloud Run environment. */
export function deploymentRuntime(environment: RuntimeEnvironment = process.env): DeploymentRuntime {
  const value = environment.NEXTSTOP_RUNTIME ?? "vm";
  if (value !== "vm" && value !== "cloud-run") throw new Error("NEXTSTOP_RUNTIME must be vm or cloud-run.");
  if (value === "cloud-run" && environment.NEXTSTOP_ENVIRONMENT !== "staging" &&
      environment.NEXTSTOP_ENVIRONMENT !== "production") {
    throw new Error("Cloud Run requires an explicit staging or production environment.");
  }
  return value;
}

export function httpShutdownGraceMilliseconds(runtime: DeploymentRuntime): number {
  return runtime === "cloud-run" ? 8_000 : 30_000;
}
