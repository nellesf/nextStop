import Foundation
import XCTest

@testable import NextStopCore

final class DomainValuesTests: XCTestCase {
  func testNegativeMetersAreRejectedDuringDecoding() {
    XCTAssertThrowsError(try JSONDecoder().decode(Meters.self, from: Data("-1".utf8)))
  }

  func testNonPositivePowerIsRejectedDuringDecoding() {
    XCTAssertThrowsError(try JSONDecoder().decode(Kilowatts.self, from: Data("0".utf8)))
  }

  func testInvalidCoordinateIsRejected() {
    XCTAssertThrowsError(try Coordinate(latitude: 91, longitude: 10))
    XCTAssertThrowsError(try Coordinate(latitude: 50, longitude: 181))
    XCTAssertThrowsError(try Coordinate(latitude: .nan, longitude: 10))
  }
}
