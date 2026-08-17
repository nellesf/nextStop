import CoreLocation
import MapKit
import NextStopCore

@MainActor
protocol FoodPOISearching: AnyObject {
  func foodPOIs(chain: FoodChain, near coordinate: Coordinate) async throws -> [FoodPOI]
}

@MainActor
final class MapKitCandidateEnricher: CandidateEnriching {
  private let routePlanner: any RoutePlanning
  private let foodSearcher: any FoodPOISearching

  init(
    routePlanner: any RoutePlanning = RetryingRoutePlanner(base: MapKitRoutePlanner()),
    foodSearcher: any FoodPOISearching = MapKitFoodPOISearchService()
  ) {
    self.routePlanner = routePlanner
    self.foodSearcher = foodSearcher
  }

  func enrich(
    candidate: BackendCandidate,
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichedChargingParkCandidate {
    let drivingRoute: PlannedRoute
    do {
      drivingRoute = try await routePlanner.automobileRoute(
        from: origin,
        to: candidate.park.navigationCoordinate
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CandidateEnrichmentError.drivingRouteUnavailable
    }

    var foodPOIs: [FoodPOI] = []
    if criteria.distanceRange.range.contains(drivingRoute.actualDrivingDistance),
      let foodChain = criteria.foodChain
    {
      do {
        foodPOIs = try await foodSearcher.foodPOIs(
          chain: foodChain,
          near: candidate.park.navigationCoordinate
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw CandidateEnrichmentError.foodSearchUnavailable
      }
    }

    return EnrichedChargingParkCandidate(
      park: candidate.park,
      distanceFromRoute: candidate.distanceFromRoute,
      actualDrivingDistance: drivingRoute.actualDrivingDistance,
      foodPOIs: foodPOIs
    )
  }
}

@MainActor
final class MapKitFoodPOISearchService: FoodPOISearching {
  func foodPOIs(chain: FoodChain, near parkCoordinate: Coordinate) async throws -> [FoodPOI] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query(for: chain)
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant])
    request.region = MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: parkCoordinate.latitude,
        longitude: parkCoordinate.longitude
      ),
      latitudinalMeters: 1_200,
      longitudinalMeters: 1_200
    )
    let response = try await MKLocalSearch(request: request).start()
    let parkLocation = CLLocation(
      latitude: parkCoordinate.latitude,
      longitude: parkCoordinate.longitude
    )
    return try response.mapItems.compactMap { mapItem in
      guard let name = mapItem.name,
        matches(name: name, chain: chain),
        let itemCoordinate = coordinate(for: mapItem)
      else {
        return nil
      }
      let itemLocation = CLLocation(
        latitude: itemCoordinate.latitude,
        longitude: itemCoordinate.longitude
      )
      let distance = Int(parkLocation.distance(from: itemLocation).rounded())
      guard distance <= SearchConfiguration.maximumFoodDistance.value else {
        return nil
      }
      return try FoodPOI(
        id: stablePOIID(name: name, coordinate: itemCoordinate),
        applePlaceIdentifier: mapItem.identifier?.rawValue,
        chain: chain,
        name: name,
        coordinate: itemCoordinate,
        distanceFromPark: Meters(distance),
        openingStatus: .unknown
      )
    }
    .sorted { first, second in
      if first.distanceFromPark == second.distanceFromPark {
        return first.id < second.id
      }
      return first.distanceFromPark < second.distanceFromPark
    }
  }

  private func query(for chain: FoodChain) -> String {
    switch chain {
    case .mcdonalds:
      "McDonald's"
    case .burgerKing:
      "Burger King"
    case .kfc:
      "KFC"
    case .subway:
      "Subway Restaurant"
    }
  }

  private func matches(name: String, chain: FoodChain) -> Bool {
    let normalized = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "de_DE")
    )
    .lowercased()
    .filter(\.isLetter)
    switch chain {
    case .mcdonalds:
      return normalized.contains("mcdonald")
    case .burgerKing:
      return normalized.contains("burgerking")
    case .kfc:
      return normalized == "kfc" || normalized.contains("kentuckyfriedchicken")
    case .subway:
      return normalized.contains("subway")
    }
  }

  private func coordinate(for mapItem: MKMapItem) -> Coordinate? {
    let location: CLLocation
    if #available(iOS 26.0, *) {
      location = mapItem.location
    } else {
      return legacyCoordinate(for: mapItem)
    }
    return try? Coordinate(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude
    )
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private func legacyCoordinate(for mapItem: MKMapItem) -> Coordinate? {
    try? Coordinate(
      latitude: mapItem.placemark.coordinate.latitude,
      longitude: mapItem.placemark.coordinate.longitude
    )
  }

  private func stablePOIID(name: String, coordinate: Coordinate) -> String {
    "mapkit:\(name.lowercased()):\(coordinate.latitude):\(coordinate.longitude)"
  }
}
