import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { PostGISCandidateSearch } from "../../src/application/postgis-candidate-search.js";
import { SignedPaginationCodec } from "../../src/application/signed-pagination.js";
import { buildChargingParkProjection } from "../../src/domain/charging-park-projection.js";
import type {
  NormalizedChargingLocation,
  NormalizedLocationObservation,
} from "../../src/domain/normalized-charging.js";
import { createDatabasePool } from "../../src/persistence/database.js";
import { AvailabilitySnapshotWriter } from "../../src/persistence/availability-snapshot-writer.js";
import { applyMigrations } from "../../src/persistence/migrate.js";
import {
  ProjectionWriter,
  type QuarantineInput,
} from "../../src/persistence/projection-writer.js";
import { readBundesnetzagenturCSV } from "../../src/providers/bundesnetzagentur/csv-provider.js";
import { bundesnetzagenturDescriptor } from "../../src/providers/bundesnetzagentur/descriptor.js";
import { ichTankeStromDescriptor } from "../../src/providers/ich-tanke-strom/descriptor.js";
import type { NormalizedAvailabilityObservation } from "../../src/providers/ich-tanke-strom/live-provider.js";
import {
  refreshStaticProviders,
  refreshSwissLiveAvailability,
} from "../../src/jobs/refresh-providers.js";
import type { SearchRequest } from "../../src/domain/candidate-search.js";

const connectionString = process.env.TEST_DATABASE_URL;
const signingKey = "integration-test-signing-key-with-at-least-32-bytes";
const fixturePath = fileURLToPath(
  new URL("../fixtures/bundesnetzagentur/sample.csv", import.meta.url),
);

void test(
  "real PostGIS projection and exact corridor search",
  { skip: connectionString === undefined ? "TEST_DATABASE_URL is not configured." : false },
  async (context) => {
    assert.ok(connectionString);
    assertDedicatedTestDatabase(connectionString);
    const pool = createDatabasePool(connectionString);
    context.after(async () => pool.end());
    await pool.query("DROP SCHEMA IF EXISTS nextstop CASCADE");
    await applyMigrations(pool);

    await context.test("imports normalized fixture rows and publishes atomically", async () => {
      await resetDatabase(pool);
      const projectionId = "11111111-1111-4111-8111-111111111111";
      const writer = new ProjectionWriter(pool);
      await writer.create({
        id: projectionId,
        sourceDatasetHash: "a".repeat(64),
        sourceObservedAt: "2026-07-07T00:00:00.000Z",
        builtAt: "2026-08-14T07:00:00.000Z",
        coverageStatus: "complete",
        activeSources: [bundesnetzagenturDescriptor.id],
        unavailableSources: [],
      });
      const observations: NormalizedLocationObservation[] = [];
      const locations: NormalizedChargingLocation[] = [];
      const quarantines: QuarantineInput[] = [];
      for await (const result of readBundesnetzagenturCSV({
        filePath: fixturePath,
        observedAt: "2026-07-07T00:00:00.000Z",
        fetchedAt: "2026-08-14T07:00:00.000Z",
      })) {
        if (result.kind === "observation") {
          observations.push(result.observation);
          locations.push(result.observation.location);
        } else {
          quarantines.push({
            providerId: bundesnetzagenturDescriptor.id,
            summary: result.quarantine,
            rawPayload: result.rawPayload,
          });
        }
      }
      await writer.writeObservations(projectionId, observations);
      await writer.writeQuarantines(projectionId, quarantines);
      const parks = buildChargingParkProjection(locations);
      await writer.writeParks(projectionId, parks);
      await writer.publish(
        projectionId,
        {
          locationCount: 3,
          chargingPointCount: 5,
          parkCount: 1,
          quarantineCount: 1,
          conflictCount: 0,
        },
        "2026-08-14T08:00:00.000Z",
      );

      const counts = await pool.query<{
        readonly locations: number;
        readonly points: number;
        readonly parks: number;
        readonly quarantines: number;
      }>(`SELECT
            (SELECT count(*)::integer FROM nextstop.normalized_charging_locations) AS locations,
            (SELECT count(*)::integer FROM nextstop.normalized_charging_points) AS points,
            (SELECT count(*)::integer FROM nextstop.charging_park_projection) AS parks,
            (SELECT count(*)::integer FROM nextstop.provider_quarantine) AS quarantines`);
      assert.deepEqual(counts.rows[0], {
        locations: 3,
        points: 5,
        parks: 1,
        quarantines: 1,
      });
      const search = candidateSearch(pool);
      const response = await search.search(searchRequest([
        [9.99, 53.55],
        [10.01, 53.55],
      ]));
      assert.equal(response.candidates.length, 1);
      assert.equal(response.candidates[0]?.chargingPoints, 4);
      assert.equal(response.candidates[0]?.availability.unknown, 4);
      assert.deepEqual(response.coverage.activeSources, [bundesnetzagenturDescriptor.id]);
    });

    await context.test("uses exact inclusive 5 km geography instead of a bounding box", async () => {
      await resetDatabase(pool);
      const projectionId = await insertActiveProjection(pool);
      await insertProjectedPark(pool, projectionId, {
        northMeters: 4_999,
        parkId: "20000000-0000-4000-8000-000000000001",
      });
      await insertProjectedPark(pool, projectionId, {
        northMeters: 5_000,
        parkId: "20000000-0000-4000-8000-000000000002",
      });
      await insertProjectedPark(pool, projectionId, {
        northMeters: 5_001,
        parkId: "20000000-0000-4000-8000-000000000003",
      });
      await insertPointPark(pool, projectionId, {
        latitude: 52.5,
        longitude: 10.5,
        parkId: "20000000-0000-4000-8000-000000000004",
      });

      const search = candidateSearch(pool);
      const straightRoute = await search.search(searchRequest([
        [10, 52],
        [10.2, 52],
      ]));
      assert.deepEqual(
        straightRoute.candidates.map((candidate) => candidate.id),
        [
          "20000000-0000-4000-8000-000000000001",
          "20000000-0000-4000-8000-000000000002",
        ],
      );
      assert.equal(straightRoute.candidates[1]?.distanceFromRouteMeters, 5_000);

      const bentRoute = await search.search(searchRequest([
        [10, 52],
        [11, 52],
        [11, 53],
      ]));
      assert.equal(
        bentRoute.candidates.some(
          (candidate) => candidate.id === "20000000-0000-4000-8000-000000000004",
        ),
        false,
      );
    });

    await context.test("automatically refreshes static and live authority feeds", async () => {
      await resetDatabase(pool);
      let cleanupCount = 0;
      const now = () => new Date("2026-08-14T09:00:00.000Z");
      const dependencies = {
        now,
        downloadBundesnetzagentur: () =>
          Promise.resolve({
            filePath: fixturePath,
            sha256: "e".repeat(64),
            observedAt: "2026-07-07T00:00:00.000Z",
            fetchedAt: "2026-08-14T08:00:00.000Z",
            sourceURL:
              "https://data.bundesnetzagentur.de/Bundesnetzagentur/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenregister_BNetzA_2026-07-07.csv",
            cleanup: () => {
              cleanupCount += 1;
              return Promise.resolve();
            },
          }),
        downloadSwissFeed: (kind: "static" | "live") =>
          Promise.resolve({
            kind,
            payload:
              kind === "static" ? swissAuthorityStaticPayload() : swissAuthorityLivePayload(),
            sha256: (kind === "static" ? "f" : "a").repeat(64),
            observedAt:
              kind === "static"
                ? "2026-08-14T08:00:00.000Z"
                : "2026-08-14T08:59:00.000Z",
            fetchedAt:
              kind === "static"
                ? "2026-08-14T08:00:01.000Z"
                : "2026-08-14T08:59:01.000Z",
            lastModified: "Thu, 14 Aug 2026 08:59:00 GMT",
          }),
      };

      const firstStatic = await refreshStaticProviders(pool, dependencies);
      assert.equal(firstStatic.kind, "published");
      assert.equal(cleanupCount, 1);
      const secondStatic = await refreshStaticProviders(pool, dependencies);
      assert.equal(secondStatic.kind, "unchanged");
      assert.equal(cleanupCount, 2);

      const live = await refreshSwissLiveAvailability(pool, dependencies);
      assert.equal(live.kind, "published");
      const authorityRequest = searchRequest([
        [7.42, 46.93],
        [7.48, 46.97],
      ]);
      const response = await candidateSearch(pool).search({
        ...authorityRequest,
        criteria: { ...authorityRequest.criteria, minimumChargingPoints: 2 },
      });
      const swissPark = response.candidates.find(({ sources }) =>
        sources.some(({ id }) => id === ichTankeStromDescriptor.id),
      );
      assert.ok(swissPark);
      assert.deepEqual(swissPark.availability, {
        knownAvailable: 1,
        knownUnavailable: 1,
        unknown: 0,
        total: 2,
        complete: true,
        observedAt: "2026-08-14T08:59:00.000Z",
      });
      assert.deepEqual(response.coverage.activeSources, [
        bundesnetzagenturDescriptor.id,
        ichTankeStromDescriptor.id,
      ]);
    });

    await context.test("merges a fresh Swiss live snapshot by EVSE identity", async () => {
      await resetDatabase(pool);
      const projectionId = "60000000-0000-4000-8000-000000000001";
      const writer = new ProjectionWriter(pool);
      const observations = swissStaticObservations();
      const locations = observations.map(({ location }) => location);
      const parks = buildChargingParkProjection(locations);
      assert.equal(parks.length, 1);
      await writer.create({
        id: projectionId,
        sourceDatasetHash: "c".repeat(64),
        sourceObservedAt: "2026-08-14T08:00:00.000Z",
        builtAt: "2026-08-14T08:05:00.000Z",
        coverageStatus: "complete",
        activeSources: [ichTankeStromDescriptor.id],
        unavailableSources: [],
      });
      await writer.writeObservations(projectionId, observations);
      await writer.writeParks(projectionId, parks);
      await writer.publish(
        projectionId,
        {
          locationCount: 4,
          chargingPointCount: 4,
          parkCount: 1,
          quarantineCount: 0,
          conflictCount: 0,
        },
        "2026-08-14T08:10:00.000Z",
      );

      const snapshotId = "70000000-0000-4000-8000-000000000001";
      const snapshotWriter = new AvailabilitySnapshotWriter(pool);
      await snapshotWriter.create({
        id: snapshotId,
        providerId: ichTankeStromDescriptor.id,
        sourceHash: "d".repeat(64),
        observedAt: "2026-08-14T08:59:00.000Z",
        fetchedAt: "2026-08-14T08:59:01.000Z",
      });
      const live = swissLiveObservations();
      await snapshotWriter.write(snapshotId, live);
      await snapshotWriter.publish(
        snapshotId,
        live.length,
        0,
        "2026-08-14T08:59:02.000Z",
      );

      const search = candidateSearch(pool);
      const response = await search.search(searchRequest([
        [10, 52],
        [10.2, 52],
      ]));
      assert.equal(response.candidates.length, 1);
      assert.deepEqual(response.candidates[0]?.availability, {
        knownAvailable: 1,
        knownUnavailable: 1,
        unknown: 2,
        total: 4,
        complete: false,
        observedAt: "2026-08-14T08:59:00.000Z",
      });
      assert.equal(response.coverage.status, "complete");
      assert.equal(
        response.candidates[0]?.sources[0]?.liveObservedAt,
        "2026-08-14T08:59:00.000Z",
      );

      const minimumFour = await search.search({
        ...searchRequest([
          [10, 52],
          [10.2, 52],
        ]),
        criteria: {
          ...searchRequest([
            [10, 52],
            [10.2, 52],
          ]).criteria,
          minimumAvailablePoints: 4,
        },
      });
      assert.equal(minimumFour.candidates.length, 0);
    });

    await context.test("applies the three-valued availability rule", async () => {
      await resetDatabase(pool);
      const projectionId = await insertActiveProjection(pool);
      await insertProjectedPark(pool, projectionId, {
        northMeters: 100,
        parkId: "30000000-0000-4000-8000-000000000001",
        knownUnavailable: 0,
        unknown: 4,
      });
      await insertProjectedPark(pool, projectionId, {
        northMeters: 200,
        parkId: "30000000-0000-4000-8000-000000000002",
        knownUnavailable: 1,
        unknown: 3,
      });

      const response = await candidateSearch(pool).search({
        ...searchRequest([
          [10, 52],
          [10.2, 52],
        ]),
        criteria: {
          ...searchRequest([
            [10, 52],
            [10.2, 52],
          ]).criteria,
          minimumAvailablePoints: 4,
        },
      });
      assert.deepEqual(response.candidates.map((candidate) => candidate.id), [
        "30000000-0000-4000-8000-000000000001",
      ]);
    });

    await context.test("keeps an old snapshot stable after a newer publish", async () => {
      await resetDatabase(pool);
      const oldProjectionId = await insertActiveProjection(pool);
      for (let index = 0; index < 55; index += 1) {
        await insertProjectedPark(pool, oldProjectionId, {
          northMeters: 0,
          eastMeters: index * 100,
          parkId: indexedUUID(4, index),
        });
      }
      const search = candidateSearch(pool);
      const request = searchRequest([
        [10, 52],
        [10.2, 52],
      ]);
      const firstPage = await search.search(request);
      assert.equal(firstPage.candidates.length, 50);
      assert.ok(firstPage.nextCursor);

      const newProjectionId = randomUUID();
      await pool.query("BEGIN");
      try {
        await pool.query(
          "UPDATE nextstop.projection_versions SET status = 'retired' WHERE id = $1",
          [oldProjectionId],
        );
        await insertProjection(pool, newProjectionId, "active");
        await pool.query("COMMIT");
      } catch (error) {
        await pool.query("ROLLBACK");
        throw error;
      }

      const secondPage = await search.search({
        ...request,
        page: {
          snapshotToken: firstPage.snapshotToken,
          cursor: firstPage.nextCursor,
        },
      });
      assert.equal(secondPage.candidates.length, 5);
      assert.equal(secondPage.nextCursor, null);
      assert.equal(secondPage.snapshotToken, firstPage.snapshotToken);
    });

    await context.test("creates and uses the GiST spatial index", async () => {
      const indexes = await pool.query<{ readonly indexname: string }>(
        `SELECT indexname
         FROM pg_indexes
         WHERE schemaname = 'nextstop' AND indexname = 'charging_park_projection_coordinate_gist'`,
      );
      assert.equal(indexes.rows.length, 1);
      await pool.query("SET enable_seqscan = off");
      const plan = await pool.query<{ readonly "QUERY PLAN": unknown }>(
        `EXPLAIN (FORMAT JSON)
         SELECT park_id
         FROM nextstop.charging_park_projection
         WHERE ST_DWithin(
           navigation_coordinate,
           ST_SetSRID(ST_MakePoint(10, 52), 4326)::geography,
           5000
         )`,
      );
      assert.match(
        JSON.stringify(plan.rows),
        /charging_park_projection_coordinate_gist/u,
      );
      await pool.query("RESET enable_seqscan");
    });
  },
);

function candidateSearch(pool: Pool): PostGISCandidateSearch {
  return new PostGISCandidateSearch(
    pool,
    new SignedPaginationCodec(signingKey),
    () => new Date("2026-08-14T09:00:00.000Z"),
  );
}

function searchRequest(
  coordinates: SearchRequest["route"]["coordinates"],
): SearchRequest {
  return {
    requestId: randomUUID(),
    route: { type: "LineString", coordinates },
    criteria: {
      distanceRangeMeters: { minimum: 50_000, maximum: 100_000 },
      minimumChargingPoints: 4,
      minimumPowerKW: 100,
    },
  };
}

async function resetDatabase(pool: Pool): Promise<void> {
  await pool.query(
    `TRUNCATE nextstop.projection_versions,
              nextstop.provider_records
     CASCADE`,
  );
}

async function insertActiveProjection(pool: Pool): Promise<string> {
  const id = randomUUID();
  await insertProjection(pool, id, "active");
  return id;
}

async function insertProjection(
  pool: Pool,
  id: string,
  status: "active" | "retired",
): Promise<void> {
  await pool.query(
    `INSERT INTO nextstop.projection_versions (
       id, source_dataset_hash, source_observed_at, built_at, published_at,
       status, coverage_status, active_sources, unavailable_sources
     ) VALUES (
       $1, $2, '2026-07-07T00:00:00Z', '2026-08-14T07:00:00Z',
       '2026-08-14T08:00:00Z', $3, 'complete', $4, '{}'
     )`,
    [id, "b".repeat(64), status, [bundesnetzagenturDescriptor.id]],
  );
}

interface ProjectedParkInput {
  readonly parkId: string;
  readonly northMeters: number;
  readonly eastMeters?: number;
  readonly knownUnavailable?: number;
  readonly unknown?: number;
}

async function insertProjectedPark(
  pool: Pool,
  projectionId: string,
  input: ProjectedParkInput,
): Promise<void> {
  const northMeters = input.northMeters;
  const eastMeters = input.eastMeters ?? 0;
  const coordinate = await pool.query<{ readonly latitude: number; readonly longitude: number }>(
    `SELECT ST_Y(projected::geometry) AS latitude,
            ST_X(projected::geometry) AS longitude
     FROM (
       SELECT ST_Project(
         ST_Project(
           ST_SetSRID(ST_MakePoint(10, 52), 4326)::geography,
           $1::double precision,
           pi() / 2
         ),
         $2::double precision,
         0::double precision
       ) AS projected
     ) AS point`,
    [eastMeters, northMeters],
  );
  const point = coordinate.rows[0];
  assert.ok(point);
  await insertPointPark(pool, projectionId, {
    parkId: input.parkId,
    latitude: point.latitude,
    longitude: point.longitude,
    ...(input.knownUnavailable === undefined
      ? {}
      : { knownUnavailable: input.knownUnavailable }),
    ...(input.unknown === undefined ? {} : { unknown: input.unknown }),
  });
}

interface PointParkInput {
  readonly parkId: string;
  readonly latitude: number;
  readonly longitude: number;
  readonly knownUnavailable?: number;
  readonly unknown?: number;
}

async function insertPointPark(
  pool: Pool,
  projectionId: string,
  input: PointParkInput,
): Promise<void> {
  const knownUnavailable = input.knownUnavailable ?? 0;
  const unknown = input.unknown ?? 4;
  const knownAvailable = 4 - knownUnavailable - unknown;
  await pool.query(
    `INSERT INTO nextstop.charging_park_projection (
       projection_id, park_id, name, centroid, navigation_coordinate,
       member_location_ids, operators, charging_point_count,
       known_available_count, known_unavailable_count, unknown_count,
       availability_complete, maximum_power_kw, source_summaries, data_updated_at
     ) VALUES (
       $1, $2, 'Fixture Park',
       ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
       ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
       ARRAY[$2]::uuid[], ARRAY['Fixture Operator'], 4,
       $5, $6, $7, $7 = 0, 150, $8::jsonb, '2026-07-07T00:00:00Z'
     )`,
    [
      projectionId,
      input.parkId,
      input.longitude,
      input.latitude,
      knownAvailable,
      knownUnavailable,
      unknown,
      JSON.stringify([
        {
          id: bundesnetzagenturDescriptor.id,
          name: bundesnetzagenturDescriptor.name,
          qualityTier: "authority",
          staticObservedAt: "2026-07-07T00:00:00.000Z",
        },
      ]),
    ],
  );
}

function indexedUUID(prefix: number, index: number): string {
  return `${prefix}0000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
}

function swissStaticObservations(): NormalizedLocationObservation[] {
  return [1, 2, 3, 4].map((index) => {
    const nativeIdentity = `CH*ABC*E${index}`;
    const providerEVSEKey = `CHABCE${index}`;
    const sourceReference = {
      providerId: ichTankeStromDescriptor.id,
      sourceRecordId: nativeIdentity,
      qualityTier: "authority" as const,
      observedAt: "2026-08-14T08:00:00.000Z",
      fetchedAt: "2026-08-14T08:00:01.000Z",
      contentHash: index.toString(16).repeat(64),
    };
    return {
      location: {
        id: indexedUUID(6, index),
        name: "Swiss Live Park",
        operatorName: "Swiss Operator",
        coordinate: { latitude: 52, longitude: 10.01 },
        address: {},
        chargingPoints: [
          {
            id: indexedUUID(7, index),
            nativeIdentity,
            providerEVSEKey,
            canonicalEVSEIdentity: providerEVSEKey,
            identityDecision: "exact" as const,
            connectors: [{ sourceValue: "CCS Combo 2 Plug" }],
            maximumPowerKW: 150,
            availability: { state: "unknown" as const, isLive: false },
            sourceReference,
          },
        ],
        active: true,
        sourceReference,
      },
      rawPayload: { EvseID: nativeIdentity },
    };
  });
}

function swissLiveObservations(): NormalizedAvailabilityObservation[] {
  const states = ["available", "occupied", "unknown"] as const;
  return states.map((state, offset) => {
    const index = offset + 1;
    const nativeIdentity = `CH*ABC*E${index}`;
    return {
      providerEVSEKey: `CHABCE${index}`,
      nativeIdentity,
      state,
      observedAt: "2026-08-14T08:59:00.000Z",
      sourceReference: {
        providerId: ichTankeStromDescriptor.id,
        sourceRecordId: nativeIdentity,
        qualityTier: "authority",
        observedAt: "2026-08-14T08:59:00.000Z",
        fetchedAt: "2026-08-14T08:59:01.000Z",
        contentHash: (offset + 5).toString(16).repeat(64),
      },
    };
  });
}

function swissAuthorityStaticPayload() {
  return {
    EVSEData: [
      {
        OperatorID: "CH*ABC",
        OperatorName: "Swiss Authority Operator",
        EVSEDataRecord: [1, 2].map((index) => ({
          Address: {
            City: "Bern",
            Country: "CHE",
            PostalCode: "3000",
            Street: "Bahnhofplatz 1",
            Region: null,
          },
          ChargingFacilities: [{ power: "150.0" }],
          ChargingStationNames: [{ lang: "de", value: "Behörden-Ladepark Bern" }],
          EvseID: `CH*ABC*E${index}`,
          GeoCoordinates: { Google: `46.948${index} 7.4474` },
          Plugs: ["CCS Combo 2 Plug"],
        })),
      },
    ],
  };
}

function swissAuthorityLivePayload() {
  return {
    EVSEStatuses: [
      {
        OperatorID: "CH*ABC",
        OperatorName: "Swiss Authority Operator",
        EVSEStatusRecord: [
          { EvseID: "CH*ABC*E1", EVSEStatus: "Available" },
          { EvseID: "CH*ABC*E2", EVSEStatus: "Occupied" },
        ],
      },
    ],
  };
}

function assertDedicatedTestDatabase(value: string): void {
  const databaseName = new URL(value).pathname.slice(1);
  if (!databaseName.endsWith("_test")) {
    throw new Error("PostGIS integration tests require a database ending in _test.");
  }
}
