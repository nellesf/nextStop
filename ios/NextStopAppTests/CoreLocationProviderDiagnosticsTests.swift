import CoreLocation
import XCTest

@testable import NextStopApp

@MainActor
final class CoreLocationProviderDiagnosticsTests: XCTestCase {
  func testTechnicalLocationFailureKeepsOnlyPlatformCodeAndDuration() async throws {
    let manager = DiagnosticLocationManager()
    manager.failure = NSError(
      domain: kCLErrorDomain,
      code: CLError.network.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "PRIVATE_LOCATION at 49.664160,11.470720"]
    )
    let recorder = LocationDiagnosticRecorder()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var instant = startedAt
    manager.onRequest = { instant = startedAt.addingTimeInterval(0.125) }
    let provider = CoreLocationProvider(
      diagnostics: recorder, now: { instant }, locationManager: manager
    )

    do {
      _ = try await provider.currentLocation()
      XCTFail("Expected a failed location request")
    } catch {
      XCTAssertEqual(error as? CurrentLocationError, .unavailable)
    }

    let event = try XCTUnwrap(recorder.events.first)
    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(event.operation, .location)
    XCTAssertEqual(event.category, .connection)
    XCTAssertEqual(event.errorDomain, .coreLocation)
    XCTAssertEqual(event.errorCode, CLError.network.rawValue)
    XCTAssertEqual(event.durationMilliseconds, 125)
    let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    for sensitiveValue in ["PRIVATE_LOCATION", "49.664160", "11.470720"] {
      XCTAssertFalse(encoded.contains(sensitiveValue))
    }
  }

  func testEmptyLocationResponseRecordsFailureWithoutInventingAPlatformCode() async throws {
    let manager = DiagnosticLocationManager()
    let recorder = LocationDiagnosticRecorder()
    let provider = CoreLocationProvider(diagnostics: recorder, locationManager: manager)
    do {
      _ = try await provider.currentLocation()
      XCTFail("An empty location callback cannot prepare a route")
    } catch {
      XCTAssertEqual(error as? CurrentLocationError, .unavailable)
    }
    XCTAssertEqual(recorder.events.map(\.operation), [.location])
    XCTAssertNil(recorder.events.first?.errorCode)
  }

  func testSuccessfulLocationDoesNotEnterTheDiagnosticHistory() async throws {
    let manager = DiagnosticLocationManager()
    manager.locations = [CLLocation(latitude: 49.664160, longitude: 11.470720)]
    let recorder = LocationDiagnosticRecorder()
    let provider = CoreLocationProvider(diagnostics: recorder, locationManager: manager)

    let coordinate = try await provider.currentLocation()

    XCTAssertEqual(coordinate.latitude, 49.664160)
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testPermissionDecisionsAndDeniedCallbacksAreNotRecordedAsFailures() async {
    for status in [CLAuthorizationStatus.denied, .restricted, .authorizedWhenInUse] {
      let manager = DiagnosticLocationManager()
      manager.stubAuthorization = status
      manager.failure = NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue)
      let recorder = LocationDiagnosticRecorder()
      let provider = CoreLocationProvider(diagnostics: recorder, locationManager: manager)
      do {
        _ = try await provider.currentLocation()
        XCTFail("Location permission is unavailable")
      } catch {}
      XCTAssertTrue(recorder.events.isEmpty)
    }
  }

  func testCancelledRequestDoesNotStartLocationOrRecordFailure() async {
    let manager = DiagnosticLocationManager()
    let recorder = LocationDiagnosticRecorder()
    let provider = CoreLocationProvider(diagnostics: recorder, locationManager: manager)
    let task = Task { @MainActor in try await provider.currentLocation() }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(manager.requestCount, 0)
    XCTAssertTrue(recorder.events.isEmpty)
  }
}

private final class DiagnosticLocationManager: CLLocationManager {
  var stubAuthorization = CLAuthorizationStatus.authorizedWhenInUse
  var failure: Error?
  var locations: [CLLocation] = []
  var onRequest: (() -> Void)?
  private(set) var requestCount = 0

  override var authorizationStatus: CLAuthorizationStatus { stubAuthorization }
  override var accuracyAuthorization: CLAccuracyAuthorization { .fullAccuracy }

  override func requestLocation() {
    requestCount += 1
    onRequest?()
    if let failure {
      delegate?.locationManager?(self, didFailWithError: failure)
    } else {
      delegate?.locationManager?(self, didUpdateLocations: locations)
    }
  }
}

@MainActor
private final class LocationDiagnosticRecorder: AppDiagnosticRecording {
  var events: [AppDiagnosticEvent] = []
  func record(_ event: AppDiagnosticEvent) { events.append(event) }
}
