import Foundation

public struct ChargingParkSearchPolicy: Sendable {
  public init() {}

  public func selectResults(
    from candidates: [EnrichedChargingParkCandidate],
    criteria: RideCriteria
  ) -> [RouteSearchResult] {
    let matchingResults = candidates.compactMap { candidate in
      evaluate(candidate, criteria: criteria)
    }

    return groupByRestaurant(matchingResults, criteria: criteria)
      .sorted { lhs, rhs in
        if lhs.candidate.actualDrivingDistance == rhs.candidate.actualDrivingDistance {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.candidate.actualDrivingDistance < rhs.candidate.actualDrivingDistance
      }
      .prefix(SearchConfiguration.maximumResultCount)
      .map { $0 }
  }

  private func groupByRestaurant(
    _ results: [RouteSearchResult],
    criteria: RideCriteria
  ) -> [RouteSearchResult] {
    guard criteria.foodChain != nil else {
      return results
    }

    let groupedResults = Dictionary(grouping: results) { result in
      result.matchingFoodPOI?.id ?? "park:\(result.id.uuidString)"
    }
    return groupedResults.values.compactMap { group in
      let sortedGroup = group.sorted { lhs, rhs in
        if lhs.candidate.actualDrivingDistance == rhs.candidate.actualDrivingDistance {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.candidate.actualDrivingDistance < rhs.candidate.actualDrivingDistance
      }
      guard let primary = sortedGroup.first else {
        return nil
      }
      return RouteSearchResult(
        candidate: primary.candidate,
        relatedCandidates: sortedGroup.dropFirst().map(\.candidate),
        matchingFoodPOI: primary.matchingFoodPOI
      )
    }
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
