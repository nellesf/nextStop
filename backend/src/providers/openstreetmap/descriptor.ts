export const openStreetMapFoodPOIDescriptor = {
  id: "openstreetmap_food_poi",
  name: "OpenStreetMap",
  sourceFamily: "community_open_data",
  qualityTier: "community",
  attributionNotice: "© OpenStreetMap contributors",
  licenseName: "Open Database License (ODbL) 1.0",
  licenseURL: "https://www.openstreetmap.org/copyright",
  transportName: "Geofabrik",
  transportURL: "https://download.geofabrik.de/",
  maximumFoodDistanceMeters: 500,
  matchPrefilterDistanceMeters: 700,
  expectedRefreshIntervalHours: 24,
  lastLegalReviewAt: "2026-08-18",
} as const;

export type OpenStreetMapFoodChain =
  | "mcdonalds"
  | "burger_king"
  | "kfc"
  | "subway";
