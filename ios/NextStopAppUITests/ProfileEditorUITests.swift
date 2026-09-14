import XCTest

/// Never starts navigation or a charging search. Normal UI tests use in-memory
/// profiles; the opt-in CarPlay runner prepares a fresh disposable local store.
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

  /// Captures the unchanged app UI for the website with a disposable example
  /// profile. The destination is selected through the real MapKit search UI;
  /// no screen content is substituted or drawn by the screenshot harness.
  @MainActor
  func testWebsiteScreenshots() {
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
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    let name = app.textFields["profile-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertEqual(name.value as? String, "Leipzig")

    // Replace the existing UI-test placeholder with a public city, using the
    // same destination picker a user sees. A lookup failure must fail capture.
    app.buttons["Fahrziel"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("L")
    dismissFirstUseKeyboardHelp(in: app)
    search.typeText("eipzig Deutschland\n")
    // The profile list remains in the hierarchy behind the destination sheet.
    // Target the result button, not the first cell containing the profile name.
    let city = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Leipzig,", "Deutschland")
    ).firstMatch
    XCTAssertTrue(city.waitForExistence(timeout: 45), "MapKit must return the city Leipzig.")
    XCTAssertTrue(city.isHittable)
    city.tap()
    waitForWebsiteElement(search, toExist: false)
    waitForWebsiteElement(app.keyboards.firstMatch, toExist: false)
    XCTAssertEqual(app.buttons["Fahrziel"].value as? String, "Leipzig")

    let power = app.buttons["Mindestleistung"]
    power.tap()
    let selectedPower = app.buttons["150 kW"]
    XCTAssertTrue(selectedPower.waitForExistence(timeout: 5))
    selectedPower.tap()
    XCTAssertEqual(power.value as? String, "150 kW")

    let scroll = app.scrollViews.firstMatch
    let restaurant = app.switches["Restaurant in der Nähe erforderlich"]
    revealWebsiteElement(restaurant, in: app)
    if restaurant.value as? String != "1" {
      // The enclosing SwiftUI label may be hittable while the thumb is still
      // covered by the fixed save bar. Tap the fully visible native switch.
      let nativeSwitch = restaurant.switches.firstMatch
      XCTAssertTrue(nativeSwitch.isHittable)
      nativeSwitch.tap()
    }
    let restaurantEnabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '1'"), object: restaurant
    )
    XCTAssertEqual(XCTWaiter.wait(for: [restaurantEnabled], timeout: 5), .completed)
    let chain = app.buttons["Restaurantkette"]
    revealWebsiteElement(chain, in: app)
    chain.tap()
    let selectedChain = app.buttons["McDonald's"]
    XCTAssertTrue(selectedChain.waitForExistence(timeout: 5))
    selectedChain.tap()
    XCTAssertEqual(chain.value as? String, "McDonald's")

    let save = app.buttons["profile-save"]
    XCTAssertTrue(save.isHittable)
    save.tap()
    waitForWebsiteElement(name, toExist: false)
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    captureWebsiteScreenshot("website-iphone-profiles", in: app)

    edit.tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["Fahrziel"].value as? String, "Leipzig")
    XCTAssertEqual(power.value as? String, "150 kW")
    captureWebsiteScreenshot("website-iphone-profile-editor", in: app)

    // Scroll the real editor to its lower section so the restaurant criteria
    // and the always-visible save action can be read together.
    scroll.swipeUp()
    revealWebsiteElement(chain, in: app)
    XCTAssertEqual(chain.value as? String, "McDonald's")
    XCTAssertTrue(save.isHittable)
    captureWebsiteScreenshot("website-iphone-profile-filters", in: app)
  }

  /// A normal persistent profile is necessary because the CarPlay scene opens
  /// the app's default store. Only the dedicated fresh-simulator job opts in.
  @MainActor
  func testPrepareCarPlayProfile() throws {
    guard ProcessInfo.processInfo.environment["NEXTSTOP_CARPLAY_CAPTURE"] == "1" else {
      throw XCTSkip("Only run on the disposable CarPlay capture simulator.")
    }
    let previousAppearance = XCUIDevice.shared.appearance
    XCUIDevice.shared.appearance = .light
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(de)",
      "-AppleLocale", "de_DE",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
    ]
    app.launch()
    defer {
      app.terminate()
      XCUIDevice.shared.appearance = previousAppearance
    }
    let create = app.buttons["Erstes Profil anlegen"]
    XCTAssertTrue(create.waitForExistence(timeout: 15), "Capture requires a fresh profile store.")
    create.tap()
    let name = app.textFields["profile-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    app.buttons["Fahrziel"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("L")
    dismissFirstUseKeyboardHelp(in: app)
    search.typeText("eipzig Deutschland\n")
    let city = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Leipzig,", "Deutschland")
    ).firstMatch
    XCTAssertTrue(city.waitForExistence(timeout: 45))
    XCTAssertTrue(city.isHittable)
    city.tap()
    waitForWebsiteElement(search, toExist: false)
    waitForWebsiteElement(app.keyboards.firstMatch, toExist: false)
    XCTAssertEqual(app.buttons["Fahrziel"].value as? String, "Leipzig")
    name.tap()
    name.typeText("Leipzig")
    XCTAssertEqual(name.value as? String, "Leipzig")

    // Saving accepts the name while its keyboard is visible; reopening the
    // editor produces an unfocused form for the remaining menu selections.
    app.buttons["profile-save"].tap()
    waitForWebsiteElement(name, toExist: false)
    let edit = app.buttons["profile-edit"]
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    let power = app.buttons["Mindestleistung"]
    power.tap()
    let selectedPower = app.buttons["150 kW"]
    XCTAssertTrue(selectedPower.waitForExistence(timeout: 5))
    selectedPower.tap()
    XCTAssertEqual(power.value as? String, "150 kW")
    let restaurant = app.switches["Restaurant in der Nähe erforderlich"]
    revealWebsiteElement(restaurant, in: app)
    restaurant.switches.firstMatch.tap()
    let restaurantEnabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '1'"), object: restaurant
    )
    XCTAssertEqual(XCTWaiter.wait(for: [restaurantEnabled], timeout: 5), .completed)
    let chain = app.buttons["Restaurantkette"]
    revealWebsiteElement(chain, in: app)
    chain.tap()
    app.buttons["McDonald's"].tap()
    XCTAssertEqual(chain.value as? String, "McDonald's")
    app.buttons["profile-save"].tap()
    waitForWebsiteElement(name, toExist: false)
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    captureWebsiteScreenshot("carplay-persistent-profile-prepared", in: app)
  }

  @MainActor
  private func waitForWebsiteElement(_ element: XCUIElement, toExist exists: Bool) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == %@", NSNumber(value: exists)), object: element
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
  }

  @MainActor
  private func revealWebsiteElement(_ element: XCUIElement, in app: XCUIApplication) {
    let scroll = app.scrollViews.firstMatch
    let save = app.buttons["profile-save"]
    for _ in 0..<4 {
      if element.exists, element.isHittable, element.frame.maxY < save.frame.minY - 12 {
        break
      }
      scroll.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
    XCTAssertLessThan(element.frame.maxY, save.frame.minY - 12)
  }

  @MainActor
  private func captureWebsiteScreenshot(_ name: String, in app: XCUIApplication) {
    XCTAssertFalse(app.keyboards.firstMatch.exists, "Website captures must not show a keyboard.")
    XCTAssertFalse(app.alerts.firstMatch.exists, "Website captures must not show an alert.")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
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
