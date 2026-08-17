import Foundation

public enum ChargingPointAvailabilityState: String, Codable, Sendable {
  case available
  case occupied
  case outOfService = "out_of_service"
  case reserved
  case unknown
}

public enum AvailabilityFreshness: String, Codable, Sendable {
  case fresh
  case stale
  case expired
  case unknown
}

public struct Availability: Hashable, Codable, Sendable {
  public let state: ChargingPointAvailabilityState
  public let observedAt: Date?
  public let receivedAt: Date
  public let isLive: Bool
  public let freshness: AvailabilityFreshness

  public init(
    state: ChargingPointAvailabilityState,
    observedAt: Date?,
    receivedAt: Date,
    isLive: Bool,
    freshness: AvailabilityFreshness
  ) {
    self.state = state
    self.observedAt = observedAt
    self.receivedAt = receivedAt
    self.isLive = isLive
    self.freshness = freshness
  }
}

public struct ParkAvailability: Hashable, Codable, Sendable {
  public let knownAvailableCount: Int
  public let knownUnavailableCount: Int
  public let unknownCount: Int
  public let totalCount: Int
  public let lastLiveObservationAt: Date?

  public var isComplete: Bool {
    unknownCount == 0
  }

  public init(
    knownAvailableCount: Int,
    knownUnavailableCount: Int,
    unknownCount: Int,
    totalCount: Int,
    lastLiveObservationAt: Date? = nil
  ) throws {
    guard knownAvailableCount >= 0,
      knownUnavailableCount >= 0,
      unknownCount >= 0,
      totalCount >= 0
    else {
      throw DomainValidationError.invalidAvailabilityCounts
    }

    let calculatedTotal = knownAvailableCount + knownUnavailableCount + unknownCount
    guard calculatedTotal == totalCount else {
      throw DomainValidationError.availabilityTotalMismatch(
        expected: totalCount,
        actual: calculatedTotal
      )
    }

    self.knownAvailableCount = knownAvailableCount
    self.knownUnavailableCount = knownUnavailableCount
    self.unknownCount = unknownCount
    self.totalCount = totalCount
    self.lastLiveObservationAt = lastLiveObservationAt
  }
}
