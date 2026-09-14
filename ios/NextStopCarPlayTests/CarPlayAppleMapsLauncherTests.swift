import Foundation
import MapKit
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayAppleMapsLauncherTests: XCTestCase {
  func testOpensTheSelectedNativePlaceURLThroughTheCarPlayScene() async throws {
    let selectedPlace = MKMapItem()
    let sceneOpener = CarPlayMapsSceneOpenerSpy()
    var urlBuilderItems: [MKMapItem] = []
    let launcher = CarPlayAppleMapsLauncher(
      sceneOpener: sceneOpener,
      placeURL: { mapItem in
        urlBuilderItems.append(mapItem)
        return AppleMapsLauncher.placeURL(placeIdentifier: "I1234567890ABCDEF")
      }
    )

    let opened = await launcher.openPlace(selectedPlace)

    XCTAssertTrue(opened)
    XCTAssertEqual(urlBuilderItems.count, 1)
    XCTAssertTrue(urlBuilderItems.first === selectedPlace)
    XCTAssertEqual(sceneOpener.openedURLs.count, 1)
    XCTAssertTrue(sceneOpener.openedMapItems.isEmpty)
    let url = try XCTUnwrap(sceneOpener.openedURLs.first)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "maps.apple.com")
    XCTAssertEqual(components.path, "/place")
    XCTAssertEqual(
      components.queryItems,
      [URLQueryItem(name: "place-id", value: "I1234567890ABCDEF")]
    )
  }

  func testMissingPlaceURLUsesTheExactNativeMapItemOnce() async {
    let selectedPlace = MKMapItem()
    let sceneOpener = CarPlayMapsSceneOpenerSpy()
    let launcher = CarPlayAppleMapsLauncher(sceneOpener: sceneOpener, placeURL: { _ in nil })

    let opened = await launcher.openPlace(selectedPlace)

    XCTAssertTrue(opened)
    XCTAssertTrue(sceneOpener.openedURLs.isEmpty)
    XCTAssertEqual(sceneOpener.openedMapItems.count, 1)
    XCTAssertTrue(sceneOpener.openedMapItems.first === selectedPlace)
  }

  func testRejectedPlaceURLReturnsFailureWithoutTryingAnAlternateLaunch() async {
    let sceneOpener = CarPlayMapsSceneOpenerSpy()
    let recorder = CarPlayMapsLaunchRecorder()
    sceneOpener.result = false
    let launcher = CarPlayAppleMapsLauncher(
      sceneOpener: sceneOpener, diagnostics: recorder,
      placeURL: { _ in AppleMapsLauncher.placeURL(placeIdentifier: "I1234567890ABCDEF") }
    )

    let opened = await launcher.openPlace(MKMapItem())

    XCTAssertFalse(opened)
    XCTAssertEqual(sceneOpener.openedURLs.count, 1)
    XCTAssertTrue(sceneOpener.openedMapItems.isEmpty)
    XCTAssertEqual(recorder.events.map(\.operation), [.mapsLaunch])
    XCTAssertEqual(recorder.events.map(\.outcome), [.failure])
  }

  func testRejectedNativeMapItemReturnsFailureWithoutRetrying() async {
    let selectedPlace = MKMapItem()
    let sceneOpener = CarPlayMapsSceneOpenerSpy()
    sceneOpener.result = false
    let launcher = CarPlayAppleMapsLauncher(sceneOpener: sceneOpener, placeURL: { _ in nil })

    let opened = await launcher.openPlace(selectedPlace)

    XCTAssertFalse(opened)
    XCTAssertTrue(sceneOpener.openedURLs.isEmpty)
    XCTAssertEqual(sceneOpener.openedMapItems.count, 1)
    XCTAssertTrue(sceneOpener.openedMapItems.first === selectedPlace)
  }

  func testCancelledTaskDoesNotAttemptEitherSceneLaunch() async {
    let selectedPlace = MKMapItem()
    let sceneOpener = CarPlayMapsSceneOpenerSpy()
    let recorder = CarPlayMapsLaunchRecorder()
    var urlBuilderCallCount = 0
    let launcher = CarPlayAppleMapsLauncher(
      sceneOpener: sceneOpener, diagnostics: recorder,
      placeURL: { _ in
        urlBuilderCallCount += 1
        return AppleMapsLauncher.placeURL(placeIdentifier: "I1234567890ABCDEF")
      }
    )
    let task = Task { @MainActor in
      await launcher.openPlace(selectedPlace)
    }
    task.cancel()

    let opened = await task.value

    XCTAssertFalse(opened)
    XCTAssertEqual(urlBuilderCallCount, 0)
    XCTAssertTrue(sceneOpener.openedURLs.isEmpty)
    XCTAssertTrue(sceneOpener.openedMapItems.isEmpty)
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testWaitsForSceneCompletionAndReturnsItsFailure() async {
    let selectedPlace = MKMapItem()
    let sceneOpener = CarPlayMapsSceneOpenerSpy()
    let recorder = CarPlayMapsLaunchRecorder()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var instant = startedAt
    let sceneReceivedRequest = expectation(description: "Scene received the place URL")
    sceneOpener.suspendsResult = true
    sceneOpener.onPendingResult = { sceneReceivedRequest.fulfill() }
    let launcher = CarPlayAppleMapsLauncher(
      sceneOpener: sceneOpener, diagnostics: recorder, now: { instant },
      placeURL: { _ in
        AppleMapsLauncher.placeURL(placeIdentifier: "I1234567890ABCDEF")
      }
    )
    var completedResult: Bool?
    let task = Task { @MainActor in
      let opened = await launcher.openPlace(selectedPlace)
      completedResult = opened
      return opened
    }

    let waitResult = await XCTWaiter.fulfillment(of: [sceneReceivedRequest], timeout: 1)

    XCTAssertEqual(waitResult, .completed)
    XCTAssertNil(completedResult)
    XCTAssertEqual(sceneOpener.openedURLs.count, 1)
    XCTAssertTrue(recorder.events.isEmpty)
    instant = startedAt.addingTimeInterval(0.5)
    sceneOpener.complete(with: false)
    let opened = await task.value

    XCTAssertFalse(opened)
    XCTAssertEqual(completedResult, false)
    XCTAssertTrue(sceneOpener.openedMapItems.isEmpty)
    XCTAssertEqual(recorder.events.map(\.durationMilliseconds), [500])
  }
}

@MainActor
private final class CarPlayMapsLaunchRecorder: AppDiagnosticRecording {
  var events: [AppDiagnosticEvent] = []
  func record(_ event: AppDiagnosticEvent) { events.append(event) }
}

@MainActor
private final class CarPlayMapsSceneOpenerSpy: CarPlayMapsSceneOpening {
  var result = true
  var suspendsResult = false
  var onPendingResult: (() -> Void)?
  private(set) var openedURLs: [URL] = []
  private(set) var openedMapItems: [MKMapItem] = []
  private var pendingResult: CheckedContinuation<Bool, Never>?

  func openPlaceURL(_ url: URL) async -> Bool {
    openedURLs.append(url)
    return await completionResult()
  }

  func openMapItem(_ mapItem: MKMapItem) async -> Bool {
    openedMapItems.append(mapItem)
    return await completionResult()
  }

  func complete(with result: Bool) {
    self.result = result
    suspendsResult = false
    pendingResult?.resume(returning: result)
    pendingResult = nil
  }

  private func completionResult() async -> Bool {
    guard suspendsResult else {
      return result
    }
    return await withCheckedContinuation { continuation in
      pendingResult = continuation
      onPendingResult?()
    }
  }
}
