import Foundation
import XCTest

@testable import NextStopCore

final class ProfileDraftTests: XCTestCase {
  func testProfileCreatesIndependentRideScopedDraft() throws {
    let destination = try SavedDestination(
      displayName: "Mönchengladbach",
      coordinate: Coordinate(latitude: 51.1805, longitude: 6.4428)
    )
    let profileCriteria = RideCriteria(
      distanceRange: .kilometers100To150,
      minimumChargingPoints: .eight,
      minimumAvailablePoints: .four,
      minimumPower: .oneHundredFifty,
      foodChain: .mcdonalds
    )
    let profile = try UserProfile(
      name: "München → Mönchengladbach",
      destination: destination,
      criteria: profileCriteria,
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )

    var draft = RideSearchDraft(profile: profile)
    draft.criteria.minimumPower = .fifty
    draft.criteria.foodChain = nil

    XCTAssertEqual(profile.criteria.minimumPower, .oneHundredFifty)
    XCTAssertEqual(profile.criteria.foodChain, .mcdonalds)
    XCTAssertEqual(draft.sourceProfileID, profile.id)
  }

  func testDestinationWithoutProfileUsesApprovedDefaults() throws {
    let destination = try SavedDestination(
      displayName: "Hamburg",
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )

    let draft = RideSearchDraft(destination: destination)

    XCTAssertEqual(draft.criteria, SearchConfiguration.defaultCriteria)
    XCTAssertNil(draft.sourceProfileID)
  }
}
