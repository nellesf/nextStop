import Foundation
import NextStopCore

struct PlannedRoute: Hashable, Sendable {
  let polyline: RoutePolyline
  let actualDrivingDistance: Meters
  let expectedTravelTimeSeconds: Int
}

enum RoutePlanningError: Error, Equatable {
  case noRoute
  case invalidDistance
  case invalidTravelTime
  case invalidPolyline
}

@MainActor
protocol RoutePlanning: AnyObject {
  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
}
