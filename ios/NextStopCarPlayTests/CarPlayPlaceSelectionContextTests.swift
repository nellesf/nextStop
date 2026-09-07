import CarPlay
import Foundation
import MapKit
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayPlaceSelectionContextTests: XCTestCase {
  func testSelectingAnotherPOIInvalidatesThePendingRestaurantWithinTheSameTemplate() {
    let firstID = UUID()
    let secondID = UUID()
    let template = CPPointOfInterestTemplate(
      title: "Ladestopps",
      pointsOfInterest: [makePoint(id: firstID), makePoint(id: secondID)],
      selectedIndex: 0
    )

    XCTAssertTrue(
      CarPlayPlaceSelectionContext.isCurrent(resultID: firstID, source: template, visible: template)
    )
    template.selectedIndex = 1
    XCTAssertFalse(
      CarPlayPlaceSelectionContext.isCurrent(resultID: firstID, source: template, visible: template)
    )
    XCTAssertTrue(
      CarPlayPlaceSelectionContext.isCurrent(
        resultID: secondID, source: template, visible: template)
    )
  }

  func testClearingPOISelectionPreventsOpeningItsOldPlace() {
    let id = UUID()
    let template = CPPointOfInterestTemplate(
      title: "Ladestopps", pointsOfInterest: [makePoint(id: id)], selectedIndex: 0
    )

    template.selectedIndex = NSNotFound

    XCTAssertFalse(
      CarPlayPlaceSelectionContext.isCurrent(resultID: id, source: template, visible: template)
    )
  }

  func testOperatorListOnlyRemainsCurrentWhileThatExactTemplateIsVisible() {
    let id = UUID()
    let original = CPListTemplate(title: "Ladeanbieter", sections: [])
    let replacement = CPListTemplate(title: "Ladeanbieter", sections: [])

    XCTAssertTrue(
      CarPlayPlaceSelectionContext.isCurrent(resultID: id, source: original, visible: original)
    )
    XCTAssertFalse(
      CarPlayPlaceSelectionContext.isCurrent(resultID: id, source: original, visible: replacement)
    )
    XCTAssertFalse(
      CarPlayPlaceSelectionContext.isCurrent(resultID: id, source: original, visible: nil)
    )
  }

  func testReturningToSummaryInvalidatesThePendingRestaurant() {
    let id = UUID()
    let results = CPPointOfInterestTemplate(
      title: "Ladestopps", pointsOfInterest: [makePoint(id: id)], selectedIndex: 0
    )
    let summary = CPListTemplate(title: "Fahrt", sections: [])

    XCTAssertFalse(
      CarPlayPlaceSelectionContext.isCurrent(resultID: id, source: results, visible: summary)
    )
  }

  private func makePoint(id: UUID) -> CPPointOfInterest {
    let point = CPPointOfInterest(
      location: MKMapItem(),
      title: "Restaurant",
      subtitle: nil,
      summary: nil,
      detailTitle: nil,
      detailSubtitle: nil,
      detailSummary: nil,
      pinImage: nil
    )
    point.userInfo = id as NSUUID
    return point
  }
}
