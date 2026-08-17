import Foundation
import NextStopCore

struct CandidateSearchRequestDTO: Encodable, Equatable {
  let requestId: UUID
  let route: RouteLineStringDTO
  let criteria: SearchCriteriaDTO
  let page: PageDTO?

  init(request: RouteSearchRequest) {
    requestId = request.requestID
    route = RouteLineStringDTO(polyline: request.route)
    criteria = SearchCriteriaDTO(criteria: request.criteria)

    if request.snapshotToken != nil || request.cursor != nil {
      page = PageDTO(
        snapshotToken: request.snapshotToken,
        cursor: request.cursor
      )
    } else {
      page = nil
    }
  }

  struct RouteLineStringDTO: Encodable, Equatable {
    let type = "LineString"
    let coordinates: [[Double]]

    init(polyline: RoutePolyline) {
      coordinates = polyline.coordinates.map { [$0.longitude, $0.latitude] }
    }
  }

  struct SearchCriteriaDTO: Encodable, Equatable {
    let distanceRangeMeters: DistanceRangeDTO
    let minimumChargingPoints: Int
    let minimumPowerKW: Int
    let foodChain: String?

    init(criteria: RideCriteria) {
      distanceRangeMeters = DistanceRangeDTO(
        minimum: criteria.distanceRange.range.lowerBound.value,
        maximum: criteria.distanceRange.range.upperBound.value
      )
      minimumChargingPoints = criteria.minimumChargingPoints.rawValue
      minimumPowerKW = criteria.minimumPower.rawValue
      foodChain = criteria.foodChain?.rawValue
    }
  }

  struct DistanceRangeDTO: Encodable, Equatable {
    let minimum: Int
    let maximum: Int
  }

  struct PageDTO: Encodable, Equatable {
    let snapshotToken: String?
    let cursor: String?
  }
}
