import type { SearchRequest } from "../domain/candidate-search.js";
import { geodesicDistanceMeters } from "../domain/geodesy.js";
import { searchRequestLimits } from "./search-request-limits.js";

export class InvalidSearchRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvalidSearchRequestError";
  }
}

export function validateSearchRequest(request: SearchRequest): void {
  const firstCoordinate = request.route.coordinates[0];
  if (firstCoordinate === undefined) {
    throw new InvalidSearchRequestError("Route must contain at least two coordinates.");
  }

  const hasDistinctCoordinate = request.route.coordinates.some(
    ([longitude, latitude]) =>
      longitude !== firstCoordinate[0] || latitude !== firstCoordinate[1],
  );

  if (!hasDistinctCoordinate) {
    throw new InvalidSearchRequestError("Route must contain distinct coordinates.");
  }

  let totalLengthMeters = 0;
  for (const [index, coordinate] of request.route.coordinates.entries()) {
    if (!isInsideSupportedEnvelope(coordinate)) {
      throw new InvalidSearchRequestError("Route is outside the supported European region.");
    }

    if (index === 0) {
      continue;
    }
    const previous = request.route.coordinates[index - 1];
    if (previous === undefined) {
      throw new InvalidSearchRequestError("Route geometry is invalid.");
    }
    const segmentLengthMeters = geodesicDistanceMeters(
      { longitude: previous[0], latitude: previous[1] },
      { longitude: coordinate[0], latitude: coordinate[1] },
    );
    if (segmentLengthMeters > searchRequestLimits.maximumRouteSegmentLengthMeters) {
      throw new InvalidSearchRequestError("Route contains an excessively long segment.");
    }
    totalLengthMeters += segmentLengthMeters;
    if (totalLengthMeters > searchRequestLimits.maximumRouteLengthMeters) {
      throw new InvalidSearchRequestError("Route is excessively long.");
    }
  }
}

function isInsideSupportedEnvelope(
  coordinate: SearchRequest["route"]["coordinates"][number],
): boolean {
  const [longitude, latitude] = coordinate;
  const envelope = searchRequestLimits.supportedRouteEnvelope;
  return (
    longitude >= envelope.minimumLongitude &&
    longitude <= envelope.maximumLongitude &&
    latitude >= envelope.minimumLatitude &&
    latitude <= envelope.maximumLatitude
  );
}
