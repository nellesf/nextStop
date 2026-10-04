import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Pool } from "pg";
import { AvailabilityContextCodec, CandidateAvailability, InvalidAvailabilityContextError } from "../../src/application/candidate-availability.js";
import { PostGISCandidateSearch } from "../../src/application/postgis-candidate-search.js";
import { SignedPaginationCodec } from "../../src/application/signed-pagination.js";
import { buildChargingCampusProjection, buildChargingParkProjection } from "../../src/domain/charging-park-projection.js";
import type { NormalizedLocationObservation } from "../../src/domain/normalized-charging.js";
import { AvailabilitySnapshotWriter } from "../../src/persistence/availability-snapshot-writer.js";
import { PostgresCandidateAvailability } from "../../src/persistence/postgres-candidate-availability.js";
import { PostgresLiveRefreshControl, assertLiveRefreshLease } from "../../src/persistence/live-refresh-control.js";
import { ProjectionWriter } from "../../src/persistence/projection-writer.js";
import { refreshSwissLiveAvailability } from "../../src/jobs/refresh-providers.js";

/** Reuses only synthetic fixture records. Runs inside the existing destructive dedicated-test-DB harness. */
export async function verifyDemandLiveAvailability(pool: Pool, base: readonly NormalizedLocationObservation[]): Promise<void> {
  const now = new Date("2026-10-04T10:00:00Z"), observedAt = "2026-10-04T09:59:30.000Z";
  const records = base.map((record, index): NormalizedLocationObservation => ({ ...record, location: {
    ...record.location, operatorName: index < 2 ? "Visible" : index === 2 ? "Hidden" : "German",
    chargingPoints: record.location.chargingPoints.map((point) => ({ ...point, maximumPowerKW: index === 2 ? 50 : 150,
      sourceReference: { ...point.sourceReference, providerId: index === 3 ? "bundesnetzagentur_ladesaeulenregister" : "ich_tanke_strom" } })),
    sourceReference: { ...record.location.sourceReference, providerId: index === 3 ? "bundesnetzagentur_ladesaeulenregister" : "ich_tanke_strom" },
  } }));
  const first = records[0]; assert.ok(first);
  records.push({ ...first, location: { ...first.location, id: "90000000-0000-4000-8000-000000000001",
    chargingPoints: first.location.chargingPoints.map((point) => ({ ...point, id: "90000000-0000-4000-8000-000000000002" })) } });
  const locations = records.map(({ location }) => location), parks = buildChargingParkProjection(locations);
  const campuses = buildChargingCampusProjection(locations, parks);
  assert.equal(parks.length, 1); assert.equal(campuses.length, 1);
  const projectionId = randomUUID(), writer = new ProjectionWriter(pool);
  await writer.create({ id: projectionId, sourceDatasetHash: "8".repeat(64), sourceObservedAt: observedAt,
    builtAt: observedAt, coverageStatus: "complete", activeSources: ["ich_tanke_strom", "bundesnetzagentur_ladesaeulenregister"], unavailableSources: [] });
  await writer.writeObservations(projectionId, records); await writer.writeParks(projectionId, parks);
  await writer.writeCampuses(projectionId, campuses);
  await writer.publish(projectionId, { locationCount: 5, chargingPointCount: 5, parkCount: 1, campusCount: 1, quarantineCount: 0, conflictCount: 0 }, observedAt);
  const snapshotId = randomUUID(), snapshots = new AvailabilitySnapshotWriter(pool);
  await snapshots.create({ id: snapshotId, providerId: "ich_tanke_strom", sourceHash: "9".repeat(64), observedAt, fetchedAt: observedAt });
  await snapshots.write(snapshotId, records.slice(0, 3).flatMap(({ location }, index) => location.chargingPoints.map((point) => ({
    providerEVSEKey: point.providerEVSEKey ?? "missing", nativeIdentity: point.nativeIdentity ?? "missing",
    state: index === 1 ? "occupied" as const : "available" as const, observedAt, sourceReference: point.sourceReference,
  }))));
  await snapshots.publish(snapshotId, 3, 0, observedAt);
  const campusId = campuses[0]?.id, parkId = parks[0]?.id;
  assert.ok(campusId); assert.ok(parkId);
  const repository = new PostgresCandidateAvailability(pool);
  const context = { projectionId, candidateKind: "campus" as const, minimumPowerKW: 150 as const, expiresAt: now.getTime() + 3_600_000 };
  const selection = [{ id: campusId, operatorNames: ["Visible"] }];
  const fresh = await repository.read(context, selection, now);
  assert.equal(fresh.needsSwissRefresh, false);
  assert.deepEqual(fresh.candidates[0]?.availability, { knownAvailable: 1, knownUnavailable: 1, unknown: 0, total: 2, complete: true, observedAt });
  assert.equal((await repository.read({ ...context, candidateKind: "park" }, [{ id: parkId, operatorNames: ["Visible"] }], now)).candidates[0]?.availability.total, 2);
  const german = await repository.read(context, [{ id: campusId, operatorNames: ["German"] }], now);
  assert.equal(german.needsSwissRefresh, false); assert.equal(german.candidates[0]?.availability.unknown, 1);
  await assert.rejects(repository.read(context, [{ id: campusId, operatorNames: ["Hidden"] }], now), InvalidAvailabilityContextError);
  const low = await repository.read({ ...context, minimumPowerKW: 50 }, [{ id: campusId, operatorNames: ["Hidden"] }], now);
  assert.equal(low.candidates[0]?.availability.total, 1); assert.equal(low.candidates[0]?.availability.knownAvailable, 1);
  const stale = await repository.read(context, selection, new Date(now.getTime() + 300_000));
  assert.equal(stale.needsSwissRefresh, true);
  assert.deepEqual(stale.candidates[0]?.availability, { knownAvailable: 0, knownUnavailable: 0, unknown: 2, total: 2, complete: false });
  // Search publishes immediately with no live join. The secondary call alone signals demand.
  const key = "integration-availability-signing-key-at-least32", codec = new AvailabilityContextCodec(key);
  const search = new PostGISCandidateSearch(pool, new SignedPaginationCodec(key), () => now, codec);
  const found = await search.search({ requestId: randomUUID(), route: { type: "LineString", coordinates: [[10, 52], [10.2, 52]] },
    criteria: { distanceRangeMeters: { minimum: 15_000, maximum: 50_000 }, minimumChargingPoints: 2, minimumPowerKW: 150 } });
  assert.ok(found.availabilityContext); assert.equal(found.candidates.length, 1);
  assert.equal(found.candidates[0]?.availability.knownAvailable, 0);
  assert.equal(found.coverage.status, "complete");
  assert.deepEqual(codec.decode(found.availabilityContext, now), context);
  let signals = 0;
  const application = new CandidateAvailability(codec, repository, { signal: () => { signals += 1; return Promise.resolve(true); } }, () => now);
  assert.equal((await application.read({ context: found.availabilityContext, candidates: selection })).refreshPending, false);
  assert.equal(signals, 0);
  // The repository performs no writes and remains valid under a read-only transaction.
  const client = await pool.connect();
  try {
    await client.query("BEGIN READ ONLY");
    const readOnly = new PostgresCandidateAvailability({ query: client.query.bind(client) } as unknown as Pool);
    assert.equal((await readOnly.read(context, selection, now)).candidates[0]?.availability.total, 2);
    await client.query("ROLLBACK");
  } finally { client.release(); }
  await pool.query("UPDATE nextstop.projection_versions SET status = 'retired', search_pruned_at = now() WHERE id = $1", [projectionId]);
  await assert.rejects(repository.read(context, selection, now), InvalidAvailabilityContextError);
  await pool.query("DELETE FROM nextstop.availability_snapshots WHERE id = $1", [snapshotId]);
  await pool.query("DELETE FROM nextstop.projection_versions WHERE id = $1", [projectionId]);

  await pool.query("DELETE FROM nextstop.live_refresh_control");
  const control = new PostgresLiveRefreshControl(pool);
  const claims = await Promise.all([control.acquire(), new PostgresLiveRefreshControl(pool).acquire()]);
  assert.equal(claims.filter(({ lease }) => lease !== undefined).length, 1);
  assert.ok(claims.every(({ pending }) => pending));
  const lease = claims.find(({ lease }) => lease !== undefined)?.lease; assert.ok(lease);
  const guardClient = await pool.connect();
  try { await assertLiveRefreshLease(guardClient, lease); } finally { guardClient.release(); }
  await pool.query("UPDATE nextstop.live_refresh_control SET lease_until = now() - interval '1 second', next_allowed_at = now() - interval '1 second'");
  const successor = await control.acquire(); assert.ok(successor.lease);
  // A late old process cannot publish. Its failed snapshot never replaces the active one.
  const pendingId = randomUUID();
  await snapshots.create({ id: pendingId, providerId: "ich_tanke_strom", sourceHash: "7".repeat(64), observedAt, fetchedAt: observedAt });
  const point = first.location.chargingPoints[0]; assert.ok(point);
  await snapshots.write(pendingId, [{ providerEVSEKey: point.providerEVSEKey ?? "missing", nativeIdentity: point.nativeIdentity ?? "missing",
    state: "available", observedAt, sourceReference: point.sourceReference }]);
  await assert.rejects(snapshots.publish(pendingId, 1, 0, observedAt, lease), /LiveRefreshLeaseLost/u);
  await control.finish(lease, true);
  assert.equal((await control.acquire()).pending, true);
  await control.finish(successor.lease, false);
  const cooldown = await control.acquire(); assert.equal(cooldown.lease, undefined); assert.equal(cooldown.pending, false);
  // Invalid/stale provider data does not publish and remains an upstream failure.
  await assert.rejects(refreshSwissLiveAvailability(pool, { now: () => now, downloadSwissFeed: () => Promise.resolve({ kind: "live",
    payload: {}, sha256: "6".repeat(64), observedAt: "2026-10-04T09:00:00Z", fetchedAt: now.toISOString(), lastModified: "Sun, 04 Oct 2026 09:00:00 GMT" }) }), /stale/u);
  await pool.query("DELETE FROM nextstop.availability_snapshots WHERE id = $1", [pendingId]);
  await pool.query("DELETE FROM nextstop.live_refresh_control");
}
