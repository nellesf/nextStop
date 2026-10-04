import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

import { brokerConfiguration } from "./configuration.mjs";

void test("named presets pair the intended cloud minter with a distinct fixed port", () => {
  assert.deepEqual(brokerConfiguration({ NEXTSTOP_BACKEND_ENVIRONMENT: "staging" }), {
    name: "staging", port: 8765, project: "nextstop-tech-testing", zone: "europe-west3-a",
    instance: "nextstop-backend", mode: "cloud-run", region: "europe-west1", service: "nextstop-broker",
    remoteMintCommand: "sudo /usr/local/sbin/nextstop-mint-simulator-token",
  });
  assert.deepEqual(brokerConfiguration({}), {
    name: "production", port: 8766, project: "nextstop-tech-staging", zone: "europe-west3-a",
    instance: "nextstop-backend", mode: "remote",
    remoteMintCommand: "sudo /usr/local/sbin/nextstop-mint-simulator-token",
  });
});

void test("only named staging can explicitly retain the VM broker during migration", () => {
  assert.equal(brokerConfiguration({ NEXTSTOP_BACKEND_ENVIRONMENT: "staging", NEXTSTOP_STAGING_HOSTING: "vm" }).mode, "remote");
  assert.throws(() => brokerConfiguration({ NEXTSTOP_BACKEND_ENVIRONMENT: "production", NEXTSTOP_STAGING_HOSTING: "vm" }));
  assert.throws(() => brokerConfiguration({ NEXTSTOP_BACKEND_ENVIRONMENT: "staging", NEXTSTOP_STAGING_HOSTING: "invalid" }));
});

void test("named presets reject crossed credentials, ports and legacy modes", () => {
  for (const changes of [
    { NEXTSTOP_GCP_PROJECT: "nextstop-tech-staging" },
    { NEXTSTOP_GCP_INSTANCE: "nextstop-worker" },
    { NEXTSTOP_SIMULATOR_AUTH_BROKER_PORT: "8766" },
    { NEXTSTOP_SIMULATOR_AUTH_MODE: "local" },
    { NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND: "true" },
  ]) {
    assert.throws(() => brokerConfiguration({ NEXTSTOP_BACKEND_ENVIRONMENT: "staging", ...changes }));
  }
  assert.throws(() => brokerConfiguration({
    NEXTSTOP_BACKEND_ENVIRONMENT: "production", NEXTSTOP_GCP_PROJECT: "nextstop-tech-testing",
  }));
  assert.throws(() => brokerConfiguration({ NEXTSTOP_BACKEND_ENVIRONMENT: "misspelled" }));
});

void test("local mode and old deployments require explicit selection", () => {
  const local = brokerConfiguration({ NEXTSTOP_SIMULATOR_AUTH_MODE: "local" });
  assert.equal(local.port, 9482);
  assert.equal(local.mode, "local");
  const legacy = brokerConfiguration({
    NEXTSTOP_SIMULATOR_AUTH_MODE: "staging", NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND: "true",
  });
  assert.equal(legacy.port, 9482);
  assert.equal(legacy.project, "nextstop-tech-staging");
  assert.equal(legacy.instance, "nextstop-backend");
  assert.match(legacy.remoteMintCommand, /docker compose/u);
  assert.throws(() => brokerConfiguration({ NEXTSTOP_SIMULATOR_AUTH_LEGACY_COMMAND: "true" }));
});

void test("every checked-in scheme archives Release and environment launch variables are only simulator presets", async () => {
  for (const name of ["NextStopApp", "NextStop-Staging", "NextStop-ProductionTest", "NextStop-Release"]) {
    const source = await readFile(new URL(`../NextStop.xcodeproj/xcshareddata/xcschemes/${name}.xcscheme`, import.meta.url), "utf8");
    assert.match(source, /<ArchiveAction\s+buildConfiguration\s*=\s*"Release"/u);
    if (name === "NextStop-Staging") assert.match(source, /value="staging"/u);
    if (name === "NextStop-ProductionTest") assert.match(source, /value="production"/u);
    if (name === "NextStop-Release") assert.match(source, /<LaunchAction\s+buildConfiguration="Release"/u);
  }
});
