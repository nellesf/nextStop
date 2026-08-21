import Foundation
import NextStopCore

enum RideCandidateSearchError: Error, Equatable {
  case authenticationUnavailable
  case candidateDataPreparing
  case candidateServiceUnavailable
  case candidateSnapshotExpired
  case candidateResponseInvalid
  case drivingDistancesUnavailable
  case foodSearchUnavailable
}

struct RideCandidateSearchOutcome: Equatable, Sendable {
  let results: [RouteSearchResult]
  let coverage: CandidateSearchCoverage
  let attributions: [DataAttribution]

  init(
    results: [RouteSearchResult],
    coverage: CandidateSearchCoverage,
    attributions: [DataAttribution] = []
  ) {
    self.results = results
    self.coverage = coverage
    self.attributions = attributions
  }
}

enum CandidateEnrichmentError: Error, Equatable {
  case drivingRouteUnavailable
}

@MainActor
protocol CandidateEnriching: AnyObject, Sendable {
  func enrich(
    candidate: BackendCandidate,
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichedChargingParkCandidate
}

@MainActor
protocol RideCandidateSearching: AnyObject {
  func search(preparedRide: PreparedRideSearch) async throws -> RideCandidateSearchOutcome
}

@MainActor
final class RideCandidateSearchCoordinator: RideCandidateSearching {
  private let pageSearcher: any CandidatePageSearching
  private let enricher: any CandidateEnriching
  private let policy: ChargingParkSearchPolicy
  private let enrichmentBatchSize: Int

  init(
    pageSearcher: any CandidatePageSearching,
    enricher: any CandidateEnriching,
    policy: ChargingParkSearchPolicy = ChargingParkSearchPolicy(),
    enrichmentBatchSize: Int = 4
  ) {
    precondition((1...4).contains(enrichmentBatchSize))
    self.pageSearcher = pageSearcher
    self.enricher = enricher
    self.policy = policy
    self.enrichmentBatchSize = enrichmentBatchSize
  }

  func search(preparedRide: PreparedRideSearch) async throws -> RideCandidateSearchOutcome {
    do {
      return try await searchOnce(preparedRide: preparedRide)
    } catch RideCandidateSearchError.candidateSnapshotExpired {
      try Task.checkCancellation()
      return try await searchOnce(preparedRide: preparedRide)
    }
  }

  private func searchOnce(
    preparedRide: PreparedRideSearch
  ) async throws -> RideCandidateSearchOutcome {
    var request = preparedRide.request
    var enrichedCandidates: [EnrichedChargingParkCandidate] = []
    var routingFailureLowerBounds: [Meters] = []
    var seenPageIdentities = Set<String>()
    var previousPageLastLowerBound: Meters?
    var searchCoverage: CandidateSearchCoverage?
    var searchAttributions: [DataAttribution]?
    var restaurantIDsToComplete: Set<String>?

    while true {
      let page: CandidateSearchPage
      do {
        page = try await pageSearcher.search(request: request)
      } catch is CancellationError {
        throw CancellationError()
      } catch CandidateSearchServiceError.dataPreparing {
        throw RideCandidateSearchError.candidateDataPreparing
      } catch CandidateSearchServiceError.foodDataPreparing {
        throw RideCandidateSearchError.foodSearchUnavailable
      } catch CandidateSearchServiceError.snapshotExpired {
        throw RideCandidateSearchError.candidateSnapshotExpired
      } catch CandidateSearchServiceError.authenticationUnavailable,
        CandidateSearchServiceError.invalidConfiguration
      {
        throw RideCandidateSearchError.authenticationUnavailable
      } catch CandidateSearchServiceError.invalidResponse {
        throw RideCandidateSearchError.candidateResponseInvalid
      } catch {
        throw RideCandidateSearchError.candidateServiceUnavailable
      }
      if let expectedSnapshot = request.snapshotToken,
        page.snapshotToken != expectedSnapshot
      {
        throw RideCandidateSearchError.candidateResponseInvalid
      }
      if let searchCoverage {
        guard searchCoverage == page.coverage else {
          throw RideCandidateSearchError.candidateResponseInvalid
        }
      } else {
        searchCoverage = page.coverage
      }
      if let searchAttributions {
        guard searchAttributions == page.attributions else {
          throw RideCandidateSearchError.candidateResponseInvalid
        }
      } else {
        searchAttributions = page.attributions
      }
      if page.candidates.isEmpty, page.nextCursor != nil {
        throw RideCandidateSearchError.candidateResponseInvalid
      }
      if let priorLowerBound = previousPageLastLowerBound,
        let firstLowerBound = page.candidates.first?.straightLineLowerBound,
        firstLowerBound < priorLowerBound
      {
        throw RideCandidateSearchError.candidateResponseInvalid
      }
      previousPageLastLowerBound =
        page.candidates.last?.straightLineLowerBound ?? previousPageLastLowerBound
      let upperDistance = request.criteria.distanceRange.range.upperBound
      let candidatesToEnrich = page.candidates.filter {
        $0.straightLineLowerBound <= upperDistance
      }
      for offset in stride(from: 0, to: candidatesToEnrich.count, by: enrichmentBatchSize) {
        let end = min(offset + enrichmentBatchSize, candidatesToEnrich.count)
        let batch = Array(candidatesToEnrich[offset..<end]).filter { candidate in
          guard let restaurantIDsToComplete else {
            return true
          }
          return candidate.foodPOIs.contains {
            restaurantIDsToComplete.contains($0.id)
          }
        }
        let outcome = try await enrichBatch(
          batch,
          origin: preparedRide.origin,
          criteria: request.criteria
        )
        enrichedCandidates.append(contentsOf: outcome.candidates)
        routingFailureLowerBounds.append(contentsOf: outcome.routingFailureLowerBounds)

        guard end < page.candidates.count else {
          continue
        }
        let nextLowerBound = page.candidates[end].straightLineLowerBound
        let batchResults = policy.selectResults(
          from: enrichedCandidates,
          criteria: request.criteria
        )
        if restaurantIDsToComplete == nil {
          restaurantIDsToComplete = restaurantCompletionIDs(
            results: batchResults,
            nextLowerBound: nextLowerBound,
            criteria: request.criteria
          )
        }
        if nextLowerBound > upperDistance
          || safeToStop(
            results: batchResults,
            nextLowerBound: nextLowerBound,
            criteria: request.criteria
          )
        {
          return try self.outcome(
            results: batchResults,
            routingFailureLowerBounds: routingFailureLowerBounds,
            coverage: searchCoverage,
            attributions: searchAttributions,
            criteria: request.criteria
          )
        }
      }

      let selectedResults = policy.selectResults(
        from: enrichedCandidates,
        criteria: request.criteria
      )
      guard let nextCursor = page.nextCursor else {
        return try outcome(
          results: selectedResults,
          routingFailureLowerBounds: routingFailureLowerBounds,
          coverage: searchCoverage,
          attributions: searchAttributions,
          criteria: request.criteria
        )
      }
      if let lastLowerBound = page.candidates.last?.straightLineLowerBound {
        if lastLowerBound > upperDistance {
          return try outcome(
            results: selectedResults,
            routingFailureLowerBounds: routingFailureLowerBounds,
            coverage: searchCoverage,
            attributions: searchAttributions,
            criteria: request.criteria
          )
        }
        if restaurantIDsToComplete == nil {
          restaurantIDsToComplete = restaurantCompletionIDs(
            results: selectedResults,
            nextLowerBound: lastLowerBound,
            criteria: request.criteria
          )
        }
        if safeToStop(
          results: selectedResults,
          nextLowerBound: lastLowerBound,
          criteria: request.criteria
        ) {
          return try outcome(
            results: selectedResults,
            routingFailureLowerBounds: routingFailureLowerBounds,
            coverage: searchCoverage,
            attributions: searchAttributions,
            criteria: request.criteria
          )
        }
      }

      let pageIdentity = "\(page.snapshotToken)\u{0}\(nextCursor)"
      guard seenPageIdentities.insert(pageIdentity).inserted else {
        throw RideCandidateSearchError.candidateResponseInvalid
      }
      request = RouteSearchRequest(
        requestID: request.requestID,
        route: request.route,
        criteria: request.criteria,
        snapshotToken: page.snapshotToken,
        cursor: nextCursor
      )
    }
  }

  private func safeToStop(
    results: [RouteSearchResult],
    nextLowerBound: Meters,
    criteria: RideCriteria
  ) -> Bool {
    guard criteria.foodChain == nil else {
      return false
    }
    return results.count == SearchConfiguration.maximumResultCount
      && results.last.map {
        nextLowerBound > $0.candidate.actualDrivingDistance
      } == true
  }

  private func restaurantCompletionIDs(
    results: [RouteSearchResult],
    nextLowerBound: Meters,
    criteria: RideCriteria
  ) -> Set<String>? {
    guard criteria.foodChain != nil,
      results.count == SearchConfiguration.maximumResultCount,
      let fifthDistance = results.last?.candidate.actualDrivingDistance,
      nextLowerBound > fifthDistance
    else {
      return nil
    }
    let restaurantIDs = Set(results.compactMap { $0.matchingFoodPOI?.id })
    guard restaurantIDs.count == SearchConfiguration.maximumResultCount else {
      return nil
    }
    return restaurantIDs
  }

  private func outcome(
    results: [RouteSearchResult],
    routingFailureLowerBounds: [Meters],
    coverage: CandidateSearchCoverage?,
    attributions: [DataAttribution]?,
    criteria: RideCriteria
  ) throws -> RideCandidateSearchOutcome {
    guard let coverage, let attributions else {
      throw RideCandidateSearchError.candidateResponseInvalid
    }
    return RideCandidateSearchOutcome(
      results: try validatedResults(
        results,
        routingFailureLowerBounds: routingFailureLowerBounds,
        criteria: criteria
      ),
      coverage: coverage,
      attributions: attributions
    )
  }

  private func validatedResults(
    _ results: [RouteSearchResult],
    routingFailureLowerBounds: [Meters],
    criteria: RideCriteria
  ) throws -> [RouteSearchResult] {
    guard !routingFailureLowerBounds.isEmpty else {
      return results
    }
    guard criteria.foodChain == nil else {
      throw RideCandidateSearchError.drivingDistancesUnavailable
    }
    if results.count == SearchConfiguration.maximumResultCount,
      let fifthDistance = results.last?.candidate.actualDrivingDistance,
      routingFailureLowerBounds.allSatisfy({ $0 > fifthDistance })
    {
      return results
    }
    throw RideCandidateSearchError.drivingDistancesUnavailable
  }

  private func enrichBatch(
    _ candidates: [BackendCandidate],
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichmentBatchOutcome {
    precondition(candidates.count <= 4)
    switch candidates.count {
    case 0:
      return EnrichmentBatchOutcome(candidates: [], routingFailureLowerBounds: [])
    case 1:
      return makeBatchOutcome([
        try await enrichOne(candidates[0], origin: origin, criteria: criteria)
      ])
    case 2:
      async let first = enrichOne(candidates[0], origin: origin, criteria: criteria)
      async let second = enrichOne(candidates[1], origin: origin, criteria: criteria)
      let outcomes = try await (first, second)
      return makeBatchOutcome([outcomes.0, outcomes.1])
    case 3:
      async let first = enrichOne(candidates[0], origin: origin, criteria: criteria)
      async let second = enrichOne(candidates[1], origin: origin, criteria: criteria)
      async let third = enrichOne(candidates[2], origin: origin, criteria: criteria)
      let outcomes = try await (first, second, third)
      return makeBatchOutcome([outcomes.0, outcomes.1, outcomes.2])
    case 4:
      async let first = enrichOne(candidates[0], origin: origin, criteria: criteria)
      async let second = enrichOne(candidates[1], origin: origin, criteria: criteria)
      async let third = enrichOne(candidates[2], origin: origin, criteria: criteria)
      async let fourth = enrichOne(candidates[3], origin: origin, criteria: criteria)
      let outcomes = try await (first, second, third, fourth)
      return makeBatchOutcome([outcomes.0, outcomes.1, outcomes.2, outcomes.3])
    default:
      preconditionFailure("Candidate enrichment batches are limited to four items")
    }
  }

  private func enrichOne(
    _ candidate: BackendCandidate,
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichmentOutcome {
    do {
      return .candidate(
        try await enricher.enrich(
          candidate: candidate,
          origin: origin,
          criteria: criteria
        )
      )
    } catch CandidateEnrichmentError.drivingRouteUnavailable {
      return .routingFailure(candidate.straightLineLowerBound)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .routingFailure(candidate.straightLineLowerBound)
    }
  }

  private func makeBatchOutcome(
    _ outcomes: [EnrichmentOutcome]
  ) -> EnrichmentBatchOutcome {
    var candidates: [EnrichedChargingParkCandidate] = []
    var routingFailureLowerBounds: [Meters] = []
    for outcome in outcomes {
      switch outcome {
      case .candidate(let candidate):
        candidates.append(candidate)
      case .routingFailure(let lowerBound):
        routingFailureLowerBounds.append(lowerBound)
      }
    }
    return EnrichmentBatchOutcome(
      candidates: candidates,
      routingFailureLowerBounds: routingFailureLowerBounds
    )
  }
}

private enum EnrichmentOutcome: Sendable {
  case candidate(EnrichedChargingParkCandidate)
  case routingFailure(Meters)
}

private struct EnrichmentBatchOutcome: Sendable {
  let candidates: [EnrichedChargingParkCandidate]
  let routingFailureLowerBounds: [Meters]
}
