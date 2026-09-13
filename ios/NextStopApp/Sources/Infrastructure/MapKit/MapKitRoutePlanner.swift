import CoreLocation
import MapKit
import NextStopCore

@MainActor
final class MapKitRoutePlanner: RoutePlanning, DrivingDistanceProviding {
  typealias CalculateRoute = @MainActor (MKDirections.Request) async throws -> MKRoute?

  private let calculateRoute: CalculateRoute
  private let measurement: AppDiagnosticMeasurement

  // Keep the existing single trailing-closure test/injection API unambiguous.
  convenience init(calculateRoute: @escaping CalculateRoute) {
    self.init(diagnostics: NoopAppDiagnostics(), now: Date.init, calculateRoute: calculateRoute)
  }

  init(
    diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics(),
    now: @escaping AppDiagnosticMeasurement.Now = Date.init,
    calculateRoute: @escaping CalculateRoute = { request in
      try await MKDirections(request: request).calculate().routes.first
    }
  ) {
    self.calculateRoute = calculateRoute
    measurement = AppDiagnosticMeasurement(recorder: diagnostics, now: now)
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    try await measurement.perform(.route) {
      try await plannedRoute(from: origin, to: destination)
    }
  }

  private func plannedRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    let route = try await route(from: origin, to: destination)
    let actualDrivingDistance = try drivingDistance(of: route)
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
      actualDrivingDistance: actualDrivingDistance,
      expectedTravelTimeSeconds: max(0, Int(route.expectedTravelTime.rounded()))
    )
  }

  func automobileDrivingDistance(from origin: Coordinate, to destination: Coordinate) async throws
    -> Meters
  {
    try await measurement.perform(.candidateDistance) {
      let route = try await route(from: origin, to: destination)
      // A valid zero-distance response can contain only one distinct route point.
      // Candidate filtering needs Apple's distance, not a corridor polyline.
      return try drivingDistance(of: route)
    }
  }

  private func route(from origin: Coordinate, to destination: Coordinate) async throws -> MKRoute {
    let request = MKDirections.Request()
    request.source = Self.makeMapItem(for: origin)
    request.destination = Self.makeMapItem(for: destination)
    request.transportType = .automobile
    request.requestsAlternateRoutes = false

    guard let route = try await calculateRoute(request) else {
      throw RoutePlanningError.noRoute
    }
    return route
  }

  private func drivingDistance(of route: MKRoute) throws -> Meters {
    guard route.distance.isFinite, route.distance >= 0,
      route.distance.rounded() < Double(Int.max)
    else {
      throw RoutePlanningError.invalidDistance
    }
    return Meters(Int(route.distance.rounded()))
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
