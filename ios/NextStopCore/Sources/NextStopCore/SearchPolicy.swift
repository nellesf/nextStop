import Foundation

public struct ChargingParkSearchPolicy: Sendable {
  public init() {}

  public func selectResults(
    from candidates: [EnrichedChargingParkCandidate],
    criteria: RideCriteria
  ) -> [RouteSearchResult] {
    Array(
      rankedResults(from: candidates, criteria: criteria)
        .prefix(SearchConfiguration.maximumResultCount)
    )
  }

  /// All qualified results, before application-level place confirmation and the final limit.
  public func rankedResults(
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
  }

  /// Restricts an already qualified result without changing its park boundaries or route evidence.
  /// The minimum applies to each original member, including members of a restaurant group.
  public func restrictToOperators(
    _ result: RouteSearchResult,
    operatorNames: Set<String>,
    criteria: RideCriteria
  ) -> RouteSearchResult? {
    let confirmedNames = operatorNames.intersection(result.operatorChargingPoints.map(\.name))
    let retainedCandidates = result.candidates.filter { candidate in
      candidate.park.operatorChargingPoints
        .filter { confirmedNames.contains($0.name) }
        .reduce(0) { $0 + $1.chargingPointCount }
        >= criteria.minimumChargingPoints.rawValue
    }.sorted { lhs, rhs in
      if lhs.actualDrivingDistance == rhs.actualDrivingDistance {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.actualDrivingDistance < rhs.actualDrivingDistance
    }
    guard let primary = retainedCandidates.first else {
      return nil
    }

    let matchingFoodPOI: FoodPOI?
    if let originalFoodPOI = result.matchingFoodPOI {
      // The restaurant stays the same; its distance belongs to the new representative park.
      guard
        let primaryFoodPOI = primary.foodPOIs.first(where: {
          $0.id == originalFoodPOI.id
            && $0.chain == originalFoodPOI.chain
            && $0.distanceFromPark <= SearchConfiguration.maximumFoodDistance
        })
      else {
        return nil
      }
      matchingFoodPOI = primaryFoodPOI
    } else {
      matchingFoodPOI = nil
    }
    let retainedNames = confirmedNames.intersection(
      retainedCandidates.flatMap(\.park.operatorChargingPoints).map(\.name)
    )
    return RouteSearchResult(
      candidate: primary,
      relatedCandidates: Array(retainedCandidates.dropFirst()),
      matchingFoodPOI: matchingFoodPOI,
      eligibleOperatorNames: retainedNames,
      placeLookupCandidates: result.placeLookupCandidates
    )
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
