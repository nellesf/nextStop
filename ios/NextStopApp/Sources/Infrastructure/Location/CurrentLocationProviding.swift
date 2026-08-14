import Foundation
import NextStopCore

enum CurrentLocationError: Error, Equatable {
  case authorizationDenied
  case authorizationRestricted
  case reducedAccuracy
  case requestAlreadyInProgress
  case unavailable
}

@MainActor
protocol CurrentLocationProviding: AnyObject {
  func currentLocation() async throws -> Coordinate
}
