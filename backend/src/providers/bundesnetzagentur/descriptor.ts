export const bundesnetzagenturDescriptor = {
  id: "bundesnetzagentur_ladesaeulenregister",
  name: "Bundesnetzagentur Ladesäulenregister",
  sourceFamily: "authority_open_data",
  countries: ["DE"],
  qualityTier: "authority",
  capabilities: {
    static: true,
    liveAvailability: false,
  },
  license: "CC-BY-4.0",
  attribution: "bundesnetzagentur.de",
  termsUrl:
    "https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenkarte/start.html",
  legalReviewDate: "2026-08-14",
  expectedRefreshIntervalHours: 24,
} as const;
