import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyFoodPOI,
  stitchOuterRings,
} from "../../src/providers/openstreetmap/pbf-provider.js";

void test("classifies supported restaurant chains using stable OSM brand identifiers", () => {
  assert.deepEqual(
    classifyFoodPOI({
      amenity: "fast_food",
      name: "McDrive Gießen",
      "brand:wikidata": "Q38076",
    }),
    { chain: "mcdonalds", matchMethod: "brand_wikidata" },
  );
  assert.deepEqual(
    classifyFoodPOI({ amenity: "restaurant", brand: "Burger King" }),
    { chain: "burger_king", matchMethod: "brand" },
  );
});

void test("does not infer a chain from an unrelated place name or amenity", () => {
  assert.equal(
    classifyFoodPOI({ amenity: "charging_station", name: "McDonald's charger" }),
    undefined,
  );
  assert.equal(classifyFoodPOI({ amenity: "restaurant", name: "Local Grill" }), undefined);
});

void test("stitches split outer ways into a closed restaurant polygon", () => {
  assert.deepEqual(stitchOuterRings([[1, 2, 3], [3, 4, 1]]), [[1, 2, 3, 4, 1]]);
  assert.equal(stitchOuterRings([[1, 2], [3, 4]]), undefined);
});
