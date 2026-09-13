import XCTest

/// Exercises the real SwiftUI screens against a simulator-only, synthetic report service.
/// No test sends a report, route, or location to the live backend.
final class UserErrorReportUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testEmptyLogsExplainNextStepWithoutOfferingAnUnavailableCheckbox() {
    let app = launch(scenario: "empty")
    defer { app.terminate() }
    openReport(in: app)

    let noLogs = element("error-report-no-logs", in: app)
    reveal(noLogs, in: app)
    XCTAssertFalse(element("error-report-include-logs", in: app).exists)
    XCTAssertFalse(element("report-log-preview", in: app).exists)
    screenshot(app, named: "light-empty-logs")

    tap("error-report-recording-settings", in: app)
    let recording = app.switches["diagnostics-recording"]
    reveal(recording, in: app)
    XCTAssertEqual(recording.value as? String, "0", "Opening settings must not enable recording.")
    recording.tap()
    XCTAssertEqual(recording.value as? String, "1")
    let savedCount = element("diagnostics-saved-count", in: app)
    reveal(savedCount, in: app, direction: .down)
    XCTAssertEqual(savedCount.label, "0", "Enabling recording must not invent past error events.")
    screenshot(app, named: "light-local-recording-enabled-without-past-logs")

    goBack(in: app)
    reveal(noLogs, in: app)
    XCTAssertFalse(element("error-report-include-logs", in: app).exists)
    screenshot(app, named: "light-recording-awaiting-a-new-error")

    enterMessage("Synthetischer UI-Test: Bericht ohne technische Logs.", in: app)
    // Reviewing privacy also ends text editing, just as it does in the real report flow.
    openPrivacyAndReturn(in: app, screenshotName: "light-report-privacy")
    tap("error-report-send", in: app)
    XCTAssertTrue(element("report-send-success", in: app).waitForExistence(timeout: 10))
    screenshot(app, named: "light-report-without-logs-sent")
  }

  @MainActor
  func testOptionalLogsPreviewFailedSendRetryAndWithdrawal() {
    let app = launch(scenario: "logs-retry")
    defer { app.terminate() }
    openReport(in: app)

    let includeLogs = element("error-report-include-logs", in: app)
    reveal(includeLogs, in: app)
    XCTAssertTrue(includeLogs.isEnabled)
    XCTAssertEqual(includeLogs.value as? String, "Nicht ausgewählt")
    includeLogs.tap()
    XCTAssertEqual(includeLogs.value as? String, "Ausgewählt")
    screenshot(app, named: "light-optional-logs-selected")

    tap("report-log-preview", in: app)
    let preview = element("log-preview-content", in: app)
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
    XCTAssertTrue(preview.label.contains("candidateSearch"))
    XCTAssertTrue(preview.label.contains("offline"))
    XCTAssertFalse(preview.label.contains("latitude"))
    XCTAssertFalse(preview.label.contains("longitude"))
    screenshot(app, named: "light-synthetic-log-preview")
    goBack(in: app)

    let message = "Synthetischer UI-Test: Beim ersten Versuch trat ein Verbindungsfehler auf."
    enterMessage(message, in: app)
    openPrivacyAndReturn(in: app, screenshotName: "light-consent-before-sending")
    tap("error-report-send", in: app)
    let sendError = element("report-send-error", in: app)
    XCTAssertTrue(sendError.waitForExistence(timeout: 10))
    screenshot(app, named: "light-failed-send-can-be-retried")
    reveal(includeLogs, in: app, direction: .down)
    XCTAssertEqual(includeLogs.value as? String, "Ausgewählt")
    let input = element("error-report-message", in: app)
    reveal(input, in: app, direction: .down)
    XCTAssertEqual(input.value as? String, message)

    tap("error-report-send", in: app)
    XCTAssertTrue(element("report-send-success", in: app).waitForExistence(timeout: 10))
    XCTAssertFalse(sendError.exists)
    XCTAssertFalse(element("error-report-send", in: app).isEnabled)
    screenshot(app, named: "light-retry-succeeded")
    reveal(includeLogs, in: app, direction: .down)
    XCTAssertEqual(includeLogs.value as? String, "Nicht ausgewählt")
    reveal(input, in: app, direction: .down)
    XCTAssertNotEqual(input.value as? String, message)

    tap("report-receipts", in: app)
    let delete = element("error-report-delete", in: app)
    reveal(delete, in: app)
    XCTAssertEqual(app.buttons.matching(identifier: "error-report-delete").count, 1)
    screenshot(app, named: "light-delivered-report-withdrawal")
    delete.tap()
    XCTAssertTrue(element("receipts-empty", in: app).waitForExistence(timeout: 10))
    XCTAssertFalse(delete.exists)
    screenshot(app, named: "light-report-deleted")
  }

  @MainActor
  func testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable() {
    let app = launch(scenario: "logs-success", largeTextAndDarkMode: true)
    defer { app.terminate() }
    screenshot(app, named: "dark-accessibility-profile-list")
    openReport(in: app)
    screenshot(app, named: "dark-accessibility-report-introduction")

    let includeLogs = element("error-report-include-logs", in: app)
    reveal(includeLogs, in: app)
    XCTAssertTrue(includeLogs.isEnabled)
    XCTAssertEqual(includeLogs.value as? String, "Nicht ausgewählt")
    includeLogs.tap()
    XCTAssertEqual(includeLogs.value as? String, "Ausgewählt")
    screenshot(app, named: "dark-accessibility-log-checkbox")

    tap("report-log-preview", in: app)
    XCTAssertTrue(element("log-preview-content", in: app).waitForExistence(timeout: 5))
    screenshot(app, named: "dark-accessibility-log-preview")
    goBack(in: app)

    tap("report-privacy", in: app)
    reveal(element("report-privacy-content", in: app), in: app)
    screenshot(app, named: "dark-accessibility-privacy")
    goBack(in: app)

    let send = element("error-report-send", in: app)
    reveal(send, in: app)
    XCTAssertFalse(send.isEnabled, "A blank report must remain unsendable at every text size.")
    screenshot(app, named: "dark-accessibility-consent-and-send")
    tap("report-receipts", in: app)
    XCTAssertTrue(element("receipts-empty", in: app).waitForExistence(timeout: 5))
    screenshot(app, named: "dark-accessibility-empty-receipts")
    goBack(in: app)

    tap("report-local-diagnostics", in: app)
    let recording = app.switches["diagnostics-recording"]
    reveal(recording, in: app)
    XCTAssertEqual(recording.value as? String, "1")
    recording.tap()
    XCTAssertEqual(recording.value as? String, "0")
    goBack(in: app)
    reveal(element("error-report-no-logs", in: app), in: app, direction: .down)
    XCTAssertFalse(includeLogs.exists, "Deleting local logs must remove the previous attachment choice.")
    XCTAssertFalse(element("report-log-preview", in: app).exists)
    screenshot(app, named: "dark-accessibility-recording-disabled-clears-attachment")
  }

  @MainActor
  private func launch(scenario: String, largeTextAndDarkMode: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing",
      "-AppleLanguages", "(de)",
      "-AppleLocale", "de_DE",
      "-AppleInterfaceStyle", largeTextAndDarkMode ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      largeTextAndDarkMode
        ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
    ]
    app.launchEnvironment["NEXTSTOP_UI_TEST_SCENARIO"] = scenario
    app.launch()
    XCTAssertTrue(element("app-info", in: app).waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func openReport(in app: XCUIApplication) {
    tap("app-info", in: app)
    tap("info-error-report", in: app)
    XCTAssertTrue(app.navigationBars["Fehler melden"].waitForExistence(timeout: 5))
    reveal(element("error-report-message", in: app), in: app)
  }

  @MainActor
  private func enterMessage(_ text: String, in app: XCUIApplication) {
    let input = element("error-report-message", in: app)
    reveal(input, in: app, direction: .down)
    input.tap()
    input.typeText(text)
    XCTAssertEqual(input.value as? String, text)
  }

  @MainActor
  private func openPrivacyAndReturn(in app: XCUIApplication, screenshotName: String) {
    tap("report-privacy", in: app)
    reveal(element("report-privacy-content", in: app), in: app)
    screenshot(app, named: screenshotName)
    goBack(in: app)
  }

  @MainActor
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @MainActor
  private func tap(_ identifier: String, in app: XCUIApplication) {
    let target = element(identifier, in: app)
    reveal(target, in: app)
    XCTAssertTrue(target.isEnabled, "Control is disabled: \(identifier)")
    target.tap()
  }

  private enum ScrollDirection { case up, down }

  @MainActor
  private func reveal(
    _ target: XCUIElement, in app: XCUIApplication, direction: ScrollDirection = .up,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for _ in 0..<16 {
      if target.exists && target.isHittable { return }
      let frame = app.frame
      let keyboard = app.keyboards.firstMatch
      let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
      // Swipe along the trailing edge, outside the message editor and above the keyboard.
      let high = frame.minY + 150
      let low = max(high + 50, bottom - 90)
      let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(dx: frame.width - 24, dy: direction == .up ? low : high))
      let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(dx: frame.width - 24, dy: direction == .up ? high : low))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    screenshot(app, named: "unreachable-\(target.identifier)")
    XCTFail("Control was not reachable after scrolling: \(target.identifier)", file: file, line: line)
  }

  @MainActor
  private func goBack(in app: XCUIApplication) {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
  }

  @MainActor
  private func screenshot(_ app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
