import assert from "node:assert/strict";
import test from "node:test";

import { readIchTankeStromLiveFeed } from "../../src/providers/ich-tanke-strom/live-provider.js";
import { readIchTankeStromStaticFeed } from "../../src/providers/ich-tanke-strom/static-provider.js";

const observedAt = "2026-08-15T12:00:00.000Z";
const fetchedAt = "2026-08-15T12:00:05.000Z";

void test("maps one Swiss OICP static record to one EVSE", () => {
  const results = readIchTankeStromStaticFeed(
    staticPayload([
      record({
        EvseID: "CH*ABC*E1001",
        ChargingFacilities: [
          { power: "150.9" },
          { power: 50 },
        ],
        Plugs: ["CCS Combo 2 Plug", "CCS Combo 2 Plug"],
      }),
    ]),
    observedAt,
    fetchedAt,
  );

  assert.equal(results.length, 1);
  const result = results[0];
  assert.equal(result?.kind, "observation");
  if (result?.kind !== "observation") {
    return;
  }
  const location = result.observation.location;
  assert.equal(location.name, "Schnellladepark Bern");
  assert.equal(location.operatorName, "Authority Operator");
  assert.equal(location.chargingPoints.length, 1);
  assert.equal(location.chargingPoints[0]?.canonicalEVSEIdentity, "CHABCE1001");
  assert.equal(location.chargingPoints[0]?.providerEVSEKey, "CHABCE1001");
  assert.equal(location.chargingPoints[0]?.maximumPowerKW, 150);
  assert.equal(location.chargingPoints[0]?.connectors.length, 1);
  assert.deepEqual(location.chargingPoints[0]?.availability, {
    state: "unknown",
    isLive: false,
  });
});

void test("quarantines duplicate EVSE IDs and missing positive power", () => {
  const results = readIchTankeStromStaticFeed(
    staticPayload([
      record({ EvseID: "CH*ABC*E1001" }),
      record({ EvseID: "CH*ABC*E1001" }),
      record({ EvseID: "CH*ABC*E1002", ChargingFacilities: [{ power: 0 }] }),
    ]),
    observedAt,
    fetchedAt,
  );

  assert.equal(results.filter(({ kind }) => kind === "observation").length, 1);
  assert.deepEqual(
    results.flatMap((result) =>
      result.kind === "quarantine" ? [result.quarantine.issueCodes] : [],
    ),
    [["duplicate_evse_id"], ["missing_positive_power"]],
  );
});

void test("maps official live states and treats source unknown as unknown", () => {
  const result = readIchTankeStromLiveFeed(
    livePayload([
      { EvseID: "CH*ABC*E1", EVSEStatus: "Available" },
      { EvseID: "CH*ABC*E2", EVSEStatus: "Occupied" },
      { EvseID: "CH*ABC*E3", EVSEStatus: "OutOfService" },
      { EvseID: "CH*ABC*E4", EVSEStatus: "Reserved" },
      { EvseID: "CH*ABC*E5", EVSEStatus: "EvseNotFound" },
    ]),
    observedAt,
    fetchedAt,
  );

  assert.deepEqual(
    result.observations.map(({ state }) => state),
    ["available", "occupied", "out_of_service", "reserved", "unknown"],
  );
  assert.equal(result.quarantines.length, 0);
});

void test("does not fabricate a known state for conflicting duplicate live records", () => {
  const result = readIchTankeStromLiveFeed(
    livePayload([
      { EvseID: "CH*ABC*E1", EVSEStatus: "Available" },
      { EvseID: "CH-ABC-E1", EVSEStatus: "Occupied" },
    ]),
    observedAt,
    fetchedAt,
  );

  assert.equal(result.observations.length, 1);
  assert.equal(result.observations[0]?.state, "unknown");
  assert.deepEqual(result.quarantines[0]?.summary.issueCodes, ["duplicate_evse_id"]);
});

function staticPayload(records: readonly Readonly<Record<string, unknown>>[]) {
  return {
    EVSEData: [
      {
        OperatorID: "CH*ABC",
        OperatorName: "Authority Operator",
        EVSEDataRecord: records,
      },
    ],
  };
}

function record(overrides: Readonly<Record<string, unknown>>) {
  return {
    Address: {
      City: "Bern",
      Country: "CHE",
      PostalCode: "3000",
      Street: "Bahnhofplatz 1",
      Region: null,
    },
    ChargingFacilities: [{ power: "22.0" }],
    ChargingStationNames: [
      { lang: "en", value: "Bern charging park" },
      { lang: "de", value: "Schnellladepark Bern" },
    ],
    EvseID: "CH*ABC*E1000",
    GeoCoordinates: { Google: "46.9480 7.4474" },
    Plugs: ["Type 2 Outlet"],
    ...overrides,
  };
}

function livePayload(records: readonly Readonly<Record<string, unknown>>[]) {
  return {
    EVSEStatuses: [
      {
        OperatorID: "CH*ABC",
        OperatorName: "Authority Operator",
        EVSEStatusRecord: records,
      },
    ],
  };
}
