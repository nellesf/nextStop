import MapKit
import NextStopCore

enum CarPlayPlaceResolutionError: Error, Equatable {
  case operatorUnavailable
  case restaurantUnavailable
  case placeNotFound
}

@MainActor
protocol CarPlayResultPlaceResolving: AnyObject {
  func resolveOperator(named operatorName: String, in result: RouteSearchResult) async throws
    -> MKMapItem

  func resolveRestaurant(in result: RouteSearchResult) async throws -> MKMapItem
}

@MainActor
final class CarPlayResultPlaceResolver: CarPlayResultPlaceResolving {
  private let placeResolver: any ApplePlaceResolving
  private var restaurantPlaces: [FoodPOI: MKMapItem] = [:]

  init(placeResolver: any ApplePlaceResolving = MapKitApplePlaceResolver()) {
    self.placeResolver = placeResolver
  }

  func resolveOperator(named operatorName: String, in result: RouteSearchResult) async throws
    -> MKMapItem
  {
    try Task.checkCancellation()
    guard let park = result.representativePark(for: operatorName) else {
      throw CarPlayPlaceResolutionError.operatorUnavailable
    }

    let relatedLocations =
      result.matchingFoodPOI != nil
      ? AppleChargingPlaceLookupScope.restaurantGroupLocations(
        candidateLocations: result.locationLookups,
        operatorName: operatorName
      )
      : AppleChargingPlaceLookupScope.relatedLocations(
        primaryLocations: park.locationLookups,
        candidateLocations: result.locationLookups,
        operatorName: operatorName
      )
    let resultGroup = AppleChargingPlaceResultGroup(
      id: result.matchingFoodPOI.map { "restaurant:\($0.id)" }
        ?? "park:\(result.id.uuidString)",
      kind: result.matchingFoodPOI == nil ? .noFoodCampus : .restaurant,
      evidenceLocations: result.locationLookups,
      searchCoordinates: result.candidates.map(\.park.navigationCoordinate),
      restaurantCoordinate: result.matchingFoodPOI?.coordinate
    )
    let mapItem = await placeResolver.resolveChargingPlace(
      park: park,
      operatorName: operatorName,
      relatedLocations: relatedLocations,
      resultGroup: resultGroup
    )
    try Task.checkCancellation()
    guard let mapItem else {
      throw CarPlayPlaceResolutionError.placeNotFound
    }
    return mapItem
  }

  func resolveRestaurant(in result: RouteSearchResult) async throws -> MKMapItem {
    try Task.checkCancellation()
    guard let foodPOI = result.matchingFoodPOI else {
      throw CarPlayPlaceResolutionError.restaurantUnavailable
    }
    if let mapItem = restaurantPlaces[foodPOI] {
      return mapItem
    }

    let mapItem = await placeResolver.resolveRestaurantPlace(foodPOI)
    try Task.checkCancellation()
    guard let mapItem else {
      throw CarPlayPlaceResolutionError.placeNotFound
    }
    restaurantPlaces[foodPOI] = mapItem
    return mapItem
  }
}
