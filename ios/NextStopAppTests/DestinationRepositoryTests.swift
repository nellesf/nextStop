import Foundation
import NextStopCore
import SwiftData
import XCTest

@testable import NextStopApp

@MainActor
final class DestinationRepositoryTests: XCTestCase {
  func testRecentDestinationIsDeduplicatedAndUpdatedByApplePlaceIdentifier() throws {
    let (container, repository) = try makeRepository()
    defer { withExtendedLifetime(container) {} }
    let first = try destination(
      name: "Berlin",
      index: 1,
      applePlaceIdentifier: "apple-berlin"
    )
    let updated = try destination(
      name: "Berlin Hauptbahnhof",
      index: 2,
      applePlaceIdentifier: "apple-berlin"
    )

    try repository.recordRecent(first, at: Date(timeIntervalSince1970: 100))
    try repository.recordRecent(updated, at: Date(timeIntervalSince1970: 200))

    let recents = try repository.fetchRecents()
    XCTAssertEqual(recents.count, 1)
    XCTAssertEqual(recents.first?.destination, updated)
    XCTAssertEqual(recents.first?.lastUsedAt, Date(timeIntervalSince1970: 200))
  }

  func testFavoriteCanBeAddedAndRemovedWithoutDeletingARecentDestination() throws {
    let (container, repository) = try makeRepository()
    defer { withExtendedLifetime(container) {} }
    let destination = try destination(name: "Hamburg", index: 3)

    try repository.recordRecent(destination, at: Date(timeIntervalSince1970: 100))
    try repository.setFavorite(
      destination,
      isFavorite: true,
      at: Date(timeIntervalSince1970: 200)
    )
    XCTAssertEqual(try repository.fetchFavorites().map(\.destination), [destination])

    try repository.setFavorite(
      destination,
      isFavorite: false,
      at: Date(timeIntervalSince1970: 300)
    )
    XCTAssertTrue(try repository.fetchFavorites().isEmpty)
    XCTAssertEqual(try repository.fetchRecents().map(\.destination), [destination])
  }

  func testRecentsAreNewestFirstCappedAndDoNotDeleteFavorites() throws {
    let (container, repository) = try makeRepository()
    defer { withExtendedLifetime(container) {} }
    let favorite = try destination(name: "Favorite", index: 99)
    try repository.setFavorite(
      favorite,
      isFavorite: true,
      at: Date(timeIntervalSince1970: 1)
    )

    for index in 0...SearchConfiguration.recentDestinationLimit {
      try repository.recordRecent(
        destination(name: "Destination \(index)", index: index),
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let recents = try repository.fetchRecents()
    XCTAssertEqual(recents.count, SearchConfiguration.recentDestinationLimit)
    XCTAssertEqual(recents.first?.destination.displayName, "Destination 20")
    XCTAssertEqual(recents.last?.destination.displayName, "Destination 1")
    XCTAssertEqual(try repository.fetchFavorites().map(\.destination), [favorite])
  }

  func testRecentAndFavoriteCollectionsCanBeClearedIndependently() throws {
    let (container, repository) = try makeRepository()
    defer { withExtendedLifetime(container) {} }
    let favoriteAndRecent = try destination(name: "Both", index: 4)
    let recentOnly = try destination(name: "Recent", index: 5)

    try repository.recordRecent(favoriteAndRecent, at: Date(timeIntervalSince1970: 100))
    try repository.setFavorite(
      favoriteAndRecent,
      isFavorite: true,
      at: Date(timeIntervalSince1970: 100)
    )
    try repository.recordRecent(recentOnly, at: Date(timeIntervalSince1970: 200))

    try repository.clearRecents()
    XCTAssertTrue(try repository.fetchRecents().isEmpty)
    XCTAssertEqual(
      try repository.fetchFavorites().map(\.destination),
      [favoriteAndRecent]
    )

    try repository.clearFavorites()
    XCTAssertTrue(try repository.fetchFavorites().isEmpty)
  }

  private func makeRepository() throws -> (ModelContainer, SwiftDataDestinationRepository) {
    let schema = Schema([StoredDestinationRecord.self])
    let configuration = ModelConfiguration(
      "DestinationRepositoryTests-\(UUID().uuidString)",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (
      container,
      SwiftDataDestinationRepository(modelContext: container.mainContext)
    )
  }

  private func destination(
    name: String,
    index: Int,
    applePlaceIdentifier: String? = nil
  ) throws -> SavedDestination {
    try SavedDestination(
      displayName: name,
      coordinate: Coordinate(
        latitude: 47 + Double(index) / 1_000,
        longitude: 8 + Double(index) / 1_000
      ),
      applePlaceIdentifier: applePlaceIdentifier,
      displayAddress: "Address \(index)"
    )
  }
}
