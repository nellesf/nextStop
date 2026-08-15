export const ichTankeStromDescriptor = {
  id: "ich_tanke_strom",
  name: "ich-tanke-strom.ch",
  sourceFamily: "authority_open_data",
  countries: ["CH"],
  qualityTier: "authority",
  capabilities: {
    static: true,
    liveAvailability: true,
  },
  license: "Open Government Data with source attribution",
  attribution: "Bundesamt für Energie BFE, ich-tanke-strom.ch",
  termsUrl: "https://data.opentransportdata.swiss/dataset/ladestationen",
  legalReviewDate: "2026-08-15",
  expectedStaticRefreshIntervalHours: 24,
  expectedLiveRefreshIntervalSeconds: 60,
  maximumLiveAgeSeconds: 300,
  liveSnapshotRetentionHours: 2,
} as const;
