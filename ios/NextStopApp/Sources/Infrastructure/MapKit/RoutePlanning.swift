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
final class DirectionsRequestGate {
  typealias Now = @MainActor () -> Date
  typealias Sleep = @MainActor (TimeInterval) async throws -> Void

  private let maximumRequests: Int
  private let windowSeconds: TimeInterval
  private let now: Now
  private let sleep: Sleep
  private var requestDates: [Date] = []

  init(
    maximumRequests: Int = 45,
    windowSeconds: TimeInterval = 60,
    now: @escaping Now = Date.init,
    sleep: @escaping Sleep = { seconds in
      try await Task.sleep(
        for: .milliseconds(Int64((seconds * 1_000).rounded(.up)))
      )
    }
  ) {
    precondition(maximumRequests > 0)
    precondition(windowSeconds > 0)
    self.maximumRequests = maximumRequests
    self.windowSeconds = windowSeconds
    self.now = now
    self.sleep = sleep
  }

  func acquire() async throws {
    while true {
      try Task.checkCancellation()
      let currentDate = now()
      requestDates.removeAll {
        currentDate.timeIntervalSince($0) >= windowSeconds
      }
      guard requestDates.count >= maximumRequests,
        let oldestRequestDate = requestDates.first
      else {
        requestDates.append(currentDate)
        return
      }
      let remainingSeconds = max(
        windowSeconds - currentDate.timeIntervalSince(oldestRequestDate),
        0.001
      )
      try await sleep(remainingSeconds)
    }
  }
}

@MainActor
final class RateLimitedRoutePlanner: RoutePlanning {
  private let base: any RoutePlanning
  private let gate: DirectionsRequestGate

  init(base: any RoutePlanning, gate: DirectionsRequestGate) {
    self.base = base
    self.gate = gate
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    try await gate.acquire()
    return try await base.automobileRoute(from: origin, to: destination)
  }
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
