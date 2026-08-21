export const searchRequestLimits = {
  maximumBodyBytes: 512 * 1024,
  maximumConcurrentSearches: 4,
  maximumRouteCoordinateCount: 8_000,
  maximumRouteLengthMeters: 2_500_000,
  maximumRouteSegmentLengthMeters: 250_000,
  supportedRouteEnvelope: {
    minimumLatitude: 34,
    maximumLatitude: 72,
    minimumLongitude: -25,
    maximumLongitude: 45,
  },
} as const;
