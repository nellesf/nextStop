import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { deflateSync } from "node:zlib";
import test from "node:test";
import { readOpenStreetMapFoodPOIs } from "../../src/providers/openstreetmap/pbf-provider.js";
import { ObjectDownloadCache } from "../../src/providers/object-download-cache.js";
import { MemoryObjectStore } from "../fixtures/memory-object-store.js";

void test("OSM relation parsing reopens the same object three times and produces the complete restaurant geometry", async () => {
  const store = new MemoryObjectStore(), cache = new ObjectDownloadCache(store, "test-osm-pbf");
  const bytes = restaurantPBF();
  const artifact = await cache.write(Readable.from([bytes]), {
    sourceURL: "https://download.geofabrik.de/europe/switzerland-latest.osm.pbf",
    observedAt: "2026-10-01T00:00:00.000Z", fetchedAt: "2026-10-02T00:00:00.000Z",
  }, bytes.length);
  const result = await readOpenStreetMapFoodPOIs([artifact]);
  assert.equal(result.records.length, 1); assert.equal(result.quarantines.length, 0);
  assert.equal(result.records[0]?.chain, "mcdonalds"); assert.equal(result.records[0]?.osmId, 42);
  assert.deepEqual(result.records[0]?.geometry, { type: "MultiPolygon", coordinates: [[[[8, 47], [8.001, 47], [8, 47.001], [8, 47]]]] });
  const reads = store.reads.filter(({ name }) => name.includes("/body-"));
  assert.equal(reads.length, 3); assert.equal(new Set(reads.map(({ generation }) => generation)).size, 1);
});

void test("upstream corruption or transport failure cannot silently publish partially parsed OSM records", async () => {
  const bytes = restaurantPBF();
  let passes = 0;
  await assert.rejects(readOpenStreetMapFoodPOIs([{
    sourceURL: "https://download.geofabrik.de/europe/switzerland-latest.osm.pbf", sha256: "0".repeat(64),
    observedAt: "2026-10-01T00:00:00.000Z", fetchedAt: "2026-10-02T00:00:00.000Z", cleanup: () => Promise.resolve(),
    openReadStream: () => { passes++; return Readable.from((function* () {
      yield bytes;
      if (passes === 2) throw new Error("pinned generation transport failed");
    })()); },
  }]), /pinned generation transport failed/u);
  assert.equal(passes, 2);
});

// A tiny actual PBF, encoded directly from OSM's protobuf field numbers. Relation->way->nodes
// requires all three parser passes; no provider data, parser mock or extra test dependency.
function restaurantPBF(): Buffer {
  const strings = ["", "amenity", "fast_food", "brand:wikidata", "Q38076", "outer"];
  const table = Buffer.concat(strings.map((value) => field(1, Buffer.from(value))));
  const nodes = [[1, 47, 8], [2, 47, 8.001], [3, 47.001, 8]].map(([id, lat, lon]) =>
    field(1, Buffer.concat([integer(1, zigzag(id!)), integer(8, zigzag(Math.round(lat! * 1e7))), integer(9, zigzag(Math.round(lon! * 1e7)))])));
  const way = field(3, Buffer.concat([integer(1, 10), field(8, Buffer.concat([1, 1, 1, -2].map((value) => varint(zigzag(value)))))]));
  const relation = field(4, Buffer.concat([integer(1, 42), field(2, Buffer.concat([varint(1), varint(3)])),
    field(3, Buffer.concat([varint(2), varint(4)])), field(8, varint(5)), field(9, varint(zigzag(10))), field(10, varint(1))]));
  const block = Buffer.concat([field(1, table), field(2, Buffer.concat(nodes)), field(2, way), field(2, relation)]);
  return Buffer.concat([frame("OSMHeader", field(4, Buffer.from("OsmSchema-V0.6"))), frame("OSMData", block)]);
}
function frame(type: string, raw: Buffer): Buffer {
  const blob = Buffer.concat([integer(2, raw.length), field(3, deflateSync(raw))]);
  const header = Buffer.concat([field(1, Buffer.from(type)), integer(3, blob.length)]);
  const length = Buffer.alloc(4); length.writeUInt32BE(header.length);
  return Buffer.concat([length, header, blob]);
}
function integer(number: number, value: number): Buffer { return Buffer.concat([varint(number * 8), varint(value)]); }
function field(number: number, bytes: Buffer): Buffer { return Buffer.concat([varint(number * 8 + 2), varint(bytes.length), bytes]); }
function zigzag(value: number): number { return value < 0 ? -value * 2 - 1 : value * 2; }
function varint(value: number): Buffer {
  const bytes: number[] = [];
  do { const next = value % 128; value = Math.floor(value / 128); bytes.push(next + (value > 0 ? 128 : 0)); } while (value > 0);
  return Buffer.from(bytes);
}
