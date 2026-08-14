import test from "node:test";

void test(
  "PostGIS corridor query",
  {
    skip: "The real PostGIS migration and exact ST_DWithin query arrive with the Bundesnetzagentur ingestion slice.",
  },
  () => undefined,
);
