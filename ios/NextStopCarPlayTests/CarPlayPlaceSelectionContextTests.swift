import CarPlay
import Foundation
import MapKit
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayPlaceSelectionContextTests: XCTestCase {
  func testResultWithoutRestaurantOpensItsOperatorsWithoutAReportedSelectedIndex() throws {
    let id = UUID()
    let point = makePoint(id: id, includesRestaurant: false)
    let results = makeTemplate(points: [point])
    let context = CarPlayPlaceSelectionContext()

    let selection = try XCTUnwrap(
      context.selectResult(point, in: results, visible: results)
    )

    XCTAssertEqual(results.selectedIndex, NSNotFound)
    XCTAssertEqual(selection.action, .showOperators(id))
    XCTAssertTrue(selection.cancelsPendingPlace)
    XCTAssertTrue(context.isCurrent(resultID: id, source: results, visible: results))
  }

  func testRestaurantResultKeepsDestinationChoiceAndCancelsOnlyChangedSelection() throws {
    let firstID = UUID()
    let first = makePoint(id: firstID)
    let second = makePoint(id: UUID())
    let results = makeTemplate(points: [first, second])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertTrue(context.select(first, in: results, visible: results))

    let repeated = try XCTUnwrap(
      context.selectResult(first, in: results, visible: results)
    )
    XCTAssertEqual(repeated.action, .showDestinationChoice)
    XCTAssertFalse(repeated.cancelsPendingPlace)

    let changed = try XCTUnwrap(
      context.selectResult(second, in: results, visible: results)
    )
    XCTAssertEqual(changed.action, .showDestinationChoice)
    XCTAssertTrue(changed.cancelsPendingPlace)
    XCTAssertFalse(context.isCurrent(resultID: firstID, source: results, visible: results))
  }

  func testDelayedNoRestaurantSelectionCannotReplaceNewerRestaurantAction() throws {
    let first = makePoint(id: UUID(), includesRestaurant: false)
    let secondID = UUID()
    let second = makePoint(id: secondID)
    let results = makeTemplate(points: [first, second])
    let context = CarPlayPlaceSelectionContext()
    let callbackTime = ContinuousClock.now
    let actionTime = callbackTime.advanced(by: .seconds(1))
    XCTAssertEqual(
      context.selectAction(
        try XCTUnwrap(second.secondaryButton), in: results, visible: results,
        observedAt: actionTime),
      secondID
    )

    XCTAssertNil(
      context.selectResult(first, in: results, visible: results, observedAt: callbackTime)
    )
    XCTAssertTrue(context.isCurrent(resultID: secondID, source: results, visible: results))
  }

  func testDirectSelectionRejectsReplacedTemplateAndPointEvenWithSameResultID() {
    let id = UUID()
    let originalPoint = makePoint(id: id, includesRestaurant: false)
    let original = makeTemplate(points: [originalPoint])
    let replacementPoint = makePoint(id: id, includesRestaurant: false)
    let replacement = makeTemplate(points: [replacementPoint])
    let context = CarPlayPlaceSelectionContext()

    XCTAssertNil(
      context.selectResult(originalPoint, in: original, visible: replacement)
    )
    XCTAssertNil(
      context.selectResult(originalPoint, in: replacement, visible: replacement)
    )
    XCTAssertEqual(
      context.selectResult(replacementPoint, in: replacement, visible: replacement)?.action,
      .showOperators(id)
    )
  }

  func testSuccessfulDirectPushReturnsToOverviewAndRejectsQueuedSelectionAfterBack() {
    let id = UUID()
    let point = makePoint(id: id, includesRestaurant: false)
    let results = makeTemplate(points: [point])
    results.selectedIndex = 0
    let operators = CPListTemplate(title: "Ladeanbieter", sections: [])
    let context = CarPlayPlaceSelectionContext()
    let selectionTime = ContinuousClock.now
    let completionTime = selectionTime.advanced(by: .seconds(1))
    XCTAssertEqual(
      context.selectResult(point, in: results, visible: results, observedAt: selectionTime)?.action,
      .showOperators(id)
    )

    XCTAssertTrue(
      context.completeDirectOperatorPush(
        resultID: id, from: results, to: operators, visible: operators,
        observedAt: completionTime)
    )
    XCTAssertEqual(results.selectedIndex, NSNotFound)
    XCTAssertFalse(context.isCurrent(resultID: id, source: results, visible: results))
    XCTAssertTrue(context.isCurrent(resultID: id, source: operators, visible: operators))
    XCTAssertNil(
      context.selectResult(point, in: results, visible: results, observedAt: selectionTime)
    )
    XCTAssertEqual(
      context.selectResult(
        point, in: results, visible: results,
        observedAt: completionTime.advanced(by: .seconds(1)))?.action,
      .showOperators(id)
    )
  }

  func testFailedDirectPushKeepsSelectionAndFallbackOperatorActionAvailable() throws {
    let id = UUID()
    let point = makePoint(id: id, includesRestaurant: false)
    let results = makeTemplate(points: [point])
    results.selectedIndex = 0
    let operators = CPListTemplate(title: "Ladeanbieter", sections: [])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertNotNil(context.selectResult(point, in: results, visible: results))

    XCTAssertFalse(
      context.completeDirectOperatorPush(
        resultID: id, from: results, to: operators, visible: results)
    )
    XCTAssertEqual(results.selectedIndex, 0)
    XCTAssertTrue(context.isCurrent(resultID: id, source: results, visible: results))
    XCTAssertEqual(
      context.selectAction(try XCTUnwrap(point.primaryButton), in: results, visible: results),
      id
    )
  }

  func testStalePushCompletionCannotClearTheReplacementSelection() {
    let id = UUID()
    let originalPoint = makePoint(id: id, includesRestaurant: false)
    let original = makeTemplate(points: [originalPoint])
    original.selectedIndex = 0
    let replacementPoint = makePoint(id: id, includesRestaurant: false)
    let replacement = makeTemplate(points: [replacementPoint])
    replacement.selectedIndex = 0
    let operators = CPListTemplate(title: "Ladeanbieter", sections: [])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertNotNil(context.selectResult(originalPoint, in: original, visible: original))
    XCTAssertNotNil(context.selectResult(replacementPoint, in: replacement, visible: replacement))

    XCTAssertFalse(
      context.completeDirectOperatorPush(
        resultID: id, from: original, to: operators, visible: operators)
    )
    XCTAssertEqual(original.selectedIndex, 0)
    XCTAssertEqual(replacement.selectedIndex, 0)
    XCTAssertTrue(context.isCurrent(resultID: id, source: replacement, visible: replacement))
  }

  func testBothPOIActionsAcceptTheirOwnButtonWithNoReportedSelection() throws {
    let id = UUID()
    let point = makePoint(id: id)
    let template = makeTemplate(points: [point])
    let context = CarPlayPlaceSelectionContext()

    for button in [try XCTUnwrap(point.primaryButton), try XCTUnwrap(point.secondaryButton)] {
      context.clear()
      XCTAssertEqual(template.selectedIndex, NSNotFound)
      XCTAssertEqual(context.selectAction(button, in: template, visible: template), id)
      XCTAssertTrue(context.isCurrent(resultID: id, source: template, visible: template))
    }
  }

  func testButtonOwnershipTakesPrecedenceOverAnOutdatedSelectedIndex() throws {
    let first = makePoint(id: UUID())
    let secondID = UUID()
    let second = makePoint(id: secondID)
    let template = makeTemplate(points: [first, second])
    template.selectedIndex = 0
    let context = CarPlayPlaceSelectionContext()

    XCTAssertEqual(
      context.selectAction(
        try XCTUnwrap(second.primaryButton), in: template, visible: template),
      secondID
    )
    XCTAssertTrue(context.isCurrent(resultID: secondID, source: template, visible: template))
  }

  func testSelectingAnotherPOIInvalidatesThePendingRestaurantWithinTheSameTemplate() {
    let firstID = UUID()
    let secondID = UUID()
    let first = makePoint(id: firstID)
    let second = makePoint(id: secondID)
    let template = makeTemplate(points: [first, second])
    let context = CarPlayPlaceSelectionContext()

    XCTAssertTrue(context.select(first, in: template, visible: template))
    XCTAssertTrue(
      context.isCurrent(resultID: firstID, source: template, visible: template)
    )
    XCTAssertFalse(context.select(first, in: template, visible: template))
    XCTAssertTrue(context.select(second, in: template, visible: template))
    XCTAssertFalse(
      context.isCurrent(resultID: firstID, source: template, visible: template)
    )
    XCTAssertTrue(
      context.isCurrent(resultID: secondID, source: template, visible: template)
    )
    XCTAssertEqual(template.selectedIndex, NSNotFound)
  }

  func testOlderQueuedSelectionDoesNotCancelANewerButtonAction() throws {
    let first = makePoint(id: UUID())
    let secondID = UUID()
    let second = makePoint(id: secondID)
    let template = makeTemplate(points: [first, second])
    let context = CarPlayPlaceSelectionContext()
    let callbackTime = ContinuousClock.now
    let actionTime = callbackTime.advanced(by: .seconds(1))

    XCTAssertEqual(
      context.selectAction(
        try XCTUnwrap(second.secondaryButton), in: template, visible: template,
        observedAt: actionTime),
      secondID
    )
    XCTAssertFalse(
      context.select(first, in: template, visible: template, observedAt: callbackTime)
    )
    XCTAssertTrue(context.isCurrent(resultID: secondID, source: template, visible: template))
    XCTAssertTrue(
      context.select(
        first, in: template, visible: template, observedAt: actionTime.advanced(by: .seconds(1)))
    )
    XCTAssertFalse(context.isCurrent(resultID: secondID, source: template, visible: template))
  }

  func testOldButtonAndPointCannotActOnReplacementWithTheSameResultID() throws {
    let id = UUID()
    let originalPoint = makePoint(id: id)
    let original = makeTemplate(points: [originalPoint])
    let replacementPoint = makePoint(id: id)
    let replacement = makeTemplate(points: [replacementPoint])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertTrue(context.select(originalPoint, in: original, visible: original))

    XCTAssertNil(
      context.selectAction(
        try XCTUnwrap(originalPoint.primaryButton), in: original, visible: replacement)
    )
    XCTAssertNil(
      context.selectAction(
        try XCTUnwrap(originalPoint.primaryButton), in: replacement, visible: replacement)
    )
    XCTAssertFalse(context.select(originalPoint, in: replacement, visible: replacement))
    XCTAssertFalse(context.isCurrent(resultID: id, source: replacement, visible: replacement))
    XCTAssertEqual(
      context.selectAction(
        try XCTUnwrap(replacementPoint.primaryButton), in: replacement, visible: replacement),
      id
    )
  }

  func testClearingSelectionPreventsOpeningItsOldPlace() {
    let id = UUID()
    let point = makePoint(id: id)
    let template = makeTemplate(points: [point])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertTrue(context.select(point, in: template, visible: template))

    context.clear()

    XCTAssertFalse(
      context.isCurrent(resultID: id, source: template, visible: template)
    )
  }

  func testRemovedPointInvalidatesSelectionWithoutReusingItsID() {
    let id = UUID()
    let point = makePoint(id: id)
    let template = makeTemplate(points: [point])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertTrue(context.select(point, in: template, visible: template))

    template.setPointsOfInterest([makePoint(id: id)], selectedIndex: NSNotFound)

    XCTAssertFalse(context.isCurrent(resultID: id, source: template, visible: template))
  }

  func testOperatorListOnlyRemainsCurrentWhileThatExactTemplateIsVisible() {
    let id = UUID()
    let original = CPListTemplate(title: "Ladeanbieter", sections: [])
    let replacement = CPListTemplate(title: "Ladeanbieter", sections: [])
    let context = CarPlayPlaceSelectionContext()

    XCTAssertTrue(
      context.isCurrent(resultID: id, source: original, visible: original)
    )
    XCTAssertFalse(
      context.isCurrent(resultID: id, source: original, visible: replacement)
    )
    XCTAssertFalse(
      context.isCurrent(resultID: id, source: original, visible: nil)
    )
  }

  func testReturningToSummaryInvalidatesThePendingRestaurant() {
    let id = UUID()
    let point = makePoint(id: id)
    let results = makeTemplate(points: [point])
    let summary = CPListTemplate(title: "Fahrt", sections: [])
    let context = CarPlayPlaceSelectionContext()
    XCTAssertTrue(context.select(point, in: results, visible: results))

    XCTAssertFalse(
      context.isCurrent(resultID: id, source: results, visible: summary)
    )
  }

  private func makeTemplate(points: [CPPointOfInterest]) -> CPPointOfInterestTemplate {
    CPPointOfInterestTemplate(
      title: "Ladestopps", pointsOfInterest: points, selectedIndex: NSNotFound
    )
  }

  private func makePoint(id: UUID, includesRestaurant: Bool = true) -> CPPointOfInterest {
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
    point.primaryButton = CPTextButton(title: "Ladeanbieter", textStyle: .confirm) { _ in }
    if includesRestaurant {
      point.secondaryButton = CPTextButton(title: "Zum Restaurant", textStyle: .normal) { _ in }
    }
    return point
  }
}
