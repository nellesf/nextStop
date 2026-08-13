import XCTest

@testable import NextStopCore

final class AvailabilityTests: XCTestCase {
  func testAvailabilityFilterIsNotRequiredForAny() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 0,
      knownUnavailableCount: 0,
      unknownCount: 8,
      totalCount: 8
    )

    XCTAssertEqual(availability.evaluate(minimum: nil), .notRequired)
  }

  func testKnownAvailableCountSatisfiesMinimum() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 4,
      knownUnavailableCount: 4,
      unknownCount: 0,
      totalCount: 8
    )

    XCTAssertEqual(
      availability.evaluate(minimum: .four),
      .satisfiedByKnownAvailability
    )
  }

  func testUnknownAvailabilityPassesWithUncertainty() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 0,
      knownUnavailableCount: 0,
      unknownCount: 8,
      totalCount: 8
    )

    XCTAssertEqual(
      availability.evaluate(minimum: .four),
      .satisfiedWithUncertainty
    )
  }

  func testPartialAvailabilityPassesWhenUnknownPointsCouldSatisfyMinimum() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 2,
      knownUnavailableCount: 3,
      unknownCount: 3,
      totalCount: 8
    )

    XCTAssertEqual(
      availability.evaluate(minimum: .four),
      .satisfiedWithUncertainty
    )
  }

  func testPartialAvailabilityFailsOnlyWhenRequirementIsImpossible() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 1,
      knownUnavailableCount: 5,
      unknownCount: 2,
      totalCount: 8
    )

    XCTAssertEqual(availability.evaluate(minimum: .four), .impossible)
  }

  func testInvalidAvailabilityTotalIsRejected() {
    XCTAssertThrowsError(
      try ParkAvailability(
        knownAvailableCount: 2,
        knownUnavailableCount: 2,
        unknownCount: 2,
        totalCount: 8
      )
    ) { error in
      XCTAssertEqual(
        error as? DomainValidationError,
        .availabilityTotalMismatch(expected: 8, actual: 6)
      )
    }
  }
}
