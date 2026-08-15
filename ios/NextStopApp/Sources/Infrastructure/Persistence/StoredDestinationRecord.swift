import Foundation
import NextStopCore
import SwiftData

@Model
final class StoredDestinationRecord {
  @Attribute(.unique) var lookupKey: String
  @Attribute(.unique) var id: UUID
  var displayName: String
  var latitude: Double
  var longitude: Double
  var applePlaceIdentifier: String?
  var displayAddress: String?
  var isFavorite: Bool
  var favoriteAddedAt: Date?
  var lastUsedAt: Date?

  init(
    id: UUID = UUID(),
    destination: SavedDestination,
    isFavorite: Bool = false,
    favoriteAddedAt: Date? = nil,
    lastUsedAt: Date? = nil
  ) {
    lookupKey = Self.makeLookupKey(destination)
    self.id = id
    displayName = destination.displayName
    latitude = destination.coordinate.latitude
    longitude = destination.coordinate.longitude
    applePlaceIdentifier = destination.applePlaceIdentifier
    displayAddress = destination.displayAddress
    self.isFavorite = isFavorite
    self.favoriteAddedAt = favoriteAddedAt
    self.lastUsedAt = lastUsedAt
  }

  func updateDestination(_ destination: SavedDestination) {
    lookupKey = Self.makeLookupKey(destination)
    displayName = destination.displayName
    latitude = destination.coordinate.latitude
    longitude = destination.coordinate.longitude
    applePlaceIdentifier = destination.applePlaceIdentifier
    displayAddress = destination.displayAddress
  }

  func domainDestination() throws -> SavedDestination {
    try SavedDestination(
      displayName: displayName,
      coordinate: Coordinate(latitude: latitude, longitude: longitude),
      applePlaceIdentifier: applePlaceIdentifier,
      displayAddress: displayAddress
    )
  }

  static func makeLookupKey(_ destination: SavedDestination) -> String {
    if let placeIdentifier = destination.applePlaceIdentifier,
      !placeIdentifier.isEmpty
    {
      return "apple:\(placeIdentifier)"
    }
    let normalizedName = destination.displayName
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(
      format: "coordinate:%.6f:%.6f:%@",
      locale: Locale(identifier: "en_US_POSIX"),
      destination.coordinate.latitude,
      destination.coordinate.longitude,
      normalizedName
    )
  }
}
