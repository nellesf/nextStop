import XCTest

/// Exercises the real SwiftUI screens against a simulator-only, synthetic report service.
/// No test sends a report, route, or location to the live backend.
final class UserErrorReportUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testEmptyLogsExplainNextStepWithoutOfferingAnUnavailableCheckbox() {
    let previousAppearance = XCUIDevice.shared.appearance
    let app = launch(scenario: "empty")
    defer {
      app.terminate()
      XCUIDevice.shared.appearance = previousAppearance
    }
    openReport(in: app)

    reveal("error-report-no-logs", in: app)
    XCTAssertFalse(element("error-report-include-logs", in: app).exists)
    XCTAssertFalse(element("report-log-preview", in: app).exists)
    screenshot(app, named: "light-empty-logs")

    tap("error-report-recording-settings", in: app)
    let recording = app.switches["diagnostics-recording"]
    reveal("diagnostics-recording", in: app)
    XCTAssertEqual(recording.value as? String, "0", "Opening settings must not enable recording.")
    recording.tap()
    XCTAssertEqual(recording.value as? String, "1")
    let savedCount = element("diagnostics-saved-count", in: app)
    reveal("diagnostics-saved-count", in: app, direction: .down)
    XCTAssertEqual(savedCount.label, "0", "Enabling recording must not invent past error events.")
    screenshot(app, named: "light-local-recording-enabled-without-past-logs")

    goBack(in: app)
    reveal("error-report-no-logs", in: app)
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
    let previousAppearance = XCUIDevice.shared.appearance
    let app = launch(scenario: "logs-retry")
    defer {
      app.terminate()
      XCUIDevice.shared.appearance = previousAppearance
    }
    openReport(in: app)

    let includeLogs = element("error-report-include-logs", in: app)
    reveal("error-report-include-logs", in: app)
    XCTAssertTrue(includeLogs.isEnabled)
    XCTAssertEqual(includeLogs.value as? String, "0")
    includeLogs.tap()
    XCTAssertEqual(includeLogs.value as? String, "1")
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
    reveal("error-report-include-logs", in: app, direction: .down)
    XCTAssertEqual(includeLogs.value as? String, "1")
    let input = element("error-report-message", in: app)
    reveal("error-report-message", in: app, direction: .down)
    XCTAssertEqual(input.value as? String, message)

    tap("error-report-send", in: app)
    XCTAssertTrue(element("report-send-success", in: app).waitForExistence(timeout: 10))
    XCTAssertFalse(sendError.exists)
    XCTAssertFalse(element("error-report-send", in: app).isEnabled)
    screenshot(app, named: "light-retry-succeeded")
    reveal("error-report-include-logs", in: app, direction: .down)
    XCTAssertEqual(includeLogs.value as? String, "0")
    reveal("error-report-message", in: app, direction: .down)
    XCTAssertNotEqual(input.value as? String, message)

    tap("report-receipts", in: app)
    let delete = element("error-report-delete", in: app)
    reveal("error-report-delete", in: app)
    XCTAssertEqual(app.buttons.matching(identifier: "error-report-delete").count, 1)
    screenshot(app, named: "light-delivered-report-withdrawal")
    delete.tap()
    XCTAssertTrue(element("receipts-empty", in: app).waitForExistence(timeout: 10))
    XCTAssertFalse(delete.exists)
    screenshot(app, named: "light-report-deleted")
  }

  @MainActor
  func testDarkModeWithLargestAccessibilityTextKeepsReportControlsReachable() {
    let previousAppearance = XCUIDevice.shared.appearance
    let app = launch(scenario: "logs-success", largeTextAndDarkMode: true)
    defer {
      app.terminate()
      XCUIDevice.shared.appearance = previousAppearance
    }
    screenshot(app, named: "dark-accessibility-profile-list")
    openReport(in: app)
    screenshot(app, named: "dark-accessibility-report-introduction")

    let includeLogs = element("error-report-include-logs", in: app)
    reveal("error-report-include-logs", in: app)
    XCTAssertTrue(includeLogs.isEnabled)
    XCTAssertEqual(includeLogs.value as? String, "0")
    includeLogs.tap()
    XCTAssertEqual(includeLogs.value as? String, "1")
    screenshot(app, named: "dark-accessibility-log-checkbox")

    tap("report-log-preview", in: app)
    XCTAssertTrue(element("log-preview-content", in: app).waitForExistence(timeout: 5))
    screenshot(app, named: "dark-accessibility-log-preview")
    goBack(in: app)

    tap("report-privacy", in: app)
    reveal("report-privacy-content", in: app)
    screenshot(app, named: "dark-accessibility-privacy")
    goBack(in: app)

    let send = element("error-report-send", in: app)
    reveal("error-report-send", in: app)
    XCTAssertFalse(send.isEnabled, "A blank report must remain unsendable at every text size.")
    screenshot(app, named: "dark-accessibility-consent-and-send")
    tap("report-receipts", in: app)
    XCTAssertTrue(element("receipts-empty", in: app).waitForExistence(timeout: 5))
    screenshot(app, named: "dark-accessibility-empty-receipts")
    goBack(in: app)

    tap("report-local-diagnostics", in: app)
    let recording = app.switches["diagnostics-recording"]
    reveal("diagnostics-recording", in: app)
    XCTAssertEqual(recording.value as? String, "1")
    recording.tap()
    XCTAssertEqual(recording.value as? String, "0")
    goBack(in: app)
    reveal("error-report-no-logs", in: app, direction: .down)
    XCTAssertFalse(includeLogs.exists, "Deleting local logs must remove the previous attachment choice.")
    XCTAssertFalse(element("report-log-preview", in: app).exists)
    screenshot(app, named: "dark-accessibility-recording-disabled-clears-attachment")
  }

  @MainActor
  private func launch(scenario: String, largeTextAndDarkMode: Bool = false) -> XCUIApplication {
    XCUIDevice.shared.appearance = largeTextAndDarkMode ? .dark : .light
    XCTAssertEqual(XCUIDevice.shared.appearance, largeTextAndDarkMode ? .dark : .light)
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing",
      "-AppleLanguages", "(de)",
      "-AppleLocale", "de_DE",
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
    reveal("error-report-message", in: app)
  }

  @MainActor
  private func enterMessage(_ text: String, in app: XCUIApplication) {
    let input = element("error-report-message", in: app)
    reveal("error-report-message", in: app, direction: .down)
    input.tap()
    input.typeText(text)
    XCTAssertEqual(input.value as? String, text)
  }

  @MainActor
  private func openPrivacyAndReturn(in app: XCUIApplication, screenshotName: String) {
    tap("report-privacy", in: app)
    reveal("report-privacy-content", in: app)
    screenshot(app, named: screenshotName)
    goBack(in: app)
  }

  @MainActor
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    switch identifier {
    case "error-report-include-logs", "diagnostics-recording":
      app.switches.matching(identifier: identifier).firstMatch
    case "error-report-no-logs", "diagnostics-saved-count", "log-preview-content",
      "report-privacy-content", "report-send-error", "report-send-success", "receipts-empty":
      app.staticTexts.matching(identifier: identifier).firstMatch
    case "error-report-message":
      // SwiftUI's vertical TextField may expose a TextField or TextView across iOS versions.
      app.descendants(matching: .any).matching(identifier: identifier).matching(
        NSPredicate(
          format: "elementType == %lu OR elementType == %lu",
          XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )
      ).firstMatch
    default:
      app.buttons.matching(identifier: identifier).firstMatch
    }
  }

  @MainActor
  private func tap(_ identifier: String, in app: XCUIApplication) {
    let target = element(identifier, in: app)
    reveal(identifier, in: app)
    XCTAssertTrue(target.isEnabled, "Control is disabled: \(identifier)")
    target.tap()
  }

  private enum ScrollDirection { case up, down }

  @MainActor
  private func reveal(
    _ identifier: String, in app: XCUIApplication, direction: ScrollDirection = .up,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let target = element(identifier, in: app)
    let deadline = Date().addingTimeInterval(60)
    for _ in 0..<12 {
      let exists = target.exists
      if exists && target.isHittable { return }
      if Date() >= deadline { break }
      let frame = app.frame
      let keyboard = app.keyboards.firstMatch
      let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
      // Keep gestures in the presented sheet's content, outside the message editor.
      let high = frame.minY + 180
      let low = max(high + 50, bottom - 90)
      var scrollDirection = direction
      if exists {
        let targetFrame = target.frame
        if targetFrame.maxY < high { scrollDirection = .down }
        if targetFrame.minY > low { scrollDirection = .up }
      }
      let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(dx: frame.width - 24, dy: scrollDirection == .up ? low : high))
      let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(dx: frame.width - 24, dy: scrollDirection == .up ? high : low))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    // Never query a missing element's identifier while recording the original failure.
    screenshot(app, named: "unreachable-\(identifier)")
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "unreachable-\(identifier)-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    XCTFail("Control was not reachable after scrolling: \(identifier)", file: file, line: line)
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
