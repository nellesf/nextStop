import MapKit
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class AppDiagnosticMeasurementTests: XCTestCase {
  func testRouteFailurePreservesErrorAndOnlyRecordsAllowedMetadata() async throws {
    let recorder = MeasurementRecorder()
    let startedAt = Date(timeIntervalSince1970: 1_789_200_000)
    var instant = startedAt
    let original = NSError(
      domain: MKErrorDomain,
      code: Int(MKError.directionsNotFound.rawValue),
      userInfo: [NSLocalizedDescriptionKey: "PRIVATE destination Leipzig at 49.664160,11.470720"]
    )
    let planner = MapKitRoutePlanner(
      diagnostics: recorder,
      now: { instant },
      calculateRoute: { _ in
        instant = startedAt.addingTimeInterval(0.125)
        throw original
      }
    )
    let point = try Coordinate(latitude: 49.664160, longitude: 11.470720)

    do {
      _ = try await planner.automobileDrivingDistance(from: point, to: point)
      XCTFail("Expected the original MapKit error")
    } catch {
      XCTAssertTrue((error as NSError) === original)
    }

    let event = try XCTUnwrap(recorder.events.first)
    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(event.operation, .candidateDistance)
    XCTAssertEqual(event.category, .noRoute)
    XCTAssertEqual(event.errorDomain, .mapKit)
    XCTAssertEqual(event.errorCode, Int(MKError.directionsNotFound.rawValue))
    XCTAssertEqual(event.durationMilliseconds, 125)
    let report = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    for secret in ["PRIVATE", "Leipzig", "49.664160", "11.470720"] {
      XCTAssertFalse(report.contains(secret))
    }
  }

  func testUnknownErrorCannotExportItsDomainCodeOrPayload() async throws {
    let recorder = MeasurementRecorder()
    let measurement = AppDiagnosticMeasurement(recorder: recorder)
    do {
      try await measurement.perform(.placeLookup) {
        throw NSError(domain: "PRIVATE_TOKEN", code: 987, userInfo: ["route": "PRIVATE_ROUTE"])
      }
      XCTFail("Expected a failure")
    } catch {}
    let event = try XCTUnwrap(recorder.events.first)
    XCTAssertEqual(event.category, .unknown)
    XCTAssertEqual(event.errorDomain, .unknown)
    XCTAssertNil(event.errorCode)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("PRIVATE"))
  }

  func testSuccessAndCancellationDoNotProduceFailureReports() async throws {
    let recorder = MeasurementRecorder()
    let measurement = AppDiagnosticMeasurement(recorder: recorder)
    let value = try await measurement.perform(.route) { 7 }
    XCTAssertEqual(value, 7)
    for error: Error in [CancellationError(), URLError(.cancelled)] {
      do {
        try await measurement.perform(.route) { throw error }
        XCTFail("Cancellation must propagate")
      } catch {}
    }
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testRouteValidationFailureKeepsItsCoarseCategory() async throws {
    let recorder = MeasurementRecorder()
    let measurement = AppDiagnosticMeasurement(recorder: recorder)
    do {
      try await measurement.perform(.route) { throw RoutePlanningError.invalidPolyline }
      XCTFail("Expected invalid geometry")
    } catch let error as RoutePlanningError {
      XCTAssertEqual(error, .invalidPolyline)
    }
    XCTAssertEqual(recorder.events.first?.category, .invalidRoute)
    XCTAssertEqual(recorder.events.first?.errorDomain, .routePlanning)
    XCTAssertNil(recorder.events.first?.errorCode)
  }
}

@MainActor
private final class MeasurementRecorder: AppDiagnosticRecording {
  var events: [AppDiagnosticEvent] = []
  func record(_ event: AppDiagnosticEvent) { events.append(event) }
}
