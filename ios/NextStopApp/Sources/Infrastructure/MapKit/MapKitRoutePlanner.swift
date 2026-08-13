import CoreLocation
import MapKit
import NextStopCore

@MainActor
final class MapKitRoutePlanner: RoutePlanning {
  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    let request = MKDirections.Request()
    request.source = Self.makeMapItem(for: origin)
    request.destination = Self.makeMapItem(for: destination)
    request.transportType = .automobile
    request.requestsAlternateRoutes = false

    let response = try await MKDirections(request: request).calculate()
    guard let route = response.routes.first else {
      throw RoutePlanningError.noRoute
    }
    guard route.distance.isFinite, route.distance >= 0 else {
      throw RoutePlanningError.invalidDistance
    }
    guard route.expectedTravelTime.isFinite, route.expectedTravelTime >= 0 else {
      throw RoutePlanningError.invalidTravelTime
    }

    let coordinates: [Coordinate]
    do {
      coordinates = try route.polyline.nextStopCoordinates.map { mapCoordinate in
        try Coordinate(
          latitude: mapCoordinate.latitude,
          longitude: mapCoordinate.longitude
        )
      }
    } catch {
      throw RoutePlanningError.invalidPolyline
    }
    guard let polyline = try? RoutePolyline(coordinates: coordinates) else {
      throw RoutePlanningError.invalidPolyline
    }

    return PlannedRoute(
      polyline: polyline,
      actualDrivingDistance: Meters(Int(route.distance.rounded())),
      expectedTravelTimeSeconds: max(0, Int(route.expectedTravelTime.rounded()))
    )
  }

  private static func makeMapItem(for coordinate: Coordinate) -> MKMapItem {
    let location = CLLocation(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    )
    if #available(iOS 26.0, *) {
      return MKMapItem(location: location, address: nil)
    } else {
      return makeLegacyMapItem(for: location)
    }
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private static func makeLegacyMapItem(for location: CLLocation) -> MKMapItem {
    MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
  }
}

extension MKPolyline {
  fileprivate var nextStopCoordinates: [CLLocationCoordinate2D] {
    let pointBuffer = points()
    return (0..<pointCount).map { pointBuffer[$0].coordinate }
  }
}
