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

@MainActor
final class RetryingRoutePlanner: RoutePlanning {
  private let base: any RoutePlanning
  private let maximumAttempts: Int
  private let retryDelay: Duration

  init(
    base: any RoutePlanning,
    maximumAttempts: Int = 2,
    retryDelay: Duration = .milliseconds(300)
  ) {
    precondition(maximumAttempts > 0)
    self.base = base
    self.maximumAttempts = maximumAttempts
    self.retryDelay = retryDelay
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    for attempt in 1...maximumAttempts {
      do {
        return try await base.automobileRoute(from: origin, to: destination)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard attempt < maximumAttempts else {
          throw error
        }
        try await Task.sleep(for: retryDelay)
      }
    }
    preconditionFailure("A positive route attempt count must execute at least once")
  }
}
