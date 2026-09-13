#if DEBUG && targetEnvironment(simulator)
  import Foundation
  import SwiftData
  import XCTest

  @testable import NextStopApp

  @MainActor
  final class UITestSupportTests: XCTestCase {
    func testLaunchRequiresExactArgumentAndRejectsUnknownScenarios() throws {
      XCTAssertNil(
        try UITestSupport.requested(
          arguments: ["nextStop"], environment: ["NEXTSTOP_UI_TEST_SCENARIO": "logs-success"]
        )
      )
      XCTAssertFalse(UITestSupport.isRequested(arguments: ["--ui-testing=true"]))
      XCTAssertThrowsError(
        try UITestSupport.requested(arguments: ["--ui-testing"], environment: [:])
      )
      XCTAssertThrowsError(
        try UITestSupport.requested(
          arguments: ["--ui-testing"], environment: ["NEXTSTOP_UI_TEST_SCENARIO": "unknown"]
        )
      )
    }

    func testFixturesKeepProfilesInMemoryAndIsolateLogConsentAndReceipts() async throws {
      let empty = try UITestSupport(scenario: .empty)
      let logs = try UITestSupport(scenario: .logsSuccess)
      XCTAssertTrue(empty.modelContainer.configurations.allSatisfy(\.isStoredInMemoryOnly))
      XCTAssertTrue(logs.modelContainer.configurations.allSatisfy(\.isStoredInMemoryOnly))
      XCTAssertEqual(try empty.modelContainer.mainContext.fetchCount(FetchDescriptor<StoredProfile>()), 0)
      XCTAssertFalse(empty.diagnostics.recordingEnabled)
      XCTAssertTrue(empty.diagnostics.events.isEmpty)
      XCTAssertTrue(logs.diagnostics.recordingEnabled)
      XCTAssertEqual(logs.diagnostics.events.count, 1)
      XCTAssertEqual(logs.diagnostics.events.first?.category, .offline)

      let request = try UserErrorReportRequest(message: "Synthetic report.", includeDiagnostics: false)
      let receipt = try await logs.reportSender.send(request)
      XCTAssertEqual(logs.receipts.receipts, [receipt])
      XCTAssertFalse(receipt.isPending)
      XCTAssertTrue(empty.receipts.receipts.isEmpty)
      try await logs.reportSender.delete(receipt)
      XCTAssertTrue(logs.receipts.receipts.isEmpty)
    }

    func testAppearanceOverrideIsExplicitAndRejectsUnknownValues() throws {
      let baseEnvironment = ["NEXTSTOP_UI_TEST_SCENARIO": "empty"]
      let inherited = try XCTUnwrap(
        UITestSupport.requested(arguments: ["--ui-testing"], environment: baseEnvironment)
      )
      XCTAssertNil(inherited.preferredColorScheme)
      for appearance in [UITestSupport.Appearance.light, .dark] {
        var environment = baseEnvironment
        environment["NEXTSTOP_UI_TEST_APPEARANCE"] = appearance.rawValue
        let support = try XCTUnwrap(
          UITestSupport.requested(arguments: ["--ui-testing"], environment: environment)
        )
        XCTAssertEqual(support.preferredColorScheme, appearance.colorScheme)
      }
      var invalidEnvironment = baseEnvironment
      invalidEnvironment["NEXTSTOP_UI_TEST_APPEARANCE"] = "unexpected"
      XCTAssertThrowsError(
        try UITestSupport.requested(arguments: ["--ui-testing"], environment: invalidEnvironment)
      )
      XCTAssertNil(
        try UITestSupport.requested(arguments: [], environment: invalidEnvironment)
      )
    }

    func testRetryScenarioLeavesDeletionReceiptAndConfirmsSameDraft() async throws {
      let support = try UITestSupport(scenario: .logsRetry)
      let composer = UserErrorReportComposer(sender: support.reportSender, privacyConfigured: true)
      composer.refreshDiagnostics(from: support.diagnostics)
      composer.message = "Synthetic retry report."
      composer.includeDiagnostics = true
      await composer.send()
      XCTAssertEqual(composer.error, .unavailable)
      let pending = try XCTUnwrap(support.receipts.receipts.first)
      XCTAssertTrue(pending.isPending)
      XCTAssertEqual(composer.message, "Synthetic retry report.")
      XCTAssertTrue(composer.includeDiagnostics)

      await composer.send()
      let delivered = try XCTUnwrap(support.receipts.receipts.first)
      XCTAssertEqual(delivered.reportID, pending.reportID)
      XCTAssertEqual(delivered.deletionToken, pending.deletionToken)
      XCTAssertFalse(delivered.isPending)
      XCTAssertEqual(support.receipts.receipts.count, 1)
      XCTAssertEqual(composer.sentReportID, delivered.reportID)
      XCTAssertNil(composer.error)
      XCTAssertEqual(composer.message, "")
      XCTAssertFalse(composer.includeDiagnostics)
      XCTAssertTrue(support.diagnostics.recordingEnabled)
    }
  }
#endif
