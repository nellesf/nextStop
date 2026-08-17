import MapKit
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class MapKitFoodPOISearchServiceTests: XCTestCase {
  func testSearchRequestRequiresPointOfInterestResultsInsideConfiguredRegion() throws {
    let parkCoordinate = try Coordinate(latitude: 50.598132, longitude: 8.822718)

    let request = MapKitFoodPOISearchService.makeRequest(
      chain: .mcdonalds,
      near: parkCoordinate
    )

    XCTAssertEqual(request.naturalLanguageQuery, "McDonald's")
    XCTAssertEqual(request.resultTypes, .pointOfInterest)
    XCTAssertEqual(request.regionPriority, .required)
    XCTAssertEqual(request.region.center.latitude, parkCoordinate.latitude, accuracy: 0.000_001)
    XCTAssertEqual(request.region.center.longitude, parkCoordinate.longitude, accuracy: 0.000_001)
  }
}
