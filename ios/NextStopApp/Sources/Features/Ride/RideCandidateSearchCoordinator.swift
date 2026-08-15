import Foundation
import NextStopCore

enum RideCandidateSearchError: Error, Equatable {
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
}

enum CandidateEnrichmentError: Error, Equatable {
  case drivingRouteUnavailable
  case foodSearchUnavailable
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
    var request = preparedRide.request
    var enrichedCandidates: [EnrichedChargingParkCandidate] = []
    var routingFailureLowerBounds: [Meters] = []
    var seenPageIdentities = Set<String>()
    var previousPageLastLowerBound: Meters?
    var searchCoverage: CandidateSearchCoverage?

    while true {
      let page: CandidateSearchPage
      do {
        page = try await pageSearcher.search(request: request)
      } catch is CancellationError {
        throw CancellationError()
      } catch CandidateSearchServiceError.dataPreparing {
        throw RideCandidateSearchError.candidateDataPreparing
      } catch CandidateSearchServiceError.snapshotExpired {
        throw RideCandidateSearchError.candidateSnapshotExpired
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
        let outcome = try await enrichBatch(
          Array(candidatesToEnrich[offset..<end]),
          origin: preparedRide.origin,
          criteria: request.criteria
        )
        enrichedCandidates.append(contentsOf: outcome.candidates)
        routingFailureLowerBounds.append(contentsOf: outcome.routingFailureLowerBounds)
      }

      let selectedResults = policy.selectResults(
        from: enrichedCandidates,
        criteria: request.criteria
      )
      guard let nextCursor = page.nextCursor else {
        return try outcome(
          results: selectedResults,
          routingFailureLowerBounds: routingFailureLowerBounds,
          coverage: searchCoverage
        )
      }
      if let lastLowerBound = page.candidates.last?.straightLineLowerBound {
        if lastLowerBound > upperDistance {
          return try outcome(
            results: selectedResults,
            routingFailureLowerBounds: routingFailureLowerBounds,
            coverage: searchCoverage
          )
        }
        if selectedResults.count == SearchConfiguration.maximumResultCount,
          let fifthDistance = selectedResults.last?.candidate.actualDrivingDistance,
          lastLowerBound > fifthDistance
        {
          return try outcome(
            results: selectedResults,
            routingFailureLowerBounds: routingFailureLowerBounds,
            coverage: searchCoverage
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

  private func outcome(
    results: [RouteSearchResult],
    routingFailureLowerBounds: [Meters],
    coverage: CandidateSearchCoverage?
  ) throws -> RideCandidateSearchOutcome {
    guard let coverage else {
      throw RideCandidateSearchError.candidateResponseInvalid
    }
    return RideCandidateSearchOutcome(
      results: try validatedResults(
        results,
        routingFailureLowerBounds: routingFailureLowerBounds
      ),
      coverage: coverage
    )
  }

  private func validatedResults(
    _ results: [RouteSearchResult],
    routingFailureLowerBounds: [Meters]
  ) throws -> [RouteSearchResult] {
    guard !routingFailureLowerBounds.isEmpty else {
      return results
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
    } catch CandidateEnrichmentError.foodSearchUnavailable {
      throw RideCandidateSearchError.foodSearchUnavailable
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
