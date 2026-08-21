import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
  case negativeMeters(Int)
  case nonPositiveKilowatts(Int)
  case invalidLatitude(Double)
  case invalidLongitude(Double)
  case invalidAvailabilityCounts
  case availabilityTotalMismatch(expected: Int, actual: Int)
  case nonPositiveChargingPointCount(Int)
  case operatorChargingPointTotalMismatch(expected: Int, actual: Int)
  case locationLookupOperatorNotInPark(String)
  case emptyName
  case emptySourceIdentifier
  case routeRequiresAtLeastTwoCoordinates
  case routeRequiresDistinctCoordinates
  case routeHasTooManyCoordinates(maximum: Int, actual: Int)
  case routeCoordinateOutsideSupportedEnvelope(
    index: Int,
    latitude: Double,
    longitude: Double
  )
  case routeSegmentExceedsMaximumLength(
    startCoordinateIndex: Int,
    maximum: Meters,
    actual: Meters
  )
  case routeExceedsMaximumLength(maximum: Meters, actual: Meters)
}

public struct Meters: Hashable, Comparable, Codable, Sendable {
  public let value: Int

  public init(_ value: Int) {
    precondition(value >= 0, "Meters cannot be negative")
    self.value = value
  }

  public static func < (lhs: Meters, rhs: Meters) -> Bool {
    lhs.value < rhs.value
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let decodedValue = try container.decode(Int.self)
    guard decodedValue >= 0 else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Meters cannot be negative"
      )
    }
    value = decodedValue
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct Kilowatts: Hashable, Comparable, Codable, Sendable {
  public let value: Int

  public init(_ value: Int) {
    precondition(value > 0, "Kilowatts must be positive")
    self.value = value
  }

  public static func < (lhs: Kilowatts, rhs: Kilowatts) -> Bool {
    lhs.value < rhs.value
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let decodedValue = try container.decode(Int.self)
    guard decodedValue > 0 else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Kilowatts must be positive"
      )
    }
    value = decodedValue
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct Coordinate: Hashable, Codable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) throws {
    guard latitude.isFinite, (-90.0...90.0).contains(latitude) else {
      throw DomainValidationError.invalidLatitude(latitude)
    }
    guard longitude.isFinite, (-180.0...180.0).contains(longitude) else {
      throw DomainValidationError.invalidLongitude(longitude)
    }
    self.latitude = latitude
    self.longitude = longitude
  }

  private enum CodingKeys: String, CodingKey {
    case latitude
    case longitude
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let latitude = try container.decode(Double.self, forKey: .latitude)
    let longitude = try container.decode(Double.self, forKey: .longitude)
    try self.init(latitude: latitude, longitude: longitude)
  }
}
