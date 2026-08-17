import XCTest

@testable import NextStopCore

final class SearchConfigurationTests: XCTestCase {
  func testAllowedOptionsMatchProductSpecification() {
    XCTAssertEqual(
      DistanceRangeOption.allCases.map(\.range),
      [
        Meters(15_000)...Meters(50_000),
        Meters(50_000)...Meters(100_000),
        Meters(100_000)...Meters(150_000),
      ]
    )
    XCTAssertEqual(
      MinimumChargingPointsOption.allCases.map(\.rawValue),
      [2, 4, 6, 8, 10, 12, 16, 20]
    )
    XCTAssertEqual(
      MinimumPowerOption.allCases.map(\.rawValue),
      [11, 22, 50, 100, 150, 200, 250, 300, 350, 400]
    )
    XCTAssertEqual(
      FoodChain.allCases,
      [.mcdonalds, .burgerKing, .kfc, .subway]
    )
  }

  func testFixedThresholdsAndLimits() {
    XCTAssertEqual(SearchConfiguration.maximumDistanceFromRoute, Meters(5_000))
    XCTAssertEqual(SearchConfiguration.maximumChargingParkClusterDistance, Meters(200))
    XCTAssertEqual(SearchConfiguration.maximumFoodDistance, Meters(500))
    XCTAssertEqual(SearchConfiguration.maximumResultCount, 5)
    XCTAssertEqual(SearchConfiguration.recentDestinationLimit, 20)
  }

  func testApprovedNonProfileDefaults() {
    let defaults = SearchConfiguration.defaultCriteria

    XCTAssertEqual(defaults.distanceRange, .kilometers50To100)
    XCTAssertEqual(defaults.minimumChargingPoints, .four)
    XCTAssertEqual(defaults.minimumPower, .oneHundred)
    XCTAssertNil(defaults.foodChain)
  }
}
