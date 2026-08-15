import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayRideSearchServiceTests: XCTestCase {
  func testBuildsTheSamePrivacyScopedRideSearchUsedByTheIPhoneApp() async throws {
    let origin = try Coordinate(latitude: 47.3769, longitude: 8.5417)
    let destination = try SavedDestination(
      displayName: "Bern",
      coordinate: Coordinate(latitude: 46.948, longitude: 7.4474)
    )
    let draft = RideSearchDraft(destination: destination)
    let route = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination.coordinate]),
      actualDrivingDistance: Meters(122_000),
      expectedTravelTimeSeconds: 5_400
    )
    let expectedOutcome = RideCandidateSearchOutcome(
      results: [],
      coverage: CandidateSearchCoverage(
        status: .complete,
        activeSourceIDs: ["ich_tanke_strom"],
        unavailableSourceIDs: [],
        projectionUpdatedAt: Date(timeIntervalSince1970: 0)
      )
    )
    let candidateSearcher = CarPlayCandidateSearcherStub(result: .success(expectedOutcome))
    let requestID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    let service = CarPlayRideSearchService(
      locationReadiness: CarPlayLocationReadinessStub(isReadyForRouteSearch: true),
      locationProvider: CarPlayLocationProviderStub(result: .success(origin)),
      routePlanner: CarPlayRoutePlannerStub(result: .success(route)),
      candidateSearcher: candidateSearcher,
      makeRequestID: { requestID }
    )

    let outcome = try await service.search(draft: draft)

    XCTAssertEqual(outcome, expectedOutcome)
    let preparedRide = try XCTUnwrap(candidateSearcher.preparedRide)
    XCTAssertEqual(preparedRide.origin, origin)
    XCTAssertEqual(preparedRide.route, route)
    XCTAssertEqual(preparedRide.request.requestID, requestID)
    XCTAssertEqual(preparedRide.request.route, route.polyline)
    XCTAssertEqual(preparedRide.request.criteria, draft.criteria)
    XCTAssertNil(preparedRide.request.snapshotToken)
    XCTAssertNil(preparedRide.request.cursor)
  }

  func testRequiresIPhoneLocationSetupBeforeStartingAnyCarPlayWork() async throws {
    let locationProvider = CarPlayLocationProviderStub(
      result: .failure(CurrentLocationError.unavailable)
    )
    let routePlanner = CarPlayRoutePlannerStub(
      result: .failure(RoutePlanningError.noRoute)
    )
    let candidateSearcher = CarPlayCandidateSearcherStub(
      result: .failure(RideCandidateSearchError.candidateServiceUnavailable)
    )
    let service = CarPlayRideSearchService(
      locationReadiness: CarPlayLocationReadinessStub(isReadyForRouteSearch: false),
      locationProvider: locationProvider,
      routePlanner: routePlanner,
      candidateSearcher: candidateSearcher
    )

    do {
      _ = try await service.search(draft: try makeDraft())
      XCTFail("Expected iPhone setup to be required")
    } catch let error as CarPlayRideSearchError {
      XCTAssertEqual(error, .phoneSetupRequired)
    }
    XCTAssertEqual(locationProvider.requestCount, 0)
    XCTAssertEqual(routePlanner.requestCount, 0)
    XCTAssertNil(candidateSearcher.preparedRide)
  }

  func testMapsCandidateSnapshotFailureToAnActionableCarPlayError() async throws {
    let origin = try Coordinate(latitude: 47.3769, longitude: 8.5417)
    let destination = try Coordinate(latitude: 46.948, longitude: 7.4474)
    let route = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination]),
      actualDrivingDistance: Meters(122_000),
      expectedTravelTimeSeconds: 5_400
    )
    let service = CarPlayRideSearchService(
      locationReadiness: CarPlayLocationReadinessStub(isReadyForRouteSearch: true),
      locationProvider: CarPlayLocationProviderStub(result: .success(origin)),
      routePlanner: CarPlayRoutePlannerStub(result: .success(route)),
      candidateSearcher: CarPlayCandidateSearcherStub(
        result: .failure(RideCandidateSearchError.candidateSnapshotExpired)
      )
    )

    do {
      _ = try await service.search(draft: try makeDraft())
      XCTFail("Expected a snapshot error")
    } catch let error as CarPlayRideSearchError {
      XCTAssertEqual(error, .snapshotExpired)
    }
  }

  private func makeDraft() throws -> RideSearchDraft {
    RideSearchDraft(
      destination: try SavedDestination(
        displayName: "Bern",
        coordinate: Coordinate(latitude: 46.948, longitude: 7.4474)
      )
    )
  }
}

@MainActor
private final class CarPlayLocationReadinessStub: CarPlayLocationReadinessChecking {
  let isReadyForRouteSearch: Bool

  init(isReadyForRouteSearch: Bool) {
    self.isReadyForRouteSearch = isReadyForRouteSearch
  }
}

@MainActor
private final class CarPlayLocationProviderStub: CurrentLocationProviding {
  let result: Result<Coordinate, any Error>
  private(set) var requestCount = 0

  init(result: Result<Coordinate, any Error>) {
    self.result = result
  }

  func currentLocation() async throws -> Coordinate {
    requestCount += 1
    return try result.get()
  }
}

@MainActor
private final class CarPlayRoutePlannerStub: RoutePlanning {
  let result: Result<PlannedRoute, any Error>
  private(set) var requestCount = 0

  init(result: Result<PlannedRoute, any Error>) {
    self.result = result
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    _ = origin
    _ = destination
    requestCount += 1
    return try result.get()
  }
}

@MainActor
private final class CarPlayCandidateSearcherStub: RideCandidateSearching {
  let result: Result<RideCandidateSearchOutcome, any Error>
  private(set) var preparedRide: PreparedRideSearch?

  init(result: Result<RideCandidateSearchOutcome, any Error>) {
    self.result = result
  }

  func search(preparedRide: PreparedRideSearch) async throws -> RideCandidateSearchOutcome {
    self.preparedRide = preparedRide
    return try result.get()
  }
}
