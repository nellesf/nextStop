import XCTest

/// Uses an in-memory profile and never starts navigation or a destination lookup.
final class ProfileEditorUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testNameFieldPaddingAcceptsOneTapAndPersistsTypedChanges() {
    let previousAppearance = XCUIDevice.shared.appearance
    XCUIDevice.shared.appearance = .light
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing",
      "-AppleLanguages", "(de)",
      "-AppleLocale", "de_DE",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
    ]
    app.launchEnvironment["NEXTSTOP_UI_TEST_SCENARIO"] = "profile-editor"
    app.launchEnvironment["NEXTSTOP_UI_TEST_APPEARANCE"] = "light"
    app.launch()
    defer {
      app.terminate()
      XCUIDevice.shared.appearance = previousAppearance
    }

    let edit = app.buttons["profile-edit"]
    let field = app.textFields["profile-name"]
    let fieldArea = app.otherElements["profile-name-area"]
    let save = app.buttons["profile-save"]
    var savedName = "Leipzig"
    let taps: [(name: String, offset: CGVector, input: String)] = [
      ("right-padding", CGVector(dx: 0.99, dy: 0.5), "7"),
      ("top-padding", CGVector(dx: 0.5, dy: 0.06), "8"),
      ("bottom-padding", CGVector(dx: 0.5, dy: 0.94), "9"),
    ]

    for tap in taps {
      XCTAssertTrue(edit.waitForExistence(timeout: 10))
      edit.tap()
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      XCTAssertEqual(field.value as? String, savedName)
      XCTAssertTrue(fieldArea.exists)
      XCTAssertGreaterThanOrEqual(fieldArea.frame.height, 48)
      XCTAssertFalse(
        app.keyboards.firstMatch.exists, "Opening the editor must not pre-focus the field.")

      // Exactly one tap outside the text glyphs, without XCTest's element.tap()
      // fallback choosing the center of the native text input for us.
      fieldArea.coordinate(withNormalizedOffset: tap.offset).tap()
      XCTAssertTrue(
        app.keyboards.firstMatch.waitForExistence(timeout: 5),
        "One tap on \(tap.name) must focus the name field."
      )
      app.typeText(tap.input)
      // The first keyboard session on a fresh Simulator can finish injecting
      // its initial key after typeText returns, while presenting QuickPath help.
      let typedValue = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value != %@", savedName), object: field
      )
      XCTAssertEqual(
        XCTWaiter.wait(for: [typedValue], timeout: 10), .completed,
        "The single edge tap must allow the typed character to reach the name field."
      )
      guard let editedName = field.value as? String else {
        return XCTFail("The native text field must expose its edited value.")
      }
      XCTAssertEqual(editedName.count, savedName.count + 1)
      XCTAssertTrue(editedName.contains(tap.input))
      savedName = editedName
      if tap.input == "7" {
        dismissFirstUseKeyboardHelp(in: app)
      }
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "profile-name-focused-from-\(tap.name)"
      attachment.lifetime = .keepAlways
      add(attachment)

      XCTAssertTrue(save.isHittable)
      save.tap()
      let editorDismissed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"), object: field
      )
      XCTAssertEqual(
        XCTWaiter.wait(for: [editorDismissed], timeout: 5), .completed,
        "Saving must finish dismissing the editor before the next profile edit."
      )
      XCTAssertTrue(edit.waitForExistence(timeout: 5))
    }

    edit.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(
      field.value as? String, savedName, "The final edit must survive saving and reopening.")
  }

  @MainActor
  private func dismissFirstUseKeyboardHelp(in app: XCUIApplication) {
    // This belongs to the runner's English system keyboard, not the localized
    // app. Only dismiss the observed tutorial, never a generic Continue button.
    let keyboardHelp = app.staticTexts[
      "Speed up your typing by sliding your finger across the letters to compose a word."
    ]
    if keyboardHelp.waitForExistence(timeout: 3) {
      let continueButton = app.buttons["Continue"]
      XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
      continueButton.tap()
    }
  }
}
