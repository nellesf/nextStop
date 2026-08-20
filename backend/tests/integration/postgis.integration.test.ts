import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";

import type { Pool } from "pg";

import { PostGISCandidateSearch } from "../../src/application/postgis-candidate-search.js";
import { SignedPaginationCodec } from "../../src/application/signed-pagination.js";
import {
  buildChargingCampusProjection,
  buildChargingParkProjection,
  findEVSEIdentityConflicts,
} from "../../src/domain/charging-park-projection.js";
import type {
  NormalizedChargingLocation,
  NormalizedLocationObservation,
} from "../../src/domain/normalized-charging.js";
import { createDatabasePool } from "../../src/persistence/database.js";
import { AvailabilitySnapshotWriter } from "../../src/persistence/availability-snapshot-writer.js";
import { FoodPOIProjectionWriter } from "../../src/persistence/food-poi-projection-writer.js";
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
import {
  minimumPowerOptions,
  type SearchRequest,
} from "../../src/domain/candidate-search.js";
import type { OpenStreetMapFoodPOIRecord } from "../../src/providers/openstreetmap/pbf-provider.js";

const connectionString = process.env.TEST_DATABASE_URL;
const signingKey = "integration-test-signing-key-with-at-least-32-bytes";
const fixturePath = fileURLToPath(
  new URL("../fixtures/bundesnetzagentur/sample.csv", import.meta.url),
);
const versionSevenMigrations = [
  "0001_initial_postgis_projection.sql",
  "0002_live_availability_snapshots.sql",
  "0003_operator_charging_point_counts.sql",
  "0004_osm_food_poi_projection.sql",
  "0005_power_search_projection.sql",
  "0006_power_projection_work_memory.sql",
  "0007_power_projection_spatial_lookup.sql",
] as const;
const conditionalCampusMigration = "0008_conditional_charging_campus.sql";

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
      const campuses = buildChargingCampusProjection(locations, parks);
      await writer.writeParks(projectionId, parks);
      await writer.writeCampuses(projectionId, campuses);
      await writer.publish(
        projectionId,
        {
          locationCount: 3,
          chargingPointCount: 5,
          parkCount: 1,
          campusCount: 1,
          quarantineCount: 1,
          conflictCount: 0,
        },
        "2026-08-14T08:00:00.000Z",
      );

      const counts = await pool.query<{
        readonly locations: number;
        readonly points: number;
        readonly parks: number;
        readonly campuses: number;
        readonly quarantines: number;
      }>(`SELECT
            (SELECT count(*)::integer FROM nextstop.normalized_charging_locations) AS locations,
            (SELECT count(*)::integer FROM nextstop.normalized_charging_points) AS points,
            (SELECT count(*)::integer FROM nextstop.charging_park_projection) AS parks,
            (SELECT count(*)::integer FROM nextstop.charging_campus_projection) AS campuses,
            (SELECT count(*)::integer FROM nextstop.provider_quarantine) AS quarantines`);
      assert.deepEqual(counts.rows[0], {
        locations: 3,
        points: 5,
        parks: 1,
        campuses: 1,
        quarantines: 1,
      });
      const search = candidateSearch(pool);
      const baseRequest = searchRequest([
        [9.99, 53.55],
        [10.01, 53.55],
      ]);
      const response = await search.search({
        ...baseRequest,
        criteria: { ...baseRequest.criteria, minimumChargingPoints: 2 },
      });
      assert.equal(response.candidates.length, 1);
      assert.equal(response.candidates[0]?.name, "Energie Nord GmbH");
      assert.equal(response.candidates[0]?.chargingPoints, 2);
      assert.deepEqual(response.candidates[0]?.operatorChargingPoints, [
        { name: "Energie Nord GmbH", chargingPoints: 2 },
      ]);
      assert.equal(response.candidates[0]?.availability.unknown, 2);
      assert.equal(response.candidates[0]?.maximumPowerKW, 300);
      assert.deepEqual(response.coverage.activeSources, [bundesnetzagenturDescriptor.id]);
    });

    await context.test(
      "filters EVSE power before operator counts and minimum park size",
      async () => {
        await resetDatabase(pool);
        const projectionId = "12111111-1111-4111-8111-111111111111";
        const writer = new ProjectionWriter(pool);
        const observations = mixedPowerObservations();
        const locations = observations.map(({ location }) => location);
        const parks = buildChargingParkProjection(locations);
        const campuses = buildChargingCampusProjection(locations, parks);
        await writer.create({
          id: projectionId,
          sourceDatasetHash: "9".repeat(64),
          sourceObservedAt: "2026-07-07T00:00:00.000Z",
          builtAt: "2026-08-14T07:00:00.000Z",
          coverageStatus: "complete",
          activeSources: [bundesnetzagenturDescriptor.id],
          unavailableSources: [],
        });
        await writer.writeObservations(projectionId, observations);
        await writer.writeParks(projectionId, parks);
        await writer.writeCampuses(projectionId, campuses);
        await writer.publish(
          projectionId,
          {
            locationCount: 2,
            chargingPointCount: 5,
            parkCount: 1,
            campusCount: 1,
            quarantineCount: 0,
            conflictCount: 0,
          },
          "2026-08-14T08:00:00.000Z",
        );

        const projectedThresholds = await pool.query<{
          readonly minimumPowerKW: number;
          readonly chargingPoints: number;
          readonly operators: string[];
          readonly operatorChargingPoints: {
            readonly name: string;
            readonly chargingPoints: number;
          }[];
        }>(
          `SELECT minimum_power_kw AS "minimumPowerKW",
                  charging_point_count AS "chargingPoints",
                  operators,
                  operator_charging_point_counts AS "operatorChargingPoints"
           FROM nextstop.charging_park_power_projection
           WHERE projection_id = $1
             AND minimum_power_kw IN (50, 300)
           ORDER BY minimum_power_kw`,
          [projectionId],
        );
        assert.deepEqual(projectedThresholds.rows, [
          {
            minimumPowerKW: 50,
            chargingPoints: 5,
            operators: ["Fast Charge GmbH", "Slow Charge GmbH"],
            operatorChargingPoints: [
              { name: "Fast Charge GmbH", chargingPoints: 4 },
              { name: "Slow Charge GmbH", chargingPoints: 1 },
            ],
          },
          {
            minimumPowerKW: 300,
            chargingPoints: 2,
            operators: ["Fast Charge GmbH"],
            operatorChargingPoints: [
              { name: "Fast Charge GmbH", chargingPoints: 2 },
            ],
          },
        ]);

        const baseRequest = searchRequest([
          [10, 52],
          [10.2, 52],
        ]);
        const matching = await candidateSearch(pool).search({
          ...baseRequest,
          criteria: {
            ...baseRequest.criteria,
            minimumChargingPoints: 2,
            minimumPowerKW: 300,
          },
        });
        assert.equal(matching.candidates.length, 1);
        assert.equal(matching.candidates[0]?.chargingPoints, 2);
        assert.equal(matching.candidates[0]?.maximumPowerKW, 300);
        assert.deepEqual(
          matching.candidates[0]?.locationLookups.map(({ operatorName }) => operatorName),
          ["Fast Charge GmbH"],
        );
        assert.deepEqual(matching.candidates[0]?.availability, {
          knownAvailable: 0,
          knownUnavailable: 0,
          unknown: 2,
          total: 2,
          complete: false,
          observedAt: null,
        });
        assert.deepEqual(matching.candidates[0]?.operators, ["Fast Charge GmbH"]);
        assert.deepEqual(matching.candidates[0]?.operatorChargingPoints, [
          { name: "Fast Charge GmbH", chargingPoints: 2 },
        ]);
        assert.equal(matching.candidates[0]?.navigationCoordinate.latitude, 52);

        const tooFew = await candidateSearch(pool).search({
          ...baseRequest,
          criteria: {
            ...baseRequest.criteria,
            minimumChargingPoints: 4,
            minimumPowerKW: 300,
          },
        });
        assert.equal(tooFew.candidates.length, 0);
      },
    );

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

    await context.test(
      "uses cached OSM pairs but enforces the exact 500 m food boundary",
      async () => {
        await resetDatabase(pool);
        const chargingProjectionId = await insertActiveProjection(pool);
        const parkId = "25000000-0000-4000-8000-000000000001";
        await insertPointPark(pool, chargingProjectionId, {
          latitude: 52,
          longitude: 10.05,
          parkId,
        });
        const coordinates = await pool.query<{
          readonly insideLatitude: number;
          readonly insideLongitude: number;
          readonly outsideLatitude: number;
          readonly outsideLongitude: number;
        }>(
          `SELECT
             ST_Y(inside_point::geometry) AS "insideLatitude",
             ST_X(inside_point::geometry) AS "insideLongitude",
             ST_Y(outside_point::geometry) AS "outsideLatitude",
             ST_X(outside_point::geometry) AS "outsideLongitude"
           FROM (
             SELECT ST_Project(origin, 499, 0) AS inside_point,
                    ST_Project(origin, 501, 0) AS outside_point
             FROM (
               SELECT ST_SetSRID(ST_MakePoint(10.05, 52), 4326)::geography AS origin
             ) AS value
           ) AS projected`,
        );
        const coordinate = coordinates.rows[0];
        assert.ok(coordinate);
        const foodProjectionId = "26000000-0000-4000-8000-000000000001";
        const foodWriter = new FoodPOIProjectionWriter(pool);
        await foodWriter.create({
          id: foodProjectionId,
          sourceDatasetHash: "8".repeat(64),
          sourceObservedAt: "2026-08-18T00:00:00.000Z",
          fetchedAt: "2026-08-18T01:00:00.000Z",
          builtAt: "2026-08-18T01:01:00.000Z",
          sourceURLs: ["https://download.geofabrik.de/europe/germany-latest.osm.pbf"],
        });
        await foodWriter.writeRecords(foodProjectionId, [
          foodRecord(1, "mcdonalds", coordinate.insideLatitude, coordinate.insideLongitude),
          foodRecord(2, "burger_king", coordinate.outsideLatitude, coordinate.outsideLongitude),
        ]);
        await foodWriter.publish(
          foodProjectionId,
          2,
          0,
          "2026-08-18T01:02:00.000Z",
        );

        const base = searchRequest([[10, 52], [10.2, 52]]);
        const matching = await candidateSearch(pool).search({
          ...base,
          criteria: { ...base.criteria, foodChain: "mcdonalds" },
        });
        assert.equal(matching.candidates.length, 1);
        assert.equal(matching.candidates[0]?.foodPOI?.name, "McDonald's");
        assert.equal(matching.candidates[0]?.foodPOI?.distanceFromChargingParkMeters, 499);
        assert.equal(matching.attributions[0]?.notice, "© OpenStreetMap contributors");

        const outside = await candidateSearch(pool).search({
          ...base,
          criteria: { ...base.criteria, foodChain: "burger_king" },
        });
        assert.equal(outside.candidates.length, 0);
        assert.equal(outside.attributions.length, 1);
      },
    );

    await context.test(
      "prefilters food from the fine-park base navigation before exact power navigation",
      async () => {
        await resetDatabase(pool);
        const baseCoordinate = { latitude: 52, longitude: 10.05 };
        const powerCoordinate = await projectedCoordinate(pool, baseCoordinate, 199);
        const insideFoodCoordinate = await projectedCoordinate(pool, baseCoordinate, 698);
        const outsideFoodCoordinate = await projectedCoordinate(pool, baseCoordinate, 699.5);
        const chargingProjectionId = "25100000-0000-4000-8000-000000000001";
        const observations = [
          chargingObservation({
            locationID: "25100000-0000-4000-8000-000000000011",
            operatorName: "Base Operator",
            northMeters: 0,
            coordinate: baseCoordinate,
            points: [{ id: "25100000-0000-4000-8000-000000000021", maximumPowerKW: 50 }],
          }),
          chargingObservation({
            locationID: "25100000-0000-4000-8000-000000000012",
            operatorName: "Power Operator",
            northMeters: 0,
            coordinate: powerCoordinate,
            points: [
              { id: "25100000-0000-4000-8000-000000000022", maximumPowerKW: 150 },
              { id: "25100000-0000-4000-8000-000000000023", maximumPowerKW: 150 },
            ],
          }),
        ];
        const locations = observations.map(({ location }) => location);
        const parks = buildChargingParkProjection(locations);
        const campuses = buildChargingCampusProjection(locations, parks);
        assert.equal(parks.length, 1);
        assert.equal(campuses.length, 1);
        assert.deepEqual(parks[0]?.navigationCoordinate, baseCoordinate);

        const writer = new ProjectionWriter(pool);
        await writer.create({
          id: chargingProjectionId,
          sourceDatasetHash: "4".repeat(64),
          sourceObservedAt: "2026-08-20T00:00:00.000Z",
          builtAt: "2026-08-20T00:01:00.000Z",
          coverageStatus: "complete",
          activeSources: [bundesnetzagenturDescriptor.id],
          unavailableSources: [],
        });
        await writer.writeObservations(chargingProjectionId, observations);
        await writer.writeParks(chargingProjectionId, parks);
        await writer.writeCampuses(chargingProjectionId, campuses);
        await writer.publish(
          chargingProjectionId,
          {
            locationCount: 2,
            chargingPointCount: 3,
            parkCount: 1,
            campusCount: 1,
            quarantineCount: 0,
            conflictCount: 0,
          },
          "2026-08-20T00:02:00.000Z",
        );

        const navigationSeparation = await pool.query<{
          readonly distanceMeters: number;
        }>(
          `SELECT round(ST_Distance(
                    park.navigation_coordinate,
                    power.navigation_coordinate
                  ))::integer AS "distanceMeters"
           FROM nextstop.charging_park_projection AS park
           JOIN nextstop.charging_park_power_projection AS power
             ON power.projection_id = park.projection_id
            AND power.park_id = park.park_id
           WHERE park.projection_id = $1
             AND power.minimum_power_kw = 100`,
          [chargingProjectionId],
        );
        assert.equal(navigationSeparation.rows[0]?.distanceMeters, 199);

        const foodProjectionId = "25100000-0000-4000-8000-000000000002";
        const foodWriter = new FoodPOIProjectionWriter(pool);
        await foodWriter.create({
          id: foodProjectionId,
          sourceDatasetHash: "3".repeat(64),
          sourceObservedAt: "2026-08-20T00:03:00.000Z",
          fetchedAt: "2026-08-20T00:04:00.000Z",
          builtAt: "2026-08-20T00:05:00.000Z",
          sourceURLs: ["https://download.geofabrik.de/europe/germany-latest.osm.pbf"],
        });
        await foodWriter.writeRecords(foodProjectionId, [
          foodRecord(
            11,
            "mcdonalds",
            insideFoodCoordinate.latitude,
            insideFoodCoordinate.longitude,
          ),
          foodRecord(
            12,
            "burger_king",
            outsideFoodCoordinate.latitude,
            outsideFoodCoordinate.longitude,
          ),
        ]);
        await foodWriter.publish(
          foodProjectionId,
          2,
          0,
          "2026-08-20T00:06:00.000Z",
        );

        const cached = await pool.query<{
          readonly osmId: string;
          readonly broadDistanceMeters: number;
        }>(
          `SELECT osm_id::text AS "osmId",
                  broad_distance_meters AS "broadDistanceMeters"
           FROM nextstop.charging_park_food_poi_matches
           WHERE charging_projection_id = $1
             AND food_projection_id = $2
           ORDER BY osm_id`,
          [chargingProjectionId, foodProjectionId],
        );
        assert.deepEqual(cached.rows, [
          { osmId: "11", broadDistanceMeters: 698 },
          { osmId: "12", broadDistanceMeters: 700 },
        ]);

        const base = searchRequest([[10, 52], [10.2, 52]]);
        const matching = await candidateSearch(pool).search({
          ...base,
          criteria: {
            ...base.criteria,
            minimumChargingPoints: 2,
            foodChain: "mcdonalds",
          },
        });
        assert.equal(matching.candidates.length, 1);
        assert.equal(matching.candidates[0]?.foodPOI?.distanceFromChargingParkMeters, 499);

        const outside = await candidateSearch(pool).search({
          ...base,
          criteria: {
            ...base.criteria,
            minimumChargingPoints: 2,
            foodChain: "burger_king",
          },
        });
        assert.equal(outside.candidates.length, 0);
      },
    );

    await context.test(
      "uses campuses only without food and keeps restaurant searches on fine parks",
      async () => {
        await resetDatabase(pool);
        const chargingProjectionId = "27000000-0000-4000-8000-000000000001";
        const writer = new ProjectionWriter(pool);
        const observations = conditionalCampusObservations();
        const locations = observations.map(({ location }) => location);
        const parks = buildChargingParkProjection(locations);
        const campuses = buildChargingCampusProjection(locations, parks);
        assert.equal(parks.length, 2);
        assert.equal(campuses.length, 1);
        assert.ok(parks.every(({ chargingPointCount }) => chargingPointCount < 6));
        assert.equal(campuses[0]?.chargingPointCount, 7);
        await writer.create({
          id: chargingProjectionId,
          sourceDatasetHash: "7".repeat(64),
          sourceObservedAt: "2026-07-07T00:00:00.000Z",
          builtAt: "2026-08-20T07:00:00.000Z",
          coverageStatus: "complete",
          activeSources: [bundesnetzagenturDescriptor.id],
          unavailableSources: [],
        });
        await writer.writeObservations(chargingProjectionId, observations);
        await writer.writeParks(chargingProjectionId, parks);
        await writer.writeCampuses(chargingProjectionId, campuses);
        await writer.publish(
          chargingProjectionId,
          {
            locationCount: observations.length,
            chargingPointCount: 8,
            parkCount: parks.length,
            campusCount: campuses.length,
            quarantineCount: 0,
            conflictCount: 0,
          },
          "2026-08-20T08:00:00.000Z",
        );

        const withoutFoodBase = searchRequest([[10, 52], [10.2, 52]]);
        const withoutFood = await candidateSearch(pool).search({
          ...withoutFoodBase,
          criteria: {
            ...withoutFoodBase.criteria,
            minimumChargingPoints: 6,
            minimumPowerKW: 100,
          },
        });
        assert.equal(withoutFood.candidates.length, 1);
        assert.equal(withoutFood.candidates[0]?.id, campuses[0]?.id);
        assert.equal(withoutFood.candidates[0]?.chargingPoints, 7);
        assert.equal(withoutFood.candidates[0]?.locationLookups.length, 3);

        const foodLocation = observations.at(-1)?.location.coordinate;
        assert.ok(foodLocation);

        const foodProjectionId = "28000000-0000-4000-8000-000000000001";
        const foodWriter = new FoodPOIProjectionWriter(pool);
        await foodWriter.create({
          id: foodProjectionId,
          sourceDatasetHash: "6".repeat(64),
          sourceObservedAt: "2026-08-20T00:00:00.000Z",
          fetchedAt: "2026-08-20T01:00:00.000Z",
          builtAt: "2026-08-20T01:01:00.000Z",
          sourceURLs: ["https://download.geofabrik.de/europe/germany-latest.osm.pbf"],
        });
        await foodWriter.writeRecords(foodProjectionId, [
          foodRecord(3, "mcdonalds", foodLocation.latitude, foodLocation.longitude),
        ]);
        await foodWriter.publish(
          foodProjectionId,
          1,
          0,
          "2026-08-20T01:02:00.000Z",
        );

        const cached = await pool.query<{
          readonly parkId: string;
          readonly broadDistanceMeters: number;
          readonly baseNavigationDistanceMeters: number;
        }>(
          `SELECT match.park_id AS "parkId",
                  match.broad_distance_meters AS "broadDistanceMeters",
                  round(ST_Distance(
                    park.navigation_coordinate,
                    food.coordinate
                  ))::integer AS "baseNavigationDistanceMeters"
           FROM nextstop.charging_park_food_poi_matches AS match
           JOIN nextstop.charging_park_projection AS park
             ON park.projection_id = match.charging_projection_id
            AND park.park_id = match.park_id
           JOIN nextstop.food_poi_projection AS food
             ON food.projection_id = match.food_projection_id
            AND food.osm_type = match.osm_type
            AND food.osm_id = match.osm_id
           WHERE match.charging_projection_id = $1
             AND match.food_projection_id = $2
           ORDER BY match.park_id`,
          [chargingProjectionId, foodProjectionId],
        );
        assert.deepEqual(
          cached.rows.map(({ parkId }) => parkId),
          parks.map(({ id }) => id).toSorted(),
        );
        assert.ok(
          cached.rows.every(
            ({ broadDistanceMeters, baseNavigationDistanceMeters }) =>
              broadDistanceMeters === baseNavigationDistanceMeters &&
              broadDistanceMeters <= 700,
          ),
        );

        const fineParkAtSameThreshold = await candidateSearch(pool).search({
          ...withoutFoodBase,
          criteria: {
            ...withoutFoodBase.criteria,
            minimumChargingPoints: 6,
            minimumPowerKW: 100,
            foodChain: "mcdonalds",
          },
        });
        assert.equal(fineParkAtSameThreshold.candidates.length, 0);

        const fineParkMatches = await candidateSearch(pool).search({
          ...withoutFoodBase,
          criteria: {
            ...withoutFoodBase.criteria,
            minimumChargingPoints: 2,
            minimumPowerKW: 100,
            foodChain: "mcdonalds",
          },
        });
        assert.deepEqual(
          fineParkMatches.candidates.map(({ id }) => id).toSorted(),
          parks.map(({ id }) => id).toSorted(),
        );
        assert.ok(
          fineParkMatches.candidates.every(
            ({ foodPOI }) => foodPOI !== undefined && foodPOI !== null,
          ),
        );
      },
    );

    await context.test(
      "keeps a conflicting canonical EVSE identity distinct campuswide, including live data",
      async () => {
        await resetDatabase(pool);
        const projectionId = "29000000-0000-4000-8000-000000000001";
        const writer = new ProjectionWriter(pool);
        const observations = bridgedIdentityConflictObservations();
        const locations = observations.map(({ location }) => location);
        const parks = buildChargingParkProjection(locations);
        const campuses = buildChargingCampusProjection(locations, parks);
        const conflicts = findEVSEIdentityConflicts(locations);
        assert.equal(parks.length, 2);
        assert.equal(campuses.length, 1);
        assert.equal(campuses[0]?.chargingPointCount, 4);
        assert.equal(conflicts.length, 1);
        await writer.create({
          id: projectionId,
          sourceDatasetHash: "5".repeat(64),
          sourceObservedAt: "2026-07-07T00:00:00.000Z",
          builtAt: "2026-08-20T07:00:00.000Z",
          coverageStatus: "complete",
          activeSources: [ichTankeStromDescriptor.id],
          unavailableSources: [],
        });
        await writer.writeObservations(projectionId, observations);
        await writer.writeParks(projectionId, parks);
        await writer.writeCampuses(projectionId, campuses);
        await writer.writeConflicts(projectionId, conflicts);
        await writer.publish(
          projectionId,
          {
            locationCount: 3,
            chargingPointCount: 4,
            parkCount: 2,
            campusCount: 1,
            quarantineCount: 0,
            conflictCount: 1,
          },
          "2026-08-20T08:00:00.000Z",
        );

        const snapshotId = "29100000-0000-4000-8000-000000000001";
        const snapshotWriter = new AvailabilitySnapshotWriter(pool);
        await snapshotWriter.create({
          id: snapshotId,
          providerId: ichTankeStromDescriptor.id,
          sourceHash: "4".repeat(64),
          observedAt: "2026-08-14T08:59:00.000Z",
          fetchedAt: "2026-08-14T08:59:01.000Z",
        });
        const liveObservations: NormalizedAvailabilityObservation[] = observations.flatMap(
          ({ location }) => location.chargingPoints.map((point) => ({
            providerEVSEKey: point.providerEVSEKey ?? point.id,
            nativeIdentity: point.nativeIdentity ?? point.id,
            state: "available",
            observedAt: "2026-08-14T08:59:00.000Z",
            sourceReference: {
              providerId: ichTankeStromDescriptor.id,
              sourceRecordId: `live-${point.id}`,
              qualityTier: "authority",
              observedAt: "2026-08-14T08:59:00.000Z",
              fetchedAt: "2026-08-14T08:59:01.000Z",
              contentHash: point.id.replaceAll("-", "").repeat(2),
            },
          })),
        );
        await snapshotWriter.write(snapshotId, liveObservations);
        await snapshotWriter.publish(
          snapshotId,
          liveObservations.length,
          0,
          "2026-08-14T08:59:02.000Z",
        );

        const projected = await pool.query<{
          readonly chargingPoints: number;
          readonly operatorChargingPoints: {
            readonly name: string;
            readonly chargingPoints: number;
          }[];
        }>(
          `SELECT charging_point_count AS "chargingPoints",
                  operator_charging_point_counts AS "operatorChargingPoints"
           FROM nextstop.charging_campus_power_projection
           WHERE projection_id = $1
             AND minimum_power_kw = 100`,
          [projectionId],
        );
        assert.deepEqual(projected.rows, [{
          chargingPoints: 4,
          operatorChargingPoints: [
            { name: "Alpha", chargingPoints: 1 },
            { name: "Beta", chargingPoints: 2 },
            { name: "Gamma", chargingPoints: 1 },
          ],
        }]);

        const response = await candidateSearch(pool).search(searchRequest([
          [10, 52],
          [10.2, 52],
        ]));
        assert.equal(response.candidates.length, 1);
        assert.equal(response.candidates[0]?.id, campuses[0]?.id);
        assert.equal(response.candidates[0]?.chargingPoints, 4);
        assert.deepEqual(response.candidates[0]?.availability, {
          knownAvailable: 4,
          knownUnavailable: 0,
          unknown: 0,
          total: 4,
          complete: true,
          observedAt: "2026-08-14T08:59:00.000Z",
        });
        assert.deepEqual(response.candidates[0]?.operatorChargingPoints, [
          { name: "Alpha", chargingPoints: 1 },
          { name: "Beta", chargingPoints: 2 },
          { name: "Gamma", chargingPoints: 1 },
        ]);
      },
    );

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
      const campuses = buildChargingCampusProjection(locations, parks);
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
      await writer.writeCampuses(projectionId, campuses);
      await writer.publish(
        projectionId,
        {
          locationCount: 4,
          chargingPointCount: 4,
          parkCount: 1,
          campusCount: 1,
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

    });

    await context.test("keeps availability informational instead of filtering", async () => {
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
        knownUnavailable: 4,
        unknown: 0,
      });

      const response = await candidateSearch(pool).search(
        searchRequest([
          [10, 52],
          [10.2, 52],
        ]),
      );
      assert.deepEqual(
        response.candidates.map((candidate) => candidate.id),
        [
          "30000000-0000-4000-8000-000000000001",
          "30000000-0000-4000-8000-000000000002",
        ],
      );
      assert.deepEqual(response.candidates[1]?.availability, {
        knownAvailable: 0,
        knownUnavailable: 4,
        unknown: 0,
        total: 4,
        complete: true,
        observedAt: null,
      });
    });

    await context.test(
      "keeps a multi-park campus whole across stable cursor pages",
      async () => {
        await resetDatabase(pool);
        const oldProjectionId = "85000000-0000-4000-8000-000000000001";
        const observations = conditionalCampusObservations();
        const locations = observations.map(({ location }) => location);
        const parks = buildChargingParkProjection(locations);
        const campuses = buildChargingCampusProjection(locations, parks);
        const multiParkCampus = campuses[0];
        assert.equal(parks.length, 2);
        assert.ok(multiParkCampus);
        assert.equal(multiParkCampus.memberParkIds.length, 2);
        assert.equal(multiParkCampus.chargingPointCount, 7);

        const writer = new ProjectionWriter(pool);
        await writer.create({
          id: oldProjectionId,
          sourceDatasetHash: "2".repeat(64),
          sourceObservedAt: "2026-08-20T01:00:00.000Z",
          builtAt: "2026-08-20T01:01:00.000Z",
          coverageStatus: "complete",
          activeSources: [bundesnetzagenturDescriptor.id],
          unavailableSources: [],
        });
        await writer.writeObservations(oldProjectionId, observations);
        await writer.writeParks(oldProjectionId, parks);
        await writer.writeCampuses(oldProjectionId, campuses);
        for (let index = 1; index <= 50; index += 1) {
          await insertProjectedPark(pool, oldProjectionId, {
            northMeters: 0,
            eastMeters: index * 50,
            parkId: indexedUUID(8, index),
          });
        }
        await writer.publish(
          oldProjectionId,
          {
            locationCount: 53,
            chargingPointCount: 208,
            parkCount: 52,
            campusCount: 51,
            quarantineCount: 0,
            conflictCount: 0,
          },
          "2026-08-20T01:02:00.000Z",
        );

        const search = candidateSearch(pool);
        const request = searchRequest([
          [10, 52],
          [10.2, 52],
        ]);
        const firstPage = await search.search(request);
        assert.equal(firstPage.candidates.length, 50);
        assert.ok(firstPage.nextCursor);
        assert.equal(
          firstPage.candidates.some(({ id }) => id === multiParkCampus.id),
          false,
        );

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
          requestId: request.requestId,
          criteria: {
            minimumPowerKW: 100,
            minimumChargingPoints: 4,
            distanceRangeMeters: { maximum: 100_000, minimum: 50_000 },
          },
          route: {
            coordinates: request.route.coordinates,
            type: "LineString",
          },
          page: {
            snapshotToken: firstPage.snapshotToken,
            cursor: firstPage.nextCursor,
          },
        });
        assert.equal(secondPage.candidates.length, 1);
        assert.equal(secondPage.nextCursor, null);
        assert.equal(secondPage.snapshotToken, firstPage.snapshotToken);
        assert.equal(secondPage.candidates[0]?.id, multiParkCampus.id);
        assert.equal(secondPage.candidates[0]?.chargingPoints, 7);
        assert.equal(secondPage.candidates[0]?.locationLookups.length, 3);
        assert.equal(
          secondPage.candidates[0]?.operatorChargingPoints.reduce(
            (sum, { chargingPoints }) => sum + chargingPoints,
            0,
          ),
          7,
        );

        const allCandidateIds = [
          ...firstPage.candidates.map(({ id }) => id),
          ...secondPage.candidates.map(({ id }) => id),
        ];
        assert.equal(allCandidateIds.length, 51);
        assert.equal(new Set(allCandidateIds).size, 51);
        assert.equal(
          allCandidateIds.filter((id) => id === multiParkCampus.id).length,
          1,
        );
      },
    );

    await context.test("creates fine and campus power thresholds with GiST indexes", async () => {
      await resetDatabase(pool);
      const projectionId = await insertActiveProjection(pool);
      await insertPointPark(pool, projectionId, {
        latitude: 52,
        longitude: 10.01,
        parkId: "32000000-0000-4000-8000-000000000001",
      });
      const thresholds = await pool.query<{ readonly minimumPowerKW: number }>(
        `SELECT minimum_power_kw AS "minimumPowerKW"
         FROM nextstop.charging_park_power_projection
         WHERE projection_id = $1
         ORDER BY minimum_power_kw`,
        [projectionId],
      );
      assert.deepEqual(
        thresholds.rows.map(({ minimumPowerKW }) => minimumPowerKW),
        minimumPowerOptions.filter((minimumPowerKW) => minimumPowerKW <= 150),
      );
      const campusThresholds = await pool.query<{ readonly minimumPowerKW: number }>(
        `SELECT minimum_power_kw AS "minimumPowerKW"
         FROM nextstop.charging_campus_power_projection
         WHERE projection_id = $1
         ORDER BY minimum_power_kw`,
        [projectionId],
      );
      assert.deepEqual(campusThresholds.rows, thresholds.rows);
      const indexes = await pool.query<{ readonly indexname: string }>(
        `SELECT indexname
         FROM pg_indexes
         WHERE schemaname = 'nextstop'
           AND indexname IN (
             'charging_park_power_projection_lookup_gist',
             'charging_campus_power_projection_lookup_gist'
           )
         ORDER BY indexname`,
      );
      assert.deepEqual(indexes.rows.map(({ indexname }) => indexname), [
        "charging_campus_power_projection_lookup_gist",
        "charging_park_power_projection_lookup_gist",
      ]);
      const functionSettings = await pool.query<{
        readonly settings: string[] | null;
      }>(
        `SELECT procedure.proconfig AS settings
         FROM pg_proc AS procedure
         JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
         WHERE namespace.nspname = 'nextstop'
           AND procedure.proname IN (
             'rebuild_charging_park_power_projection',
             'rebuild_charging_campus_power_projection'
           )
         ORDER BY procedure.proname`,
      );
      assert.equal(functionSettings.rows.length, 2);
      assert.ok(functionSettings.rows.every(({ settings }) => settings?.includes("work_mem=128MB")));
      await pool.query("SET enable_seqscan = off");
      const plan = await pool.query<{ readonly "QUERY PLAN": unknown }>(
         `EXPLAIN (FORMAT JSON)
         SELECT park_id
         FROM nextstop.charging_park_power_projection
         WHERE projection_id = $1
           AND minimum_power_kw = 100
         ORDER BY navigation_coordinate <->
           ST_SetSRID(ST_MakePoint(10, 52), 4326)::geography
         LIMIT 1`,
        [projectionId],
      );
      assert.match(
        JSON.stringify(plan.rows),
        /charging_park_power_projection_lookup_gist/u,
      );
      const campusPlan = await pool.query<{ readonly "QUERY PLAN": unknown }>(
        `EXPLAIN (FORMAT JSON)
         SELECT campus_id
         FROM nextstop.charging_campus_power_projection
         WHERE projection_id = $1
           AND minimum_power_kw = 100
         ORDER BY navigation_coordinate <->
           ST_SetSRID(ST_MakePoint(10, 52), 4326)::geography
         LIMIT 1`,
        [projectionId],
      );
      assert.match(
        JSON.stringify(campusPlan.rows),
        /charging_campus_power_projection_lookup_gist/u,
      );
      await pool.query("RESET enable_seqscan");
    });

    await context.test(
      "backfills a populated v7 schema into searchable singleton campuses",
      async () => {
        await pool.query("DROP SCHEMA IF EXISTS nextstop CASCADE");
        for (const migrationName of versionSevenMigrations) {
          await applyMigration(pool, migrationName);
        }

        const projectionId = "86000000-0000-4000-8000-000000000001";
        const firstParkId = "86100000-0000-4000-8000-000000000001";
        const secondParkId = "86100000-0000-4000-8000-000000000002";
        const foodProjectionId = "87000000-0000-4000-8000-000000000001";
        await insertProjection(pool, projectionId, "active");
        await insertLegacyFinePark(pool, projectionId, {
          latitude: 52,
          longitude: 10.05,
          operatorName: "Alpha Charge",
          parkId: firstParkId,
          pointPowersKW: [150, 150, 50],
        });
        await insertLegacyFinePark(pool, projectionId, {
          latitude: 52.018,
          longitude: 10.05,
          operatorName: "Beta Charge",
          parkId: secondParkId,
          pointPowersKW: [300, 300],
        });
        await pool.query(
          `UPDATE nextstop.projection_versions
           SET location_count = 2,
               charging_point_count = 5,
               park_count = 2
           WHERE id = $1`,
          [projectionId],
        );

        await pool.query(
          `INSERT INTO nextstop.food_poi_projection_versions (
             id, source_dataset_hash, source_observed_at, fetched_at, built_at,
             published_at, status, source_urls, poi_count, quarantine_count
           ) VALUES (
             $1, $2, '2026-08-18T00:00:00Z', '2026-08-18T01:00:00Z',
             '2026-08-18T01:01:00Z', '2026-08-18T01:02:00Z', 'active',
             ARRAY['https://download.geofabrik.de/europe/germany-latest.osm.pbf'], 1, 0
           )`,
          [foodProjectionId, "f".repeat(64)],
        );
        await pool.query(
          `INSERT INTO nextstop.food_poi_projection (
             projection_id, osm_type, osm_id, chain, name, coordinate,
             address, match_method, source_record_url, source_observed_at, fetched_at
           )
           SELECT $1, 'node', 88001, 'mcdonalds', 'Upgrade Restaurant',
                  ST_Project(park.navigation_coordinate, 300, 0),
                  '{}'::jsonb, 'brand_wikidata',
                  'https://www.openstreetmap.org/node/88001',
                  '2026-08-18T00:00:00Z', '2026-08-18T01:00:00Z'
           FROM nextstop.charging_park_projection AS park
           WHERE park.projection_id = $2 AND park.park_id = $3`,
          [foodProjectionId, projectionId, firstParkId],
        );
        await pool.query(
          `INSERT INTO nextstop.charging_park_food_poi_matches (
             charging_projection_id, food_projection_id, park_id,
             osm_type, osm_id, broad_distance_meters
           ) VALUES ($1, $2, $3, 'node', 88001, 0)`,
          [projectionId, foodProjectionId, firstParkId],
        );

        const stalePower = await pool.query<{
          readonly chargingPointCount: number;
        }>(
          `SELECT charging_point_count AS "chargingPointCount"
           FROM nextstop.charging_park_power_projection
           WHERE projection_id = $1 AND park_id = $2 AND minimum_power_kw = 100`,
          [projectionId, firstParkId],
        );
        assert.deepEqual(stalePower.rows, [{ chargingPointCount: 1 }]);

        await applyMigration(pool, conditionalCampusMigration);

        const migrations = await pool.query<{ readonly name: string }>(
          `SELECT name
           FROM nextstop.schema_migrations
           ORDER BY name`,
        );
        assert.deepEqual(
          migrations.rows.map(({ name }) => name),
          [...versionSevenMigrations, conditionalCampusMigration],
        );

        const campuses = await pool.query<{
          readonly campusId: string;
          readonly memberParkIds: string[];
          readonly memberLocationIds: string[];
        }>(
          `SELECT campus_id AS "campusId",
                  member_park_ids AS "memberParkIds",
                  member_location_ids AS "memberLocationIds"
           FROM nextstop.charging_campus_projection
           WHERE projection_id = $1
           ORDER BY campus_id`,
          [projectionId],
        );
        assert.deepEqual(campuses.rows, [
          {
            campusId: firstParkId,
            memberParkIds: [firstParkId],
            memberLocationIds: [firstParkId],
          },
          {
            campusId: secondParkId,
            memberParkIds: [secondParkId],
            memberLocationIds: [secondParkId],
          },
        ]);
        const projectionCounts = await pool.query<{
          readonly campusCount: number;
          readonly parkCount: number;
        }>(
          `SELECT campus_count AS "campusCount", park_count AS "parkCount"
           FROM nextstop.projection_versions
           WHERE id = $1`,
          [projectionId],
        );
        assert.deepEqual(projectionCounts.rows, [{ campusCount: 2, parkCount: 2 }]);

        const campusPower = await pool.query<{
          readonly campusId: string;
          readonly chargingPointCount: number;
          readonly maximumPowerKW: number;
          readonly operatorChargingPoints: {
            readonly name: string;
            readonly chargingPoints: number;
          }[];
        }>(
          `SELECT campus_id AS "campusId",
                  charging_point_count AS "chargingPointCount",
                  maximum_power_kw AS "maximumPowerKW",
                  operator_charging_point_counts AS "operatorChargingPoints"
           FROM nextstop.charging_campus_power_projection
           WHERE projection_id = $1 AND minimum_power_kw = 100
           ORDER BY campus_id`,
          [projectionId],
        );
        assert.deepEqual(campusPower.rows, [
          {
            campusId: firstParkId,
            chargingPointCount: 2,
            maximumPowerKW: 150,
            operatorChargingPoints: [{ name: "Alpha Charge", chargingPoints: 2 }],
          },
          {
            campusId: secondParkId,
            chargingPointCount: 2,
            maximumPowerKW: 300,
            operatorChargingPoints: [{ name: "Beta Charge", chargingPoints: 2 }],
          },
        ]);

        const retainedFoodMatches = await pool.query<{
          readonly actualDistanceMeters: number;
          readonly broadDistanceMeters: number;
          readonly parkId: string;
        }>(
          `SELECT match.park_id AS "parkId",
                  match.broad_distance_meters AS "broadDistanceMeters",
                  round(ST_Distance(
                    park.navigation_coordinate,
                    food.coordinate
                  ))::integer AS "actualDistanceMeters"
           FROM nextstop.charging_park_food_poi_matches AS match
           JOIN nextstop.charging_park_projection AS park
             ON park.projection_id = match.charging_projection_id
            AND park.park_id = match.park_id
           JOIN nextstop.food_poi_projection AS food
             ON food.projection_id = match.food_projection_id
            AND food.osm_type = match.osm_type
            AND food.osm_id = match.osm_id
           WHERE match.charging_projection_id = $1
             AND match.food_projection_id = $2`,
          [projectionId, foodProjectionId],
        );
        assert.deepEqual(retainedFoodMatches.rows, [{
          actualDistanceMeters: 300,
          broadDistanceMeters: 300,
          parkId: firstParkId,
        }]);

        const request = searchRequest([
          [10, 52],
          [10.2, 52],
        ]);
        const response = await candidateSearch(pool).search({
          ...request,
          criteria: {
            ...request.criteria,
            minimumChargingPoints: 2,
          },
        });
        assert.deepEqual(
          response.candidates.map(({ id }) => id),
          [firstParkId, secondParkId],
        );
        assert.equal(response.nextCursor, null);
        const snapshot = new SignedPaginationCodec(signingKey).decodeSnapshot(
          response.snapshotToken,
        );
        assert.equal(snapshot.projectionId, projectionId);
        assert.equal(snapshot.foodProjectionId, null);
        assert.deepEqual(snapshot.availabilitySnapshotIds, []);
      },
    );
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
              nextstop.food_poi_projection_versions,
              nextstop.provider_records
     CASCADE`,
  );
}

async function applyMigration(pool: Pool, migrationName: string): Promise<void> {
  const migration = await readFile(
    new URL(`../../migrations/${migrationName}`, import.meta.url),
    "utf8",
  );
  await pool.query(migration);
}

function foodRecord(
  id: number,
  chain: "mcdonalds" | "burger_king",
  latitude: number,
  longitude: number,
): OpenStreetMapFoodPOIRecord {
  return {
    osmType: "node",
    osmId: id,
    chain,
    name: chain === "mcdonalds" ? "McDonald's" : "Burger King",
    geometry: { type: "Point", coordinates: [longitude, latitude] },
    address: {},
    matchMethod: "brand_wikidata",
    sourceRecordURL: `https://www.openstreetmap.org/node/${id}`,
    sourceObservedAt: "2026-08-18T00:00:00.000Z",
    fetchedAt: "2026-08-18T01:00:00.000Z",
  };
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

interface LegacyFineParkInput {
  readonly latitude: number;
  readonly longitude: number;
  readonly operatorName: string;
  readonly parkId: string;
  readonly pointPowersKW: readonly number[];
}

async function insertLegacyFinePark(
  pool: Pool,
  projectionId: string,
  input: LegacyFineParkInput,
): Promise<void> {
  const maximumPowerKW = Math.max(...input.pointPowersKW);
  const pointRows = input.pointPowersKW.map((maximumPower, index) => ({
    charging_point_id: randomUUID(),
    maximum_power_kw: maximumPower,
    provider_evse_key: `${input.parkId}-${index}`,
  }));
  await pool.query(
    `INSERT INTO nextstop.normalized_charging_locations (
       projection_id, location_id, name, operator_name, coordinate,
       address, active, source_reference
     ) VALUES (
       $1, $2, $3, $3,
       ST_SetSRID(ST_MakePoint($4, $5), 4326)::geography,
       '{}'::jsonb, true, '{}'::jsonb
     )`,
    [
      projectionId,
      input.parkId,
      input.operatorName,
      input.longitude,
      input.latitude,
    ],
  );
  await pool.query(
    `INSERT INTO nextstop.normalized_charging_points (
       projection_id, charging_point_id, location_id, provider_id,
       provider_evse_key, identity_decision, connectors, maximum_power_kw,
       availability_state, availability_is_live, source_reference
     )
     SELECT $1,
            item.charging_point_id,
            $2,
            $3,
            item.provider_evse_key,
            'unresolved',
            jsonb_build_array(jsonb_build_object(
              'sourceValue', 'fixture',
              'maximumPowerKW', item.maximum_power_kw
            )),
            item.maximum_power_kw,
            'unknown',
            false,
            '{}'::jsonb
     FROM jsonb_to_recordset($4::jsonb) AS item(
       charging_point_id uuid,
       maximum_power_kw integer,
       provider_evse_key text
     )`,
    [
      projectionId,
      input.parkId,
      bundesnetzagenturDescriptor.id,
      JSON.stringify(pointRows),
    ],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_park_projection (
       projection_id, park_id, name, centroid, navigation_coordinate,
       member_location_ids, operators, operator_charging_point_counts,
       charging_point_count, known_available_count, known_unavailable_count,
       unknown_count, availability_complete, maximum_power_kw,
       source_summaries, data_updated_at
     ) VALUES (
       $1, $2, $3,
       ST_SetSRID(ST_MakePoint($4, $5), 4326)::geography,
       ST_SetSRID(ST_MakePoint($4, $5), 4326)::geography,
       ARRAY[$2]::uuid[], ARRAY[$3]::text[], $6::jsonb,
       $7, 0, 0, $7, false, $8, $9::jsonb, '2026-07-07T00:00:00Z'
     )`,
    [
      projectionId,
      input.parkId,
      input.operatorName,
      input.longitude,
      input.latitude,
      JSON.stringify([{
        operatorName: input.operatorName,
        chargingPointCount: input.pointPowersKW.length,
      }]),
      input.pointPowersKW.length,
      maximumPowerKW,
      JSON.stringify([{
        id: bundesnetzagenturDescriptor.id,
        name: bundesnetzagenturDescriptor.name,
        qualityTier: "authority",
        staticObservedAt: "2026-07-07T00:00:00.000Z",
      }]),
    ],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_park_location_memberships (
       projection_id, park_id, location_id
     ) VALUES ($1, $2, $2)`,
    [projectionId, input.parkId],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_park_power_projection (
       projection_id, park_id, minimum_power_kw, centroid,
       navigation_coordinate, charging_point_count, known_available_count,
       known_unavailable_count, unknown_count, maximum_power_kw, operators,
       operator_charging_point_counts
     )
     SELECT park.projection_id, park.park_id, 100, park.centroid,
            park.navigation_coordinate, 1, 0, 0, 1, $3,
            ARRAY[$4]::text[], $5::jsonb
     FROM nextstop.charging_park_projection AS park
     WHERE park.projection_id = $1 AND park.park_id = $2`,
    [
      projectionId,
      input.parkId,
      maximumPowerKW,
      input.operatorName,
      JSON.stringify([{ name: input.operatorName, chargingPoints: 1 }]),
    ],
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
  const point = await projectedCoordinate(
    pool,
    { latitude: 52, longitude: 10 },
    input.northMeters,
    input.eastMeters ?? 0,
  );
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

async function projectedCoordinate(
  pool: Pool,
  origin: Readonly<{ latitude: number; longitude: number }>,
  northMeters: number,
  eastMeters = 0,
): Promise<Readonly<{ latitude: number; longitude: number }>> {
  const coordinate = await pool.query<{
    readonly latitude: number;
    readonly longitude: number;
  }>(
    `SELECT ST_Y(projected::geometry) AS latitude,
            ST_X(projected::geometry) AS longitude
     FROM (
       SELECT ST_Project(
         ST_Project(
           ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
           $3::double precision,
           pi() / 2
         ),
         $4::double precision,
         0::double precision
       ) AS projected
     ) AS point`,
    [origin.longitude, origin.latitude, eastMeters, northMeters],
  );
  const point = coordinate.rows[0];
  assert.ok(point);
  return point;
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
    `INSERT INTO nextstop.normalized_charging_locations (
       projection_id, location_id, name, operator_name, coordinate,
       address, active, source_reference
     ) VALUES (
       $1, $2, 'Fixture Park', 'Fixture Operator',
       ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
       '{}'::jsonb, true, '{}'::jsonb
     )`,
    [projectionId, input.parkId, input.longitude, input.latitude],
  );
  const pointRows = Array.from({ length: 4 }, (_, index) => {
    const state =
      index < knownAvailable
        ? "available"
        : index < knownAvailable + knownUnavailable
          ? "occupied"
          : "unknown";
    return {
      charging_point_id: randomUUID(),
      provider_id: bundesnetzagenturDescriptor.id,
      provider_evse_key: `${input.parkId}-${index}`,
      maximum_power_kw: 150,
      availability_state: state,
      availability_is_live: state !== "unknown",
    };
  });
  await pool.query(
    `INSERT INTO nextstop.normalized_charging_points (
       projection_id, charging_point_id, location_id, provider_id,
       provider_evse_key, identity_decision, connectors, maximum_power_kw,
       availability_state, availability_is_live, source_reference
     )
     SELECT $1,
            charging_point_id,
            $2,
            provider_id,
            provider_evse_key,
            'unresolved',
            '[{"sourceValue":"fixture","maximumPowerKW":150}]'::jsonb,
            maximum_power_kw,
            availability_state,
            availability_is_live,
            '{}'::jsonb
     FROM jsonb_to_recordset($3::jsonb) AS item(
       charging_point_id uuid,
       provider_id text,
       provider_evse_key text,
       maximum_power_kw integer,
       availability_state text,
       availability_is_live boolean
     )`,
    [projectionId, input.parkId, JSON.stringify(pointRows)],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_park_projection (
       projection_id, park_id, name, centroid, navigation_coordinate,
       member_location_ids, operators, operator_charging_point_counts, charging_point_count,
       known_available_count, known_unavailable_count, unknown_count,
       availability_complete, maximum_power_kw, source_summaries, data_updated_at
     ) VALUES (
       $1, $2, 'Fixture Park',
       ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
       ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
       ARRAY[$2]::uuid[], ARRAY['Fixture Operator'],
       '[{"operatorName":"Fixture Operator","chargingPointCount":4}]'::jsonb, 4,
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
  await pool.query(
    `INSERT INTO nextstop.charging_park_location_memberships (
       projection_id, park_id, location_id
     ) VALUES ($1, $2, $2)`,
    [projectionId, input.parkId],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_park_power_projection (
       projection_id, park_id, minimum_power_kw, centroid,
       navigation_coordinate, charging_point_count, known_available_count,
       known_unavailable_count, unknown_count, maximum_power_kw, operators,
       operator_charging_point_counts
     )
     SELECT $1, $2, threshold.minimum_power_kw,
            ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
            ST_SetSRID(ST_MakePoint($3, $4), 4326)::geography,
            4, $5, $6, $7, 150, ARRAY['Fixture Operator'],
            '[{"name":"Fixture Operator","chargingPoints":4}]'::jsonb
     FROM (VALUES (11), (22), (50), (100), (150))
       AS threshold(minimum_power_kw)`,
    [
      projectionId,
      input.parkId,
      input.longitude,
      input.latitude,
      knownAvailable,
      knownUnavailable,
      unknown,
    ],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_campus_projection (
       projection_id, campus_id, name, centroid, navigation_coordinate,
       member_park_ids, member_location_ids, operators,
       operator_charging_point_counts, charging_point_count,
       known_available_count, known_unavailable_count, unknown_count,
       availability_complete, last_live_observation_at, maximum_power_kw,
       source_summaries, data_updated_at
     )
     SELECT projection_id, park_id, name, centroid, navigation_coordinate,
            ARRAY[park_id], member_location_ids, operators,
            operator_charging_point_counts, charging_point_count,
            known_available_count, known_unavailable_count, unknown_count,
            availability_complete, last_live_observation_at, maximum_power_kw,
            source_summaries, data_updated_at
     FROM nextstop.charging_park_projection
     WHERE projection_id = $1 AND park_id = $2`,
    [projectionId, input.parkId],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_campus_park_memberships (
       projection_id, campus_id, park_id
     ) VALUES ($1, $2, $2)`,
    [projectionId, input.parkId],
  );
  await pool.query(
    `INSERT INTO nextstop.charging_campus_power_projection (
       projection_id, campus_id, minimum_power_kw, centroid,
       navigation_coordinate, charging_point_count, known_available_count,
       known_unavailable_count, unknown_count, last_live_observation_at,
       maximum_power_kw, operators, operator_charging_point_counts
     )
     SELECT projection_id, park_id, minimum_power_kw, centroid,
            navigation_coordinate, charging_point_count, known_available_count,
            known_unavailable_count, unknown_count, last_live_observation_at,
            maximum_power_kw, operators, operator_charging_point_counts
     FROM nextstop.charging_park_power_projection
     WHERE projection_id = $1 AND park_id = $2`,
    [projectionId, input.parkId],
  );
  await pool.query(
    `UPDATE nextstop.projection_versions
     SET campus_count = (
       SELECT count(*)::integer
       FROM nextstop.charging_campus_projection
       WHERE projection_id = $1
     )
     WHERE id = $1`,
    [projectionId],
  );
}

function indexedUUID(prefix: number, index: number): string {
  return `${prefix}0000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
}

function mixedPowerObservations(): NormalizedLocationObservation[] {
  const makeLocation = (
    locationID: string,
    operatorName: string,
    powers: readonly number[],
    latitude: number,
  ): NormalizedLocationObservation => {
    const locationSource = {
      providerId: bundesnetzagenturDescriptor.id,
      sourceRecordId: `location-${locationID}`,
      qualityTier: "authority" as const,
      observedAt: "2026-07-07T00:00:00.000Z",
      fetchedAt: "2026-08-14T07:00:00.000Z",
      contentHash: locationID.replaceAll("-", "").padEnd(64, "0").slice(0, 64),
    };
    return {
      location: {
        id: locationID,
        name: operatorName,
        operatorName,
        coordinate: { latitude, longitude: 10.01 },
        address: {},
        chargingPoints: powers.map((maximumPowerKW, index) => {
          const id = indexedUUID(operatorName === "Fast Charge GmbH" ? 8 : 9, index + 1);
          return {
            id,
            providerEVSEKey: `${locationID}-${index}`,
            identityDecision: "unresolved" as const,
            connectors: [{ sourceValue: "fixture", maximumPowerKW }],
            maximumPowerKW,
            availability: { state: "unknown" as const, isLive: false },
            sourceReference: {
              ...locationSource,
              sourceRecordId: `point-${id}`,
              contentHash: id.replaceAll("-", "").padEnd(64, "0").slice(0, 64),
            },
          };
        }),
        active: true,
        sourceReference: locationSource,
      },
      rawPayload: { fixture: operatorName },
    };
  };
  return [
    makeLocation(
      "81000000-0000-4000-8000-000000000001",
      "Fast Charge GmbH",
      [50, 300, 300, 50],
      52,
    ),
    makeLocation(
      "91000000-0000-4000-8000-000000000001",
      "Slow Charge GmbH",
      [50],
      52.0005,
    ),
  ];
}

function conditionalCampusObservations(): NormalizedLocationObservation[] {
  const sharedCanonicalEVSEIdentity = "DEABCCAMPUSDEDUP";
  return [0, 150, 300].map((northMeters, index) =>
    chargingObservation({
      locationID: indexedUUID(2, index + 1),
      operatorName: `Campus Operator ${index + 1}`,
      northMeters,
      points: [1, 2, ...(index === 1 ? [] : [3])].map((pointIndex) => ({
        id: indexedUUID(3 + index, pointIndex),
        maximumPowerKW: 150,
        ...(
          pointIndex === 1 && index >= 1
            ? { canonicalEVSEIdentity: sharedCanonicalEVSEIdentity }
            : {}
        ),
      })),
    }),
  );
}

function bridgedIdentityConflictObservations(): NormalizedLocationObservation[] {
  const canonicalEVSEIdentity = "DEABCEBRIDGED";
  return [
    chargingObservation({
      locationID: indexedUUID(4, 1),
      operatorName: "Alpha",
      northMeters: 0,
      providerID: ichTankeStromDescriptor.id,
      points: [{
        id: indexedUUID(5, 1),
        maximumPowerKW: 150,
        canonicalEVSEIdentity,
      }],
    }),
    chargingObservation({
      locationID: indexedUUID(4, 2),
      operatorName: "Beta",
      northMeters: 150,
      providerID: ichTankeStromDescriptor.id,
      points: [
        { id: indexedUUID(5, 2), maximumPowerKW: 150 },
        { id: indexedUUID(5, 3), maximumPowerKW: 150 },
      ],
    }),
    chargingObservation({
      locationID: indexedUUID(4, 3),
      operatorName: "Gamma",
      northMeters: 300,
      providerID: ichTankeStromDescriptor.id,
      points: [{
        id: indexedUUID(5, 4),
        maximumPowerKW: 150,
        canonicalEVSEIdentity,
      }],
    }),
  ];
}

interface ChargingObservationInput {
  readonly locationID: string;
  readonly operatorName: string;
  readonly northMeters: number;
  readonly coordinate?: Readonly<{ latitude: number; longitude: number }>;
  readonly providerID?: string;
  readonly points: readonly Readonly<{
    id: string;
    maximumPowerKW: number;
    canonicalEVSEIdentity?: string;
  }>[];
}

function chargingObservation(input: ChargingObservationInput): NormalizedLocationObservation {
  const sourceReference = {
    providerId: input.providerID ?? bundesnetzagenturDescriptor.id,
    sourceRecordId: `location-${input.locationID}`,
    qualityTier: "authority" as const,
    observedAt: "2026-07-07T00:00:00.000Z",
    fetchedAt: "2026-08-20T07:00:00.000Z",
    contentHash: input.locationID.replaceAll("-", "").repeat(2),
  };
  return {
    location: {
      id: input.locationID,
      name: input.operatorName,
      operatorName: input.operatorName,
      coordinate: input.coordinate ?? {
        latitude: 52 + input.northMeters / 111_267,
        longitude: 10.05,
      },
      address: {},
      chargingPoints: input.points.map((point) => ({
        id: point.id,
        providerEVSEKey: `fixture-${point.id}`,
        ...(point.canonicalEVSEIdentity === undefined
          ? {}
          : { canonicalEVSEIdentity: point.canonicalEVSEIdentity }),
        identityDecision:
          point.canonicalEVSEIdentity === undefined ? "unresolved" as const : "exact" as const,
        connectors: [{ sourceValue: "fixture", maximumPowerKW: point.maximumPowerKW }],
        maximumPowerKW: point.maximumPowerKW,
        availability: { state: "unknown" as const, isLive: false },
        sourceReference: {
          ...sourceReference,
          sourceRecordId: `point-${point.id}`,
          contentHash: point.id.replaceAll("-", "").repeat(2),
        },
      })),
      active: true,
      sourceReference,
    },
    rawPayload: { fixture: input.operatorName },
  };
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
