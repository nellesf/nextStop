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
protocol DrivingDistanceProviding: AnyObject {
  func automobileDrivingDistance(from origin: Coordinate, to destination: Coordinate) async throws
    -> Meters
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
final class RateLimitedRoutePlanner: RoutePlanning, DrivingDistanceProviding {
  private let base: any RoutePlanning & DrivingDistanceProviding
  private let gate: DirectionsRequestGate

  init(base: any RoutePlanning & DrivingDistanceProviding, gate: DirectionsRequestGate) {
    self.base = base
    self.gate = gate
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    try await gate.acquire()
    return try await base.automobileRoute(from: origin, to: destination)
  }

  func automobileDrivingDistance(from origin: Coordinate, to destination: Coordinate) async throws
    -> Meters
  {
    try await gate.acquire()
    return try await base.automobileDrivingDistance(from: origin, to: destination)
  }
}

@MainActor
final class RetryingRoutePlanner: RoutePlanning, DrivingDistanceProviding {
  private let base: any RoutePlanning & DrivingDistanceProviding
  private let maximumAttempts: Int
  private let retryDelay: Duration

  init(
    base: any RoutePlanning & DrivingDistanceProviding,
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
    try await withRetry {
      try await base.automobileRoute(from: origin, to: destination)
    }
  }

  func automobileDrivingDistance(from origin: Coordinate, to destination: Coordinate) async throws
    -> Meters
  {
    try await withRetry {
      try await base.automobileDrivingDistance(from: origin, to: destination)
    }
  }

  private func withRetry<Value>(
    _ operation: @MainActor () async throws -> Value
  ) async throws -> Value {
    for attempt in 1...maximumAttempts {
      do {
        return try await operation()
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
