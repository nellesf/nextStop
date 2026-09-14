import Foundation
import NextStopCore
import SwiftData
import XCTest

@testable import NextStopApp

@MainActor
final class ProfileRepositoryTests: XCTestCase {
  func testPrepareCarPlayScreenshotProfile() throws {
    #if targetEnvironment(simulator)
      guard ProcessInfo.processInfo.environment["NEXTSTOP_CARPLAY_CAPTURE"] == "1" else {
        throw XCTSkip("The persistent screenshot fixture requires explicit opt-in.")
      }

      // Use the production schema and default persistent URL in the hosted app's
      // sandbox, exactly as the SwiftUI root and CarPlay scene do.
      let container = try ModelContainer(for: StoredProfile.self, StoredDestinationRecord.self)
      let repository = SwiftDataProfileRepository(modelContext: container.mainContext)
      guard
        try repository.fetchProfiles().isEmpty,
        try container.mainContext.fetchCount(FetchDescriptor<StoredDestinationRecord>()) == 0
      else {
        XCTFail("Screenshot preparation requires a fresh store; existing data is never deleted.")
        return
      }

      let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
      let profile = try UserProfile(
        id: UUID(uuidString: "B7303CD0-6EC3-4D25-8FD2-61F8CEDDCA00")!,
        name: "Leipzig",
        destination: SavedDestination(
          displayName: "Leipzig",
          coordinate: Coordinate(latitude: 51.3397, longitude: 12.3731),
          applePlaceIdentifier: nil,
          displayAddress: "Leipzig, Deutschland"
        ),
        criteria: RideCriteria(
          distanceRange: SearchConfiguration.defaultCriteria.distanceRange,
          minimumChargingPoints: .four,
          minimumPower: .oneHundredFifty,
          foodChain: .mcdonalds
        ),
        createdAt: timestamp,
        updatedAt: timestamp
      )
      try repository.save(profile)

      // Fetch through a separate context so validation does not reuse inserted
      // model instances from the writing context.
      let readback = SwiftDataProfileRepository(modelContext: ModelContext(container))
      XCTAssertEqual(try readback.fetchProfiles(), [profile])

      let attachment = XCTAttachment(
        string: """
          Fixture: public Leipzig example, prepared by an opt-in hosted unit test.
          Repository: unchanged SwiftDataProfileRepository.
          Store: production default persistent container in the simulator app sandbox.
          Profile ID: \(profile.id.uuidString)
          Destination: Leipzig, Deutschland (51.3397, 12.3731).
          Criteria: default distance range, 150 kW, 4 EVSEs, McDonald's.
          Existing data: required empty; nothing deleted.
          """
      )
      attachment.name = "carplay-screenshot-profile-fixture"
      attachment.lifetime = .keepAlways
      add(attachment)
    #else
      throw XCTSkip("Persistent screenshot fixtures are supported only in the iOS simulator.")
    #endif
  }

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
        minimumPower: .oneHundredFifty,
        foodChain: .mcdonalds
      ),
      createdAt: firstTimestamp,
      updatedAt: firstTimestamp.addingTimeInterval(60)
    )
    try repository.save(updated)

    XCTAssertEqual(try repository.fetchProfiles(), [updated])

    let withoutRestaurant = try UserProfile(
      id: profileID,
      name: "Updated",
      destination: original.destination,
      criteria: RideCriteria(
        distanceRange: updated.criteria.distanceRange,
        minimumChargingPoints: updated.criteria.minimumChargingPoints,
        minimumPower: updated.criteria.minimumPower,
        foodChain: nil
      ),
      createdAt: firstTimestamp,
      updatedAt: firstTimestamp.addingTimeInterval(120)
    )
    try repository.save(withoutRestaurant)

    XCTAssertEqual(try repository.fetchProfiles(), [withoutRestaurant])

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

  func testLegacyAvailabilityValueIsIgnoredWhenLoadingAProfile() throws {
    let (container, repository) = try makeRepository()
    let profile = try makeProfile(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Legacy",
      timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let stored = StoredProfile(profile: profile)
    stored.minimumAvailablePointsRawValue = 999
    container.mainContext.insert(stored)
    try container.mainContext.save()

    XCTAssertEqual(try repository.fetchProfiles(), [profile])
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
