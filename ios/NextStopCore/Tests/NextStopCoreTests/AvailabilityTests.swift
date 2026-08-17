import XCTest

@testable import NextStopCore

final class AvailabilityTests: XCTestCase {
  func testCompletenessRemainsInformational() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 4,
      knownUnavailableCount: 4,
      unknownCount: 0,
      totalCount: 8
    )

    XCTAssertTrue(availability.isComplete)
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
