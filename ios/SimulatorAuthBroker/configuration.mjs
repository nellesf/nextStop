const presets = {
  staging: { project: "nextstop-tech-testing", instance: "nextstop-backend", port: 8765 },
  production: { project: "nextstop-tech-staging", instance: "nextstop-backend", port: 8766 },
};

export function brokerConfiguration(environment = process.env) {
  const selected = environment.NEXTSTOP_BACKEND_ENVIRONMENT;
  const oldMode = environment.NEXTSTOP_SIMULATOR_AUTH_MODE;
  if (selected !== undefined && !Object.hasOwn(presets, selected)) {
    throw new Error("NEXTSTOP_BACKEND_ENVIRONMENT must be staging or production.");
  }
  if (oldMode !== undefined && oldMode !== "staging" && oldMode !== "local") {
    throw new Error("NEXTSTOP_SIMULATOR_AUTH_MODE must be staging or local.");
  }
  if (selected !== undefined && oldMode !== undefined) {
    throw new Error("Use a named backend preset or a legacy/local mode, not both.");
  }
  const name = selected ?? (oldMode === undefined ? "production" : oldMode);
  const legacy = selected === undefined && oldMode === "staging";
  // The explicit compatibility mode retains the historical host. Its Google
  // project ID contains "staging", but the existing service is now production.
  const preset = legacy ? presets.production : presets[name];
  const port = Number(environment.NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT
    ?? (legacy || name === "local" ? 9482 : preset.port));
  if (!Number.isSafeInteger(port) || port < 1024 || port > 65535) {
    throw new Error("NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT must be an integer from 1024 through 65535.");
  }
  if (!legacy && name !== "local" && port !== preset.port) {
    throw new Error("Named backend presets use fixed paired broker ports.");
  }
  const project = identifier(environment.NEXTSTOP_GCP_PROJECT ?? preset?.project ?? "local");
  const zone = identifier(environment.NEXTSTOP_GCP_ZONE ?? "europe-west3-a");
  const instance = identifier(environment.NEXTSTOP_GCP_INSTANCE ?? preset?.instance ?? "local");
  if (!legacy && name !== "local" && (project !== preset.project || instance !== preset.instance || zone !== "europe-west3-a")) {
    throw new Error("Named backend presets cannot target a different cloud environment.");
  }
  const legacyCommand = environment.NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND;
  if (legacyCommand !== undefined && legacyCommand !== "true" && legacyCommand !== "false") {
    throw new Error("NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND must be true or false.");
  }
  if (legacyCommand === "true" && !legacy) {
    throw new Error("The old compose minter is permitted only in explicit legacy staging mode.");
  }
  const hosting = environment.NEXTSTOP_STAGING_HOSTING ?? "cloud-run";
  if (!["cloud-run", "vm"].includes(hosting) ||
      (environment.NEXTSTOP_STAGING_HOSTING !== undefined && name !== "staging")) {
    throw new Error("NEXTSTOP_STAGING_HOSTING is only valid for the named staging preset.");
  }
  const cloud = !legacy && name === "staging" && hosting === "cloud-run";
  return {
    name, port, project, zone, instance, mode: name === "local" ? "local" : cloud ? "cloud-run" : "remote",
    ...(cloud ? { region: "europe-west1", service: "nextstop-broker" } : {}),
    remoteMintCommand: legacyCommand === "true"
      ? "cd /opt/nextstop/current && sudo docker compose --project-name gcp-vm --env-file /etc/nextstop/backend.env -f deploy/gcp-vm/compose.yaml run --rm --no-deps -T simulator-token-mint"
      : "sudo /usr/local/sbin/nextstop-mint-simulator-token",
  };
}

function identifier(value) {
  if (!/^[a-z][a-z0-9-]{0,62}$/u.test(value)) throw new Error("Invalid cloud target identifier.");
  return value;
}
