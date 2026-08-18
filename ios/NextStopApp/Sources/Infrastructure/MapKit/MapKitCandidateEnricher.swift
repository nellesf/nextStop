import Foundation
import NextStopCore

@MainActor
final class MapKitCandidateEnricher: CandidateEnriching {
  private let routePlanner: any RoutePlanning
  private var cache: [CacheKey: Meters] = [:]

  init(routePlanner: any RoutePlanning) {
    self.routePlanner = routePlanner
  }

  func enrich(
    candidate: BackendCandidate,
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichedChargingParkCandidate {
    let cacheKey = CacheKey(
      candidateID: candidate.id,
      origin: origin,
      navigationCoordinate: candidate.park.navigationCoordinate
    )
    let actualDrivingDistance: Meters
    if let cached = cache[cacheKey] {
      actualDrivingDistance = cached
    } else {
      do {
        actualDrivingDistance = try await routePlanner.automobileRoute(
          from: origin,
          to: candidate.park.navigationCoordinate
        ).actualDrivingDistance
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw CandidateEnrichmentError.drivingRouteUnavailable
      }
      cache[cacheKey] = actualDrivingDistance
    }
    return EnrichedChargingParkCandidate(
      park: candidate.park,
      distanceFromRoute: candidate.distanceFromRoute,
      actualDrivingDistance: actualDrivingDistance,
      foodPOIs: criteria.foodChain == nil ? [] : candidate.foodPOIs
    )
  }

  private struct CacheKey: Hashable {
    let candidateID: UUID
    let origin: Coordinate
    let navigationCoordinate: Coordinate
  }
}
