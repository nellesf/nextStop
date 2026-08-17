import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class RidePreparationViewModelTests: XCTestCase {
  func testAppleMapsURLKeepsDestinationAndAddsRestaurantWaypoint() throws {
    let destination = try SavedDestination(
      displayName: "Berlin Hauptbahnhof",
      coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694),
      applePlaceIdentifier: "destination-place"
    )
    let restaurant = try FoodPOI(
      id: "restaurant",
      applePlaceIdentifier: "restaurant-place",
      chain: .mcdonalds,
      name: "McDonald's",
      coordinate: Coordinate(latitude: 52.1, longitude: 10.2),
      distanceFromPark: Meters(120),
      openingStatus: .unknown
    )

    let url = try XCTUnwrap(
      AppleMapsNavigationLauncher.multistopDirectionsURL(
        waypoint: restaurant,
        finalDestination: destination
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let values = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "maps.apple.com")
    XCTAssertEqual(components.path, "/directions")
    XCTAssertEqual(values["destination"], "52.5251,13.3694")
    XCTAssertEqual(values["destination-place-id"], "destination-place")
    XCTAssertEqual(values["waypoint"], "52.1,10.2")
    XCTAssertEqual(values["waypoint-place-id"], "restaurant-place")
    XCTAssertEqual(values["mode"], "driving")
  }

  func testPreparationUsesCurrentLocationAndCreatesPrivacyScopedRequest() async throws {
    let origin = try Coordinate(latitude: 48.1372, longitude: 11.5756)
    let destination = try SavedDestination(
      displayName: "Berlin Hauptbahnhof",
      coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694),
      displayAddress: "Europaplatz 1, Berlin"
    )
    let profile = try makeProfile(name: "Private profile name", destination: destination)
    let route = try PlannedRoute(
      polyline: RoutePolyline(coordinates: [origin, destination.coordinate]),
      actualDrivingDistance: Meters(585_000),
      expectedTravelTimeSeconds: 20_400
    )
    let locationProvider = LocationProviderStub(result: .success(origin))
    let routePlanner = RoutePlannerStub(result: .success(route))
    let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(profile: profile),
      locationProvider: locationProvider,
      routePlanner: routePlanner,
      makeRequestID: { requestID }
    )

    await viewModel.prepareRoute()

    XCTAssertEqual(routePlanner.receivedOrigin, origin)
    XCTAssertEqual(routePlanner.receivedDestination, destination.coordinate)
    guard case .ready(let preparedSearch) = viewModel.state else {
      return XCTFail("Expected a prepared ride search")
    }
    XCTAssertEqual(preparedSearch.origin, origin)
    XCTAssertEqual(preparedSearch.route, route)
    XCTAssertEqual(preparedSearch.request.requestID, requestID)
    XCTAssertEqual(preparedSearch.request.route, route.polyline)
    XCTAssertEqual(preparedSearch.request.criteria, profile.criteria)
    XCTAssertNil(preparedSearch.request.snapshotToken)
    XCTAssertNil(preparedSearch.request.cursor)

    await viewModel.prepareRoute()
    XCTAssertEqual(locationProvider.requestCount, 1)
    XCTAssertEqual(routePlanner.requestCount, 1)
  }

  func testDeniedLocationMapsToActionableFailureWithoutCallingRoutePlanner() async throws {
    let destination = try SavedDestination(
      displayName: "Hamburg",
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
    let locationProvider = LocationProviderStub(
      result: .failure(CurrentLocationError.authorizationDenied)
    )
    let routePlanner = RoutePlannerStub(
      result: .failure(RoutePlanningError.noRoute)
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: locationProvider,
      routePlanner: routePlanner
    )

    await viewModel.prepareRoute()

    XCTAssertEqual(viewModel.state, .failed(.locationPermissionDenied))
    XCTAssertNil(routePlanner.receivedOrigin)
  }

  func testReducedAccuracyMapsToPreciseLocationFailure() async throws {
    let destination = try SavedDestination(
      displayName: "Hamburg",
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: LocationProviderStub(
        result: .failure(CurrentLocationError.reducedAccuracy)
      ),
      routePlanner: RoutePlannerStub(result: .failure(RoutePlanningError.noRoute))
    )

    await viewModel.prepareRoute()

    XCTAssertEqual(viewModel.state, .failed(.preciseLocationRequired))
  }

  func testRouteErrorKeepsDraftAndCanBeRetried() async throws {
    let origin = try Coordinate(latitude: 53.5511, longitude: 9.9937)
    let destination = try SavedDestination(
      displayName: "Bremen",
      coordinate: Coordinate(latitude: 53.0793, longitude: 8.8017)
    )
    let routePlanner = RoutePlannerStub(result: .failure(RoutePlanningError.noRoute))
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: LocationProviderStub(result: .success(origin)),
      routePlanner: routePlanner
    )

    await viewModel.prepareRoute()
    XCTAssertEqual(viewModel.state, .failed(.routeUnavailable))
    XCTAssertEqual(viewModel.draft.destination, destination)

    routePlanner.result = .success(
      PlannedRoute(
        polyline: try RoutePolyline(coordinates: [origin, destination.coordinate]),
        actualDrivingDistance: Meters(120_000),
        expectedTravelTimeSeconds: 5_400
      )
    )
    await viewModel.prepareRoute()

    guard case .ready = viewModel.state else {
      return XCTFail("Expected retry to prepare the route")
    }
  }

  func testRetryingRoutePlannerRecoversFromOneTransientFailure() async throws {
    let origin = try Coordinate(latitude: 53.5511, longitude: 9.9937)
    let destination = try Coordinate(latitude: 53.0793, longitude: 8.8017)
    let expected = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination]),
      actualDrivingDistance: Meters(120_000),
      expectedTravelTimeSeconds: 5_400
    )
    let base = SequencedRoutePlannerStub(responses: [
      .failure(RoutePlanningError.noRoute),
      .success(expected),
    ])
    let planner = RetryingRoutePlanner(
      base: base,
      retryDelay: .zero
    )

    let route = try await planner.automobileRoute(from: origin, to: destination)

    XCTAssertEqual(route, expected)
    XCTAssertEqual(base.requestCount, 2)
  }

  private func makeProfile(name: String, destination: SavedDestination) throws -> UserProfile {
    try UserProfile(
      name: name,
      destination: destination,
      criteria: RideCriteria(
        distanceRange: .kilometers100To150,
        minimumChargingPoints: .eight,
        minimumPower: .oneHundredFifty,
        foodChain: .mcdonalds
      ),
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
  }
}

@MainActor
private final class LocationProviderStub: CurrentLocationProviding {
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
private final class RoutePlannerStub: RoutePlanning {
  var result: Result<PlannedRoute, any Error>
  private(set) var receivedOrigin: Coordinate?
  private(set) var receivedDestination: Coordinate?
  private(set) var requestCount = 0

  init(result: Result<PlannedRoute, any Error>) {
    self.result = result
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    requestCount += 1
    receivedOrigin = origin
    receivedDestination = destination
    return try result.get()
  }
}

@MainActor
private final class SequencedRoutePlannerStub: RoutePlanning {
  private var responses: [Result<PlannedRoute, any Error>]
  private(set) var requestCount = 0

  init(responses: [Result<PlannedRoute, any Error>]) {
    self.responses = responses
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    _ = origin
    _ = destination
    requestCount += 1
    guard !responses.isEmpty else {
      throw RoutePlanningError.noRoute
    }
    return try responses.removeFirst().get()
  }
}
