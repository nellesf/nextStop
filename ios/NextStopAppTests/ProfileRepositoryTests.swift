import Foundation
import NextStopCore
import SwiftData
import XCTest

@testable import NextStopApp

@MainActor
final class ProfileRepositoryTests: XCTestCase {
  func testSwiftDataRepositoryCreatesUpdatesAndDeletesProfile() throws {
    let (container, repository) = try makeRepository()
    defer { withExtendedLifetime(container) {} }
    let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let original = try makeProfile(
      id: profileID,
      name: "Original",
      timestamp: firstTimestamp
    )

    try repository.save(original)
    XCTAssertEqual(try repository.fetchProfiles(), [original])

    let updated = try UserProfile(
      id: profileID,
      name: "Updated",
      destination: original.destination,
      criteria: RideCriteria(
        distanceRange: .kilometers100To150,
        minimumChargingPoints: .eight,
        minimumAvailablePoints: .four,
        minimumPower: .oneHundredFifty,
        foodChain: .mcdonalds
      ),
      createdAt: firstTimestamp,
      updatedAt: firstTimestamp.addingTimeInterval(60)
    )
    try repository.save(updated)

    XCTAssertEqual(try repository.fetchProfiles(), [updated])

    try repository.delete(id: profileID)
    XCTAssertTrue(try repository.fetchProfiles().isEmpty)
  }

  func testInMemoryRepositorySortsMostRecentlyUpdatedFirst() throws {
    let older = try makeProfile(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Older",
      timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let newer = try makeProfile(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      name: "Newer",
      timestamp: Date(timeIntervalSince1970: 1_700_000_060)
    )
    let repository = InMemoryProfileRepository(profiles: [older, newer])

    XCTAssertEqual(repository.fetchProfiles().map(\.id), [newer.id, older.id])
  }

  private func makeRepository() throws -> (ModelContainer, SwiftDataProfileRepository) {
    let schema = Schema([StoredProfile.self])
    let configuration = ModelConfiguration(
      "ProfileRepositoryTests-\(UUID().uuidString)",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let repository = SwiftDataProfileRepository(modelContext: container.mainContext)
    return (container, repository)
  }

  private func makeProfile(id: UUID, name: String, timestamp: Date) throws -> UserProfile {
    try UserProfile(
      id: id,
      name: name,
      destination: SavedDestination(
        displayName: "Hamburg",
        coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937),
        applePlaceIdentifier: "hamburg",
        displayAddress: "Hamburg, Deutschland"
      ),
      criteria: SearchConfiguration.defaultCriteria,
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }
}
