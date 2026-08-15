import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class RideIntentHandlerTests: XCTestCase {
  func testResolvedDestinationIsForwardedToTheAppRouter() async throws {
    let destination = try SavedDestination(
      displayName: "Berlin Hauptbahnhof",
      coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694)
    )
    let router = RideIntentRouter()
    let handler = RideIntentHandler(
      destinationSearcher: DestinationSearcherStub(
        results: [
          DestinationSearchResult(
            id: "berlin",
            destination: destination,
            subtitle: nil
          )
        ]
      ),
      router: router
    )

    let resolved = try await handler.prepareRide(destinationQuery: "Berlin Hbf")

    XCTAssertEqual(resolved, destination)
    XCTAssertEqual(router.pendingDestination, destination)
    router.consumePendingDestination()
    XCTAssertNil(router.pendingDestination)
  }

  func testMissingDestinationDoesNotChangeTheAppRoute() async throws {
    let router = RideIntentRouter()
    let handler = RideIntentHandler(
      destinationSearcher: DestinationSearcherStub(results: []),
      router: router
    )

    let resolved = try await handler.prepareRide(destinationQuery: "Unknown")

    XCTAssertNil(resolved)
    XCTAssertNil(router.pendingDestination)
  }
}

@MainActor
private final class DestinationSearcherStub: DestinationSearching {
  let results: [DestinationSearchResult]

  init(results: [DestinationSearchResult]) {
    self.results = results
  }

  func search(query: String) async throws -> [DestinationSearchResult] {
    results
  }
}
