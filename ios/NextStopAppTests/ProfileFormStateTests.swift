import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

final class ProfileFormStateTests: XCTestCase {
  func testNewProfileUsesCentralDefaultCriteria() {
    let state = ProfileFormState()

    XCTAssertEqual(state.distanceRange, SearchConfiguration.defaultCriteria.distanceRange)
    XCTAssertEqual(
      state.minimumChargingPoints,
      SearchConfiguration.defaultCriteria.minimumChargingPoints
    )
    XCTAssertEqual(
      state.minimumAvailablePoints,
      SearchConfiguration.defaultCriteria.minimumAvailablePoints
    )
    XCTAssertEqual(state.minimumPower, SearchConfiguration.defaultCriteria.minimumPower)
    XCTAssertEqual(state.foodChain, SearchConfiguration.defaultCriteria.foodChain)
  }

  func testProfileRequiresNameBeforeDestination() {
    let state = ProfileFormState()

    XCTAssertThrowsError(try state.makeProfile(now: Date())) { error in
      XCTAssertEqual(error as? ProfileFormValidationError, .nameRequired)
    }
  }

  func testProfileRequiresDestination() {
    var state = ProfileFormState()
    state.name = "Home"

    XCTAssertThrowsError(try state.makeProfile(now: Date())) { error in
      XCTAssertEqual(error as? ProfileFormValidationError, .destinationRequired)
    }
  }

  func testUpdatingProfilePreservesIdentityAndCreationDate() throws {
    let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let profile = try UserProfile(
      id: profileID,
      name: "Work",
      destination: makeDestination(name: "Hamburg"),
      criteria: SearchConfiguration.defaultCriteria,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    var state = ProfileFormState(profile: profile)
    state.name = "Work updated"
    let updatedAt = createdAt.addingTimeInterval(60)

    let updatedProfile = try state.makeProfile(now: updatedAt)

    XCTAssertEqual(updatedProfile.id, profileID)
    XCTAssertEqual(updatedProfile.createdAt, createdAt)
    XCTAssertEqual(updatedProfile.updatedAt, updatedAt)
    XCTAssertEqual(updatedProfile.name, "Work updated")
  }

  func testNewProfileTrimsNameAndUsesInjectedIdentity() throws {
    let profileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = ProfileFormState()
    state.name = "  Weekend  "
    state.destination = try makeDestination(name: "Berlin")

    let profile = try state.makeProfile(now: now, newID: profileID)

    XCTAssertEqual(profile.id, profileID)
    XCTAssertEqual(profile.name, "Weekend")
    XCTAssertEqual(profile.createdAt, now)
    XCTAssertEqual(profile.updatedAt, now)
  }

  private func makeDestination(name: String) throws -> SavedDestination {
    try SavedDestination(
      displayName: name,
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
  }
}
