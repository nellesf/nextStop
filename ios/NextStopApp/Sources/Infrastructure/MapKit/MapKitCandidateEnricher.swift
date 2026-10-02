import Foundation
import NextStopCore

@MainActor
final class AppleChargingResultChecker: ChargingResultChecking {
  private let placeChecker: any AppleChargingPlaceChecking

  init(placeChecker: any AppleChargingPlaceChecking) {
    self.placeChecker = placeChecker
  }

  func beginSearch() {
    placeChecker.resetChargingPlaceChecks()
  }

  func confirmedOperatorNames(in result: RouteSearchResult) async throws -> Set<String> {
    let group = AppleChargingPlaceResultGroup(
      id: result.matchingFoodPOI.map { "restaurant:\($0.id)" }
        ?? "park:\(result.id.uuidString)",
      kind: result.matchingFoodPOI == nil ? .noFoodCampus : .restaurant,
      evidenceLocations: result.locationLookups,
      searchCoordinates: result.placeLookupCandidates.map(\.park.navigationCoordinate),
      restaurantCoordinate: result.matchingFoodPOI?.coordinate
    )
    var confirmed = Set<String>()
    // Bound Apple request concurrency to one; do not fan out across operators.
    for summary in result.operatorChargingPoints {
      try Task.checkCancellation()
      guard let park = result.representativePark(for: summary.name) else { continue }
      let relatedLocations =
        result.matchingFoodPOI != nil
        ? AppleChargingPlaceLookupScope.restaurantGroupLocations(
          candidateLocations: result.locationLookups,
          operatorName: summary.name
        )
        : AppleChargingPlaceLookupScope.relatedLocations(
          primaryLocations: park.locationLookups,
          candidateLocations: result.locationLookups,
          operatorName: summary.name
        )
      let item = try await placeChecker.checkChargingPlace(
        park: park,
        operatorName: summary.name,
        relatedLocations: relatedLocations,
        resultGroup: group
      )
      try Task.checkCancellation()
      if item != nil { confirmed.insert(summary.name) }
    }
    return confirmed
  }
}

@MainActor
final class MapKitCandidateEnricher: CandidateEnriching {
  private let distanceProvider: any DrivingDistanceProviding
  private var cache: [CacheKey: Meters] = [:]

  init(distanceProvider: any DrivingDistanceProviding) {
    self.distanceProvider = distanceProvider
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
        actualDrivingDistance = try await distanceProvider.automobileDrivingDistance(
          from: origin,
          to: candidate.park.navigationCoordinate
        )
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
