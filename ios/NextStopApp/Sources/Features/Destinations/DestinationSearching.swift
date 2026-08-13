import Foundation
import NextStopCore

struct DestinationSearchResult: Identifiable, Hashable, Sendable {
  let id: String
  let destination: SavedDestination
  let subtitle: String?
}

@MainActor
protocol DestinationSearching: AnyObject {
  func search(query: String) async throws -> [DestinationSearchResult]
}
