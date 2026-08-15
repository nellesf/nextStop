import Foundation
import NextStopCore

struct LocalDestinationRecord: Identifiable, Hashable, Sendable {
  let id: UUID
  let destination: SavedDestination
  let isFavorite: Bool
  let favoriteAddedAt: Date?
  let lastUsedAt: Date?
}

@MainActor
protocol DestinationRepository {
  func fetchFavorites() throws -> [LocalDestinationRecord]
  func fetchRecents() throws -> [LocalDestinationRecord]
  func recordRecent(_ destination: SavedDestination, at date: Date) throws
  func setFavorite(_ destination: SavedDestination, isFavorite: Bool, at date: Date) throws
  func removeRecent(_ destination: SavedDestination) throws
  func clearRecents() throws
  func clearFavorites() throws
}
