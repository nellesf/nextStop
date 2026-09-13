import Foundation
import XCTest

@testable import NextStopApp

@MainActor
final class ReportComposerTests: XCTestCase {
  func testMissingPrivacyContactPreventsSubmission() async {
    let sender = ReportComposerSender()
    let composer = UserErrorReportComposer(sender: sender, privacyConfigured: false)
    composer.message = "Search did not finish."
    XCTAssertFalse(composer.canSend)
    await composer.send()
    XCTAssertTrue(sender.requests.isEmpty)
    XCTAssertFalse(
      SupportPrivacyConfiguration(
        controllerName: "", postalAddress: "", email: ""
      ).isComplete)
  }

  func testLogsDefaultOffAndSuccessResetsPerReportSelection() async throws {
    let sender = ReportComposerSender()
    let composer = UserErrorReportComposer(sender: sender, privacyConfigured: true)
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    composer.refreshDiagnostics(from: fixture.store)
    XCTAssertFalse(composer.includeDiagnostics)
    composer.message = "The search failed."
    await composer.send()
    XCTAssertNil(sender.requests.first?.diagnostics)
    XCTAssertEqual(composer.message, "")
    XCTAssertNotNil(composer.sentReportID)

    composer.message = "It failed a second time."
    composer.includeDiagnostics = true
    await composer.send()
    XCTAssertEqual(sender.requests.last?.diagnostics, fixture.store.events)
    XCTAssertFalse(composer.includeDiagnostics)
    XCTAssertTrue(fixture.store.recordingEnabled)
  }

  func testUnchangedExplicitRetryUsesSameReportAndChangedInputGetsNewReference() async {
    let sender = ReportComposerSender()
    sender.failure = .unavailable
    let composer = UserErrorReportComposer(sender: sender, privacyConfigured: true)
    composer.message = "Search stopped."
    await composer.send()
    XCTAssertEqual(composer.error, .unavailable)
    XCTAssertEqual(composer.message, "Search stopped.")
    await composer.send()
    XCTAssertEqual(sender.requests[0], sender.requests[1])
    composer.message = "Search stopped after a retry."
    await composer.send()
    XCTAssertNotEqual(sender.requests[1].reportID, sender.requests[2].reportID)
  }

  func testUncheckingLogsRemovesThemFromPreviouslyFailedSubmission() async throws {
    let sender = ReportComposerSender()
    sender.failure = .unavailable
    let composer = UserErrorReportComposer(sender: sender, privacyConfigured: true)
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    composer.refreshDiagnostics(from: fixture.store)
    composer.message = "An error occurred."
    composer.includeDiagnostics = true
    await composer.send()
    composer.includeDiagnostics = false
    await composer.send()
    XCTAssertNotNil(sender.requests[0].diagnostics)
    XCTAssertNil(sender.requests[1].diagnostics)
    XCTAssertNotEqual(sender.requests[0].reportID, sender.requests[1].reportID)
  }

  func testDeletedLocalLogsCannotRemainSelectedOnReturningToForm() async throws {
    let sender = ReportComposerSender()
    let composer = UserErrorReportComposer(sender: sender, privacyConfigured: true)
    let fixture = try DiagnosticFixture()
    defer { fixture.remove() }
    composer.refreshDiagnostics(from: fixture.store)
    composer.includeDiagnostics = true
    fixture.store.recordingEnabled = false
    composer.refreshDiagnostics(from: fixture.store)
    XCTAssertTrue(composer.diagnostics.isEmpty)
    XCTAssertFalse(composer.includeDiagnostics)
    XCTAssertFalse(fixture.store.recordingEnabled)
  }

  func testEmptyOrOversizedInputDoesNotSendAndWithdrawnRetryGetsNewReference() async {
    let sender = ReportComposerSender()
    let composer = UserErrorReportComposer(sender: sender, privacyConfigured: true)
    for message in [" \n ", String(repeating: "x", count: 5_001)] {
      composer.message = message
      await composer.send()
    }
    XCTAssertTrue(sender.requests.isEmpty)
    composer.message = "The report was withdrawn."
    sender.failure = .withdrawn
    await composer.send()
    sender.failure = nil
    await composer.send()
    XCTAssertNotEqual(sender.requests[0].reportID, sender.requests[1].reportID)
  }
}

@MainActor
private final class ReportComposerSender: UserErrorReportSending {
  var requests: [UserErrorReportRequest] = []
  var failure: UserErrorReportError?

  func send(_ request: UserErrorReportRequest) async throws -> UserErrorReportReceipt {
    requests.append(request)
    if let failure { throw failure }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    return UserErrorReportReceipt(
      reportID: request.reportID, deletionToken: request.deletionToken,
      createdAt: now, receivedAt: now,
      expiresAt: now.addingTimeInterval(UserErrorReportReceiptStore.retentionInterval)
    )
  }

  func delete(_ receipt: UserErrorReportReceipt) async throws {}
}

@MainActor
private struct DiagnosticFixture {
  let directory: URL
  let store: AppDiagnosticsStore

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReportComposerTests-\(UUID().uuidString)", isDirectory: true)
    // Use an exactly representable instant: the event normalizes through Unix time.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    store = AppDiagnosticsStore(
      fileURL: directory.appendingPathComponent("events.json"), clock: { now }
    )
    store.recordingEnabled = true
    store.record(
      AppDiagnosticEvent(
        timestamp: now, operation: .candidateSearch, outcome: .failure,
        category: .networkTimeout, durationMilliseconds: 500
      ))
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
