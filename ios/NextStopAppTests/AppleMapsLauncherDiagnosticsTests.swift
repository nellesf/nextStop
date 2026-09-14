import MapKit
import XCTest

@testable import NextStopApp

@MainActor
final class AppleMapsLauncherDiagnosticsTests: XCTestCase {
  func testRejectedURLRecordsFailureWithoutOpeningOrRetainingThePlace() throws {
    let recorder = MapsLaunchRecorder()
    let launcher = AppleMapsLauncher(
      diagnostics: recorder,
      canOpenURL: { _ in false },
      openURL: { _, _ in XCTFail("A rejected URL must not open") },
      openMapItem: { _, _ in
        XCTFail("Do not fall back to another place")
        return true
      },
      nativePlaceURL: { _ in URL(string: "https://maps.apple.com/place?place-id=PRIVATE_PLACE") }
    )

    XCTAssertFalse(launcher.openPlace(MKMapItem()))

    let event = try XCTUnwrap(recorder.events.first)
    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(event.operation, .mapsLaunch)
    XCTAssertEqual(event.outcome, .failure)
    XCTAssertEqual(event.category, .unknown)
    XCTAssertNil(event.errorCode)
    let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    XCTAssertFalse(encoded.contains("PRIVATE_PLACE"))
    XCTAssertFalse(encoded.contains("maps.apple.com"))
  }

  func testAsynchronousURLRejectionRecordsActualCompletionDuration() throws {
    let recorder = MapsLaunchRecorder()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var instant = startedAt
    var completion: (@MainActor @Sendable (Bool) -> Void)?
    let launcher = AppleMapsLauncher(
      diagnostics: recorder,
      now: { instant },
      canOpenURL: { _ in true },
      openURL: { _, callback in completion = callback },
      nativePlaceURL: { _ in URL(string: "https://maps.apple.com/place?place-id=PRIVATE_PLACE") }
    )

    XCTAssertTrue(launcher.openPlace(MKMapItem()))
    XCTAssertTrue(recorder.events.isEmpty)
    instant = startedAt.addingTimeInterval(0.25)
    try XCTUnwrap(completion)(false)

    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(recorder.events.first?.operation, .mapsLaunch)
    XCTAssertEqual(recorder.events.first?.durationMilliseconds, 250)
  }

  func testNativeMapItemFailureIsRecordedButSuccessIsNot() {
    let recorder = MapsLaunchRecorder()
    var shouldOpen = true
    let selectedItem = MKMapItem()
    let launcher = AppleMapsLauncher(
      diagnostics: recorder,
      openMapItem: { item, options in
        XCTAssertTrue(item === selectedItem)
        XCTAssertNil(options)
        return shouldOpen
      },
      nativePlaceURL: { _ in nil }
    )
    XCTAssertTrue(launcher.openPlace(selectedItem))
    XCTAssertTrue(recorder.events.isEmpty)

    shouldOpen = false
    XCTAssertFalse(launcher.openPlace(selectedItem))
    XCTAssertEqual(recorder.events.map(\.operation), [.mapsLaunch])
  }

  func testSuccessfulURLAndCancelledActionDoNotProduceFailures() async {
    let recorder = MapsLaunchRecorder()
    var openCalls = 0
    let launcher = AppleMapsLauncher(
      diagnostics: recorder,
      canOpenURL: { _ in true },
      openURL: { _, completion in
        openCalls += 1
        completion(true)
      },
      nativePlaceURL: { _ in URL(string: "https://maps.apple.com/place?place-id=PRIVATE_PLACE") }
    )
    XCTAssertTrue(launcher.openPlace(MKMapItem()))
    let task = Task { @MainActor in launcher.openPlace(MKMapItem()) }
    task.cancel()
    let cancelledResult = await task.value
    XCTAssertFalse(cancelledResult)
    XCTAssertEqual(openCalls, 1)
    XCTAssertTrue(recorder.events.isEmpty)
  }
}

@MainActor
private final class MapsLaunchRecorder: AppDiagnosticRecording {
  var events: [AppDiagnosticEvent] = []
  func record(_ event: AppDiagnosticEvent) { events.append(event) }
}
