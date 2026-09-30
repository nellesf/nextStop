import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { staticInputFingerprint, type ParsedStaticProviderDataset } from "../../src/application/static-input-fingerprint.js";
import type { StaticProviderRecordResult } from "../../src/application/static-projection-importer.js";
import type { NormalizedChargingLocation, SourceReference } from "../../src/domain/normalized-charging.js";
import { readBundesnetzagenturCSV } from "../../src/providers/bundesnetzagentur/csv-provider.js";
import { readIchTankeStromStaticFeed } from "../../src/providers/ich-tanke-strom/static-provider.js";

const observedAt = "2026-09-01T00:00:00.000Z";
const fetchedAt = "2026-09-01T01:00:00.000Z";
const policy = "test-policy-v1";

void test("provider/record ordering, JSON object key ordering, and file hashes do not change the fingerprint", () => {
  const first = observation();
  const second = observation({ id: "second-location" });
  const a = dataset([first, second], "a");
  const b = dataset([observation({ id: "third-location" })], "b");
  const reordered = {
    ...first,
    observation: {
      ...first.observation,
      rawPayload: { detail: { b: false, a: 1 }, sourceValue: "unchanged" },
    },
  };
  const changedEnvelope = { ...a, datasetHash: "b".repeat(64), observedAt: fetchedAt,
    records: [second, reordered] };
  assert.equal(staticInputFingerprint([a, b], ["d", "c"], policy),
    staticInputFingerprint([b, changedEnvelope], ["c", "d"], policy));
});

void test("source-reference transport timestamps and content hashes are excluded at location and EVSE only", () => {
  const original = observation();
  const changed = observation({
    sourceReference: source({ observedAt: fetchedAt, fetchedAt: observedAt, contentHash: "b".repeat(64) }),
    chargingPoints: original.observation.location.chargingPoints.map((point) => ({
      ...point,
      sourceReference: source({ observedAt: fetchedAt, fetchedAt: observedAt, contentHash: "c".repeat(64) }),
    })),
  });
  assert.equal(recordSetHash([original]), recordSetHash([changed]));
});

void test("all raw fields remain significant including unused fields and timestamp-like field names", () => {
  const original = observation();
  for (const rawPayload of [
    { ...original.observation.rawPayload, unusedProviderField: "new" },
    { ...original.observation.rawPayload, observedAt: fetchedAt },
    { ...original.observation.rawPayload, fetchedAt },
    { ...original.observation.rawPayload, contentHash: "new" },
    { ...original.observation.rawPayload, sourceReference: { observedAt } },
    { ...original.observation.rawPayload, detail: { a: "1", b: false } },
  ]) {
    assert.notEqual(recordSetHash([original]), recordSetHash([{
      ...original, observation: { ...original.observation, rawPayload },
    }]));
  }
});

void test("normalized fields, source identity, and availability timestamps remain significant", () => {
  const original = observation();
  const location = original.observation.location;
  const point = location.chargingPoints[0];
  assert.ok(point);
  const changes: Partial<NormalizedChargingLocation>[] = [
    { operatorName: "A new batch-level operator" },
    { coordinate: { ...location.coordinate, latitude: 48 } },
    { active: false },
    { address: { street: "New address" } },
    { sourceReference: source({ sourceRecordId: "new-source-id" }) },
    { sourceReference: source({ providerId: "new-provider" }) },
    { chargingPoints: [{ ...point, maximumPowerKW: 350 }] },
    { chargingPoints: [{ ...point, nativeIdentity: "different" }] },
    { chargingPoints: [{ ...point, sourceReference: source({ sourceRecordId: "different-point" }) }] },
    { chargingPoints: [{ ...point, availability: { ...point.availability, observedAt: fetchedAt } }] },
    { chargingPoints: [{ ...point, availability: { ...point.availability, state: "available" } }] },
  ];
  for (const change of changes) {
    assert.notEqual(recordSetHash([original]), recordSetHash([observation(change)]));
  }
});

void test("quarantine positions may move but issues, source identity, raw data, and duplicates remain significant", () => {
  const original = quarantine();
  const moved = { ...original, quarantine: { ...original.quarantine, rowNumber: 999 } };
  assert.equal(recordSetHash([original]), recordSetHash([moved]));
  const changed = [
    { ...original, rawPayload: { value: "different" } },
    { ...original, quarantine: { ...original.quarantine, sourceRecordId: "different" } },
    { ...original, quarantine: { ...original.quarantine, issueCodes: ["different_issue"] } },
  ];
  for (const record of changed) assert.notEqual(recordSetHash([original]), recordSetHash([record]));
  assert.notEqual(recordSetHash([original]), recordSetHash([original, moved]));
  assert.notEqual(recordSetHash([observation()]), recordSetHash([observation(), observation()]));
});

void test("policy, provider membership, and unavailable source changes force a new fingerprint", () => {
  const records = [dataset([observation()])];
  const original = staticInputFingerprint(records, [], policy);
  assert.notEqual(original, staticInputFingerprint(records, [], "test-policy-v2"));
  assert.notEqual(original, staticInputFingerprint(records, ["missing"], policy));
  assert.notEqual(original, staticInputFingerprint([...records, dataset([], "extra")], [], policy));
});

void test("raw arrays retain order and unsupported raw values fail closed", () => {
  const base = observation();
  const withRaw = (value: unknown) => ({ ...base, observation: { ...base.observation, rawPayload: { value } } });
  assert.notEqual(recordSetHash([withRaw([1, 2])]), recordSetHash([withRaw([2, 1])]));
  for (const value of [undefined, Number.NaN, Infinity, 1n, new Date()]) {
    assert.throws(() => recordSetHash([withRaw(value)]), /non-JSON/u);
  }
});

void test("actual German CSV mapping tolerates fetch changes and complete record reordering", async () => {
  const records: StaticProviderRecordResult[] = [];
  for await (const record of readBundesnetzagenturCSV({
    filePath: fileURLToPath(new URL("../fixtures/bundesnetzagentur/sample.csv", import.meta.url)),
    observedAt, fetchedAt,
  })) records.push(record);
  assert.equal(records.length, 4);
  assert.equal(recordSetHash(records), recordSetHash(records.toReversed()));
});

void test("actual Swiss mapping ignores envelope metadata but preserves normalized batch-level operator changes", () => {
  const rawRecord = {
    EvseID: "CH*ABC*E1", GeoCoordinates: { Google: "46.9480 7.4474" },
    Plugs: ["Type 2 Outlet"], ChargingFacilities: [{ power: 22 }],
  };
  const payload = (OperatorName: string, metadata: string) => ({
    metadata, EVSEData: [{ OperatorName, EVSEDataRecord: [rawRecord] }],
  });
  const first = readIchTankeStromStaticFeed(payload("Operator", "old-envelope"), observedAt, fetchedAt);
  const refreshed = readIchTankeStromStaticFeed(payload("Operator", "new-envelope"), fetchedAt, fetchedAt);
  const changed = readIchTankeStromStaticFeed(payload("New operator", "new-envelope"), fetchedAt, fetchedAt);
  assert.equal(recordSetHash(first), recordSetHash(refreshed));
  assert.notEqual(recordSetHash(first), recordSetHash(changed));
});

function source(overrides: Partial<SourceReference> = {}): SourceReference {
  return { providerId: "fixture", sourceRecordId: "record-1", qualityTier: "authority",
    observedAt, fetchedAt, contentHash: "a".repeat(64), ...overrides };
}

function observation(
  overrides: Partial<NormalizedChargingLocation> = {},
): Extract<StaticProviderRecordResult, { kind: "observation" }> {
  return {
    kind: "observation",
    observation: {
      rawPayload: { sourceValue: "unchanged", detail: { a: 1, b: false } },
      location: {
        id: "location-1", name: "Fixture", operatorName: "Operator", active: true,
        coordinate: { latitude: 47, longitude: 8 }, address: {}, sourceReference: source(),
        chargingPoints: [{ id: "evse-1", identityDecision: "exact", maximumPowerKW: 150,
          connectors: [{ sourceValue: "CCS" }], availability: { state: "unknown", isLive: false },
          sourceReference: source() }],
        ...overrides,
      },
    },
  };
}

function quarantine(): Extract<StaticProviderRecordResult, { kind: "quarantine" }> {
  return { kind: "quarantine", rawPayload: { value: "bad" },
    quarantine: { rowNumber: 1, sourceRecordId: "bad-record", issueCodes: ["invalid_power"] } };
}

function dataset(records: readonly StaticProviderRecordResult[], providerId = "fixture"): ParsedStaticProviderDataset {
  return { providerId, datasetHash: "a".repeat(64), observedAt, records };
}

function recordSetHash(records: readonly StaticProviderRecordResult[]): string {
  return staticInputFingerprint([dataset(records)], [], policy);
}
