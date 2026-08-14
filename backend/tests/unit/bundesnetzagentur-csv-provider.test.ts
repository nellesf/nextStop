import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";

import type {
  NormalizedLocationObservation,
  QuarantinedProviderRecord,
} from "../../src/domain/normalized-charging.js";
import { readBundesnetzagenturCSV } from "../../src/providers/bundesnetzagentur/csv-provider.js";

const fixturePath = fileURLToPath(
  new URL("../fixtures/bundesnetzagentur/sample.csv", import.meta.url),
);
const options = {
  filePath: fixturePath,
  observedAt: "2026-07-07T00:00:00.000Z",
  fetchedAt: "2026-08-14T07:00:00.000Z",
} as const;

void test("maps numbered charging-point blocks as EVSEs, not their connectors", async () => {
  const result = await collectFixture();

  assert.equal(result.observations.length, 3);
  assert.equal(result.quarantines.length, 1);

  const location = result.observations[0]?.location;
  assert.ok(location);
  assert.equal(location.name, "Autohof Nord");
  assert.equal(location.chargingPoints.length, 2);
  assert.equal(location.chargingPoints[0]?.connectors.length, 2);
  assert.equal(location.chargingPoints[0]?.maximumPowerKW, 149);
  assert.equal(location.chargingPoints[0]?.canonicalEVSEIdentity, "DEABCE1001");
  assert.equal(location.chargingPoints[0]?.identityDecision, "exact");
  assert.equal(location.chargingPoints[1]?.canonicalEVSEIdentity, undefined);
  assert.equal(location.chargingPoints[1]?.identityDecision, "unresolved");
  assert.equal(location.chargingPoints[1]?.availability.state, "unknown");
  assert.equal(location.chargingPoints[1]?.availability.isLive, false);
});

void test("keeps maintenance records normalized but inactive", async () => {
  const result = await collectFixture();
  const maintenance = result.observations.find(
    (observation) => observation.location.sourceReference.sourceRecordId === "1000003",
  );

  assert.ok(maintenance);
  assert.equal(maintenance.location.active, false);
});

void test("quarantines implausible provider coordinates without retaining raw values", async () => {
  const result = await collectFixture();

  assert.deepEqual(result.quarantines, [
    {
      rowNumber: 7,
      sourceRecordId: "1000004",
      issueCodes: ["implausible_german_coordinate"],
    },
  ]);
  assert.doesNotMatch(JSON.stringify(result.quarantines), /Fehler GmbH/u);
});

void test("creates stable source, location, point, and content identities", async () => {
  const first = await collectFixture();
  const second = await collectFixture();

  assert.deepEqual(first, second);
  const location = first.observations[0]?.location;
  assert.ok(location);
  assert.match(location.id, /^[0-9a-f-]{36}$/u);
  assert.match(location.chargingPoints[0]?.id ?? "", /^[0-9a-f-]{36}$/u);
  assert.match(location.sourceReference.contentHash, /^[0-9a-f]{64}$/u);
  assert.equal(location.sourceReference.providerId, "bundesnetzagentur_ladesaeulenregister");
  assert.equal(location.sourceReference.qualityTier, "authority");
});

async function collectFixture(): Promise<Readonly<{
  observations: NormalizedLocationObservation[];
  quarantines: QuarantinedProviderRecord[];
}>> {
  const observations: NormalizedLocationObservation[] = [];
  const quarantines: QuarantinedProviderRecord[] = [];
  for await (const result of readBundesnetzagenturCSV(options)) {
    if (result.kind === "observation") {
      observations.push(result.observation);
    } else {
      quarantines.push(result.quarantine);
    }
  }
  return { observations, quarantines };
}
