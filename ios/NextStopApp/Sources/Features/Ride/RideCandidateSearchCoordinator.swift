import Foundation
import NextStopCore

enum RideCandidateSearchError: Error, Equatable {
  case candidateServiceUnavailable
  case candidateResponseInvalid
  case drivingDistancesUnavailable
  case foodSearchUnavailable
}

enum CandidateEnrichmentError: Error, Equatable {
  case drivingRouteUnavailable
  case foodSearchUnavailable
}

@MainActor
protocol CandidateEnriching: AnyObject {
  func enrich(
    candidate: BackendCandidate,
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichedChargingParkCandidate
}

@MainActor
protocol RideCandidateSearching: AnyObject {
  func search(preparedRide: PreparedRideSearch) async throws -> [RouteSearchResult]
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
    precondition(enrichmentBatchSize > 0)
    self.pageSearcher = pageSearcher
    self.enricher = enricher
    self.policy = policy
    self.enrichmentBatchSize = enrichmentBatchSize
  }

  func search(preparedRide: PreparedRideSearch) async throws -> [RouteSearchResult] {
    var request = preparedRide.request
    var enrichedCandidates: [EnrichedChargingParkCandidate] = []
    var routingFailureLowerBounds: [Meters] = []
    var seenPageIdentities = Set<String>()
    var previousPageLastLowerBound: Meters?

    while true {
      let page: CandidateSearchPage
      do {
        page = try await pageSearcher.search(request: request)
      } catch is CancellationError {
        throw CancellationError()
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
        return try validatedResults(
          selectedResults,
          routingFailureLowerBounds: routingFailureLowerBounds
        )
      }
      if let lastLowerBound = page.candidates.last?.straightLineLowerBound {
        if lastLowerBound > upperDistance {
          return try validatedResults(
            selectedResults,
            routingFailureLowerBounds: routingFailureLowerBounds
          )
        }
        if selectedResults.count == SearchConfiguration.maximumResultCount,
          let fifthDistance = selectedResults.last?.candidate.actualDrivingDistance,
          lastLowerBound > fifthDistance
        {
          return try validatedResults(
            selectedResults,
            routingFailureLowerBounds: routingFailureLowerBounds
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
    let enricher = self.enricher
    return try await withThrowingTaskGroup(of: EnrichmentOutcome.self) { group in
      for candidate in candidates {
        group.addTask { @MainActor in
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
      }

      var values: [EnrichedChargingParkCandidate] = []
      var routingFailureLowerBounds: [Meters] = []
      for try await outcome in group {
        switch outcome {
        case .candidate(let candidate):
          values.append(candidate)
        case .routingFailure(let lowerBound):
          routingFailureLowerBounds.append(lowerBound)
        }
      }
      return EnrichmentBatchOutcome(
        candidates: values,
        routingFailureLowerBounds: routingFailureLowerBounds
      )
    }
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
