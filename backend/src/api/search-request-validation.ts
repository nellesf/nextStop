import type { SearchRequest } from "../domain/candidate-search.js";

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
}
