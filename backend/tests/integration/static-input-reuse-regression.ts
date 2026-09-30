import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import type { Pool } from "pg";

import {
  importStaticProjection,
  type StaticProviderDataset,
  type StaticProviderRecordResult,
} from "../../src/application/static-projection-importer.js";
import { bundesnetzagenturDescriptor } from "../../src/providers/bundesnetzagentur/descriptor.js";

const providerId = bundesnetzagenturDescriptor.id;
const observedAt = "2026-09-01T00:00:00.000Z";
const fetchedAt = "2026-09-01T01:00:00.000Z";

/** Run against the dedicated empty integration schema before ordinary fixtures. */
export async function verifyStaticInputReuse(pool: Pool): Promise<void> {
  assert.equal((await pool.query<{ count: number }>(
    "SELECT count(*)::integer AS count FROM nextstop.projection_versions",
  )).rows[0]?.count, 0);
  const sourceRecordId = `static-input-fixture-${randomUUID()}`;
  const quarantineRecordId = `static-input-quarantine-${randomUUID()}`;
  const record: Extract<StaticProviderRecordResult, { kind: "observation" }> = {
    kind: "observation",
    observation: {
      rawPayload: { identity: sourceRecordId, ignoredByCurrentMapper: "original", nested: { a: 1, b: false } },
      location: {
        id: randomUUID(), name: "Static-input fixture", operatorName: "Fixture", active: true,
        coordinate: { latitude: 53.55, longitude: 10 }, address: {},
        sourceReference: { providerId, sourceRecordId, observedAt, fetchedAt,
          qualityTier: "authority", contentHash: "a".repeat(64) },
        chargingPoints: [{
          id: randomUUID(), identityDecision: "unresolved", connectors: [{ sourceValue: "CCS" }],
          maximumPowerKW: 150, availability: { state: "unknown", isLive: false },
          sourceReference: { providerId, sourceRecordId, observedAt, fetchedAt,
            qualityTier: "authority", contentHash: "a".repeat(64) },
        }],
      },
    },
  };
  const quarantined: Extract<StaticProviderRecordResult, { kind: "quarantine" }> = {
    kind: "quarantine", quarantine: { rowNumber: 2, sourceRecordId: quarantineRecordId,
      issueCodes: ["invalid_coordinate"] }, rawPayload: { coordinate: "invalid" },
  };
  const firstDataset: StaticProviderDataset = {
    providerId, observedAt, datasetHash: "a".repeat(64), records: [record, quarantined],
  };
  try {
    const first = await importStaticProjection(pool, [firstDataset], [], () => new Date(fetchedAt));
    assert.equal(first.kind, "published");
    const firstMetadata = await metadata(pool, first.projectionId);
    assert.match(firstMetadata.input_content_hash, /^[0-9a-f]{64}$/u);
    const initialCounts = await rowCounts(pool);
    assert.equal(initialCounts.versions, 1);
    assert.equal(initialCounts.locations, 1);
    assert.equal(initialCounts.points, 1);
    assert.equal(initialCounts.quarantines, 1);

    const refreshedRecord: typeof record = {
      ...record,
      observation: {
        rawPayload: { nested: { b: false, a: 1 }, ignoredByCurrentMapper: "original", identity: sourceRecordId },
        location: {
          ...record.observation.location,
          sourceReference: { ...record.observation.location.sourceReference,
            observedAt: fetchedAt, fetchedAt: "2026-09-02T00:00:00Z", contentHash: "b".repeat(64) },
          chargingPoints: record.observation.location.chargingPoints.map((point) => ({
            ...point, sourceReference: { ...point.sourceReference,
              observedAt: fetchedAt, fetchedAt: "2026-09-02T00:00:00Z", contentHash: "b".repeat(64) },
          })),
        },
      },
    };
    const refreshedDataset: StaticProviderDataset = {
      providerId, observedAt: fetchedAt, datasetHash: "b".repeat(64),
      records: [{ ...quarantined, quarantine: { ...quarantined.quarantine, rowNumber: 1 } }, refreshedRecord],
    };
    const reused = await importStaticProjection(pool, [refreshedDataset], [],
      () => new Date("2026-09-02T00:00:00Z"));
    assert.deepEqual(reused, { kind: "unchanged", projectionId: first.projectionId });
    assert.deepEqual(await rowCounts(pool), initialCounts,
      "Transport-only changes must add no provider/normalized/derived/version/quarantine rows.");
    assert.deepEqual(await metadata(pool, first.projectionId), firstMetadata,
      "The original source hash, timestamps, and normalized fingerprint remain immutable.");
    const alias = await pool.query<{ source_dataset_hash: string; projection_id: string; checked_at: Date }>(
      "SELECT source_dataset_hash, projection_id, checked_at FROM nextstop.static_projection_input_checks",
    );
    assert.equal(alias.rows.length, 1);
    assert.equal(alias.rows[0]?.projection_id, first.projectionId);
    assert.notEqual(alias.rows[0]?.source_dataset_hash, firstMetadata.source_dataset_hash);
    assert.equal(alias.rows[0]?.checked_at.toISOString(), "2026-09-02T00:00:00.000Z");

    const mustNotParse: StaticProviderDataset = {
      providerId, observedAt: fetchedAt, datasetHash: "b".repeat(64),
      get records(): readonly StaticProviderRecordResult[] {
        throw new Error("An already validated raw snapshot must not be parsed again.");
      },
    };
    assert.deepEqual(await importStaticProjection(pool, [mustNotParse], []), reused);
    assert.deepEqual(await rowCounts(pool), initialCounts);

    const changedRecord: typeof record = {
      ...refreshedRecord,
      observation: {
        ...refreshedRecord.observation,
        rawPayload: { ...refreshedRecord.observation.rawPayload, ignoredByCurrentMapper: "changed" },
        location: { ...refreshedRecord.observation.location,
          sourceReference: { ...refreshedRecord.observation.location.sourceReference, contentHash: "c".repeat(64) } },
      },
    };
    const changed = await importStaticProjection(pool, [{ ...firstDataset,
      datasetHash: "c".repeat(64), records: [changedRecord, quarantined],
    }], [], () => new Date("2026-09-03T00:00:00Z"));
    assert.equal(changed.kind, "published");
    assert.notEqual(changed.projectionId, first.projectionId);
    assert.notEqual((await metadata(pool, changed.projectionId)).input_content_hash,
      firstMetadata.input_content_hash);
    const changedCounts = await rowCounts(pool);
    assert.equal(changedCounts.versions, 2);
    assert.equal(changedCounts.locations, initialCounts.locations * 2);
    assert.equal(changedCounts.points, initialCounts.points * 2);
    assert.equal(changedCounts.quarantines, initialCounts.quarantines * 2);
    assert.equal((await metadata(pool, first.projectionId)).source_dataset_hash,
      firstMetadata.source_dataset_hash);
  } finally {
    // This helper explicitly requires an empty version table on entry. Delete all
    // versions it created, including a failed/building row from a failing assertion.
    await pool.query("DELETE FROM nextstop.projection_versions");
    await pool.query("DELETE FROM nextstop.provider_records WHERE provider_id = $1 AND source_record_id = $2",
      [providerId, sourceRecordId]);
  }
}

async function metadata(pool: Pool, projectionId: string) {
  const result = await pool.query<{
    source_dataset_hash: string; input_content_hash: string; source_observed_at: Date; built_at: Date;
  }>(`SELECT source_dataset_hash, input_content_hash, source_observed_at, built_at
      FROM nextstop.projection_versions WHERE id = $1`, [projectionId]);
  const row = result.rows[0];
  assert.ok(row);
  return row;
}

async function rowCounts(pool: Pool) {
  const result = await pool.query<{
    versions: number; providerRecords: number; locations: number; points: number;
    parks: number; campuses: number; parkPower: number; campusPower: number; quarantines: number;
  }>(`SELECT
    (SELECT count(*)::integer FROM nextstop.projection_versions) AS versions,
    (SELECT count(*)::integer FROM nextstop.provider_records) AS "providerRecords",
    (SELECT count(*)::integer FROM nextstop.normalized_charging_locations) AS locations,
    (SELECT count(*)::integer FROM nextstop.normalized_charging_points) AS points,
    (SELECT count(*)::integer FROM nextstop.charging_park_projection) AS parks,
    (SELECT count(*)::integer FROM nextstop.charging_campus_projection) AS campuses,
    (SELECT count(*)::integer FROM nextstop.charging_park_power_projection) AS "parkPower",
    (SELECT count(*)::integer FROM nextstop.charging_campus_power_projection) AS "campusPower",
    (SELECT count(*)::integer FROM nextstop.provider_quarantine) AS quarantines`);
  const row = result.rows[0];
  assert.ok(row);
  return row;
}
