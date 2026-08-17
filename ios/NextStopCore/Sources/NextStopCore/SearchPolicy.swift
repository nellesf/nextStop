import Foundation

public struct ChargingParkSearchPolicy: Sendable {
  public init() {}

  public func selectResults(
    from candidates: [EnrichedChargingParkCandidate],
    criteria: RideCriteria
  ) -> [RouteSearchResult] {
    candidates.compactMap { candidate in
      evaluate(candidate, criteria: criteria)
    }
    .sorted { lhs, rhs in
      if lhs.candidate.actualDrivingDistance == rhs.candidate.actualDrivingDistance {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.candidate.actualDrivingDistance < rhs.candidate.actualDrivingDistance
    }
    .prefix(SearchConfiguration.maximumResultCount)
    .map { $0 }
  }

  private func evaluate(
    _ candidate: EnrichedChargingParkCandidate,
    criteria: RideCriteria
  ) -> RouteSearchResult? {
    guard candidate.distanceFromRoute <= SearchConfiguration.maximumDistanceFromRoute,
      criteria.distanceRange.range.contains(candidate.actualDrivingDistance),
      candidate.park.chargingPointCount >= criteria.minimumChargingPoints.rawValue,
      candidate.park.maximumPower.value >= criteria.minimumPower.rawValue
    else {
      return nil
    }

    let matchingFoodPOI: FoodPOI?
    if let requiredFoodChain = criteria.foodChain {
      matchingFoodPOI = candidate.foodPOIs
        .filter {
          $0.chain == requiredFoodChain
            && $0.distanceFromPark <= SearchConfiguration.maximumFoodDistance
        }
        .min { lhs, rhs in
          if lhs.distanceFromPark == rhs.distanceFromPark {
            return lhs.id < rhs.id
          }
          return lhs.distanceFromPark < rhs.distanceFromPark
        }

      guard matchingFoodPOI != nil else {
        return nil
      }
    } else {
      matchingFoodPOI = nil
    }

    return RouteSearchResult(
      candidate: candidate,
      matchingFoodPOI: matchingFoodPOI
    )
  }
}
