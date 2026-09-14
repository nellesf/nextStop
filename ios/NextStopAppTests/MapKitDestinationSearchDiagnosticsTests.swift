import MapKit
import XCTest

@testable import NextStopApp

@MainActor
final class MapKitDestinationSearchDiagnosticsTests: XCTestCase {
  func testDestinationLookupFailureKeepsPlatformMetadataWithoutQueryOrRawError() async throws {
    let recorder = DestinationDiagnosticRecorder()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var instant = startedAt
    let original = NSError(
      domain: MKErrorDomain,
      code: Int(MKError.loadingThrottled.rawValue),
      userInfo: [NSLocalizedDescriptionKey: "PRIVATE_DESTINATION at 49.664160,11.470720"]
    )
    let searcher = MapKitDestinationSearchService(
      diagnostics: recorder,
      now: { instant },
      performSearch: { request in
        XCTAssertEqual(request.naturalLanguageQuery, "PRIVATE_DESTINATION")
        instant = startedAt.addingTimeInterval(0.25)
        throw original
      }
    )
    do {
      _ = try await searcher.search(query: " PRIVATE_DESTINATION ")
      XCTFail("Expected the platform error")
    } catch {
      XCTAssertTrue((error as NSError) === original)
    }

    let event = try XCTUnwrap(recorder.events.first)
    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(event.operation, .destinationSearch)
    XCTAssertEqual(event.category, .throttled)
    XCTAssertEqual(event.errorDomain, .mapKit)
    XCTAssertEqual(event.errorCode, Int(MKError.loadingThrottled.rawValue))
    XCTAssertEqual(event.durationMilliseconds, 250)
    let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    for sensitiveValue in ["PRIVATE_DESTINATION", "49.664160", "11.470720"] {
      XCTAssertFalse(encoded.contains(sensitiveValue))
    }
  }

  func testEmptyQueryAndSuccessfulEmptyResultsDoNotProduceDiagnostics() async throws {
    let recorder = DestinationDiagnosticRecorder()
    var searchCount = 0
    let searcher = MapKitDestinationSearchService(
      diagnostics: recorder,
      performSearch: { _ in
        searchCount += 1
        return []
      }
    )
    let emptyQuery = try await searcher.search(query: " \n ")
    XCTAssertTrue(emptyQuery.isEmpty)
    XCTAssertEqual(searchCount, 0)
    let noResults = try await searcher.search(query: "PRIVATE_DESTINATION")
    XCTAssertTrue(noResults.isEmpty)
    XCTAssertEqual(searchCount, 1)
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testCancelledLookupDoesNotRecordFailure() async {
    for failure: Error in [CancellationError(), URLError(.cancelled)] {
      let recorder = DestinationDiagnosticRecorder()
      let searcher = MapKitDestinationSearchService(
        diagnostics: recorder, performSearch: { _ in throw failure }
      )
      do {
        _ = try await searcher.search(query: "PRIVATE_DESTINATION")
        XCTFail("Expected cancellation")
      } catch {}
      XCTAssertTrue(recorder.events.isEmpty)
    }
  }
}

@MainActor
private final class DestinationDiagnosticRecorder: AppDiagnosticRecording {
  var events: [AppDiagnosticEvent] = []
  func record(_ event: AppDiagnosticEvent) { events.append(event) }
}
