import Foundation

public struct SavedDestination: Hashable, Codable, Sendable {
  public let displayName: String
  public let coordinate: Coordinate
  public let applePlaceIdentifier: String?
  public let displayAddress: String?

  public init(
    displayName: String,
    coordinate: Coordinate,
    applePlaceIdentifier: String? = nil,
    displayAddress: String? = nil
  ) throws {
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    self.displayName = displayName
    self.coordinate = coordinate
    self.applePlaceIdentifier = applePlaceIdentifier
    self.displayAddress = displayAddress
  }
}

public struct UserProfile: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public var destination: SavedDestination
  public var criteria: RideCriteria
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    destination: SavedDestination,
    criteria: RideCriteria,
    createdAt: Date,
    updatedAt: Date
  ) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    self.id = id
    self.name = name
    self.destination = destination
    self.criteria = criteria
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RideSearchDraft: Hashable, Codable, Sendable {
  public var destination: SavedDestination
  public var criteria: RideCriteria
  public let sourceProfileID: UUID?

  public init(profile: UserProfile) {
    destination = profile.destination
    criteria = profile.criteria
    sourceProfileID = profile.id
  }

  public init(destination: SavedDestination) {
    self.destination = destination
    criteria = SearchConfiguration.defaultCriteria
    sourceProfileID = nil
  }
}
