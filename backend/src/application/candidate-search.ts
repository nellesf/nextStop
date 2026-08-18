import type { SearchRequest, SearchResponse } from "../domain/candidate-search.js";

export interface CandidateSearching {
  search(request: SearchRequest): Promise<SearchResponse>;
}

export class NoProjectionAvailableError extends Error {
  constructor() {
    super("No valid charging-data projection is available.");
    this.name = "NoProjectionAvailableError";
  }
}

export class FoodPOIDataUnavailableError extends Error {
  constructor() {
    super("No valid OpenStreetMap food-POI projection is available.");
    this.name = "FoodPOIDataUnavailableError";
  }
}

export class UnavailableCandidateSearch implements CandidateSearching {
  search(request: SearchRequest): Promise<SearchResponse> {
    void request;
    return Promise.reject(new NoProjectionAvailableError());
  }
}
