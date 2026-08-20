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
    XCTAssertEqual(state.minimumPower, SearchConfiguration.defaultCriteria.minimumPower)
    XCTAssertFalse(state.requiresNearbyRestaurant)
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

  func testExistingProfileLoadsAndPersistsDestinationAndEveryCriterion() throws {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let destination = try SavedDestination(
      displayName: "Berlin",
      coordinate: Coordinate(latitude: 52.5200, longitude: 13.4050),
      applePlaceIdentifier: "berlin-place",
      displayAddress: "Berlin, Deutschland"
    )
    let criteria = RideCriteria(
      distanceRange: .kilometers100To150,
      minimumChargingPoints: .sixteen,
      minimumPower: .threeHundred,
      foodChain: .burgerKing
    )
    let profile = try UserProfile(
      name: "Langstrecke",
      destination: destination,
      criteria: criteria,
      createdAt: timestamp,
      updatedAt: timestamp
    )

    let state = ProfileFormState(profile: profile)
    let savedProfile = try state.makeProfile(now: timestamp.addingTimeInterval(60))

    XCTAssertEqual(state.destination, destination)
    XCTAssertEqual(state.distanceRange, criteria.distanceRange)
    XCTAssertEqual(state.minimumChargingPoints, criteria.minimumChargingPoints)
    XCTAssertEqual(state.minimumPower, criteria.minimumPower)
    XCTAssertTrue(state.requiresNearbyRestaurant)
    XCTAssertEqual(state.foodChain, criteria.foodChain)
    XCTAssertEqual(savedProfile.destination, destination)
    XCTAssertEqual(savedProfile.criteria, criteria)
  }

  func testRestaurantModeRequiresAChainBeforeSaving() throws {
    var state = ProfileFormState()
    state.name = "Pause"
    state.destination = try makeDestination(name: "München")
    state.requiresNearbyRestaurant = true

    XCTAssertThrowsError(try state.makeProfile(now: Date())) { error in
      XCTAssertEqual(error as? ProfileFormValidationError, .restaurantChainRequired)
    }
  }

  func testDisabledRestaurantModePersistsNoChain() throws {
    var state = ProfileFormState()
    state.name = "Ohne Pause"
    state.destination = try makeDestination(name: "Köln")
    state.foodChain = .subway
    state.requiresNearbyRestaurant = false

    let profile = try state.makeProfile(now: Date())

    XCTAssertNil(profile.criteria.foodChain)
  }

  func testRestaurantModeRestoresSelectionWithinTheSameEditSession() throws {
    var state = ProfileFormState()
    state.name = "Kaffeepause"
    state.destination = try makeDestination(name: "Berlin")
    state.requiresNearbyRestaurant = true
    state.foodChain = .burgerKing

    state.requiresNearbyRestaurant = false
    XCTAssertEqual(state.foodChain, .burgerKing)

    state.requiresNearbyRestaurant = true
    let profile = try state.makeProfile(now: Date())

    XCTAssertEqual(profile.criteria.foodChain, .burgerKing)
  }

  func testChargingPointNavigationUsesOnlyConfiguredOptionsAndStopsAtBounds() {
    var state = ProfileFormState()

    state.minimumChargingPoints = .two
    state.selectPreviousMinimumChargingPoints()
    XCTAssertEqual(state.minimumChargingPoints, .two)

    state.selectNextMinimumChargingPoints()
    XCTAssertEqual(state.minimumChargingPoints, .four)

    state.minimumChargingPoints = .twelve
    state.selectNextMinimumChargingPoints()
    XCTAssertEqual(state.minimumChargingPoints, .sixteen)

    state.selectPreviousMinimumChargingPoints()
    XCTAssertEqual(state.minimumChargingPoints, .twelve)

    state.minimumChargingPoints = .twenty
    state.selectNextMinimumChargingPoints()
    XCTAssertEqual(state.minimumChargingPoints, .twenty)
  }

  private func makeDestination(name: String) throws -> SavedDestination {
    try SavedDestination(
      displayName: name,
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
  }
}
