import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class RidePreparationViewModelTests: XCTestCase {
  func testAppleChargingLookupScopeIncludesSameOperatorAtExactSameAddress() throws {
    let sharedAddress = ChargingLocationAddress(
      street: "Am Fuchsenacker",
      houseNumber: "2",
      postalCode: "97877",
      city: "Wertheim"
    )
    let primary = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "HomE of Mobility GmbH",
      coordinate: Coordinate(latitude: 49.772275, longitude: 9.587747),
      address: sharedAddress
    )
    let related = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "HomE of Mobility GmbH",
      coordinate: Coordinate(latitude: 49.772468, longitude: 9.585005),
      address: sharedAddress
    )
    let differentAddress = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "HomE of Mobility GmbH",
      coordinate: Coordinate(latitude: 49.8, longitude: 9.6),
      address: ChargingLocationAddress(
        street: "Other Street",
        houseNumber: "1",
        postalCode: "97877",
        city: "Wertheim"
      )
    )
    let otherOperator = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "Other operator",
      coordinate: Coordinate(latitude: 49.772468, longitude: 9.585005),
      address: sharedAddress
    )

    let locations = AppleChargingPlaceLookupScope.relatedLocations(
      primaryLocations: [primary],
      candidateLocations: [primary, related, differentAddress, otherOperator],
      operatorName: "HomE of Mobility GmbH"
    )

    XCTAssertEqual(Set(locations.map(\.id)), Set([primary.id, related.id]))
  }

  func testAppleChargingLookupScopeNormalizesEquivalentAddresses() {
    let first = ChargingLocationAddress(
      street: "Am Fuchsenacker",
      houseNumber: "2",
      postalCode: "97877",
      city: "Wertheim"
    )
    let second = ChargingLocationAddress(
      street: "am-fuchsenacker",
      houseNumber: " 2 ",
      postalCode: "97877",
      city: "WERTHEIM"
    )

    XCTAssertEqual(
      AppleChargingPlaceLookupScope.addressKey(first),
      AppleChargingPlaceLookupScope.addressKey(second)
    )
  }

  func testRestaurantGroupLookupScopeIncludesEveryExactOperatorLocation() throws {
    let first = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "IONITY",
      coordinate: Coordinate(latitude: 50.001, longitude: 8),
      address: ChargingLocationAddress(
        street: "First Street",
        houseNumber: "1",
        postalCode: "10000",
        city: "First City"
      )
    )
    let second = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "IONITY",
      coordinate: Coordinate(latitude: 50.01, longitude: 8.01),
      address: ChargingLocationAddress(
        street: "Second Street",
        houseNumber: "2",
        postalCode: "20000",
        city: "Second City"
      )
    )
    let differentlyNamedOperator = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "Ionity GmbH",
      coordinate: Coordinate(latitude: 50.02, longitude: 8.02),
      address: ChargingLocationAddress()
    )

    let locations = AppleChargingPlaceLookupScope.restaurantGroupLocations(
      candidateLocations: [first, second, first, differentlyNamedOperator],
      operatorName: "IONITY"
    )

    XCTAssertEqual(locations.map(\.id), [first.id, second.id])
  }

  func testAppleChargingPlaceMatchAllowsLargeCampusOnlyWithExactAddress() {
    XCTAssertTrue(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 60,
        hasExactAddressMatch: false
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 61,
        hasExactAddressMatch: false
      )
    )
    XCTAssertTrue(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 300,
        hasExactAddressMatch: true
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 301,
        hasExactAddressMatch: true
      )
    )
  }

  func testNoFoodCampusMatchAcceptsWertheimShapedGeometryEvidence() {
    let match = AppleChargingPlaceMatchPolicy.match(
      evidence: campusEvidence(),
      scope: .noFoodCampus
    )

    XCTAssertEqual(
      match,
      .campus(distanceMeters: 44, stablePlaceIdentifier: "I19TESLA")
    )
  }

  func testFoodModeKeepsAppleChargingMatchOperatorScoped() {
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(),
        scope: .operatorOnly
      )
    )
  }

  func testNoFoodCampusPrefersOperatorScopedEvidence() {
    let evidence = AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: true,
      operatorScopedDistanceMeters: 60,
      hasExactOperatorAddressMatch: false,
      isEVCharger: true,
      campusDistanceMeters: 20,
      hasCampusLocalityMatch: true,
      stablePlaceIdentifier: "I19TESLA"
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: evidence,
        scope: .noFoodCampus
      ),
      .operatorScoped(distanceMeters: 60)
    )
  }

  func testCampusMatchRejectsWrongCategoryLocalityAndCanonicalOperator() {
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(isEVCharger: false),
        scope: .noFoodCampus
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(hasCampusLocalityMatch: false),
        scope: .noFoodCampus
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(canonicalOperatorNameMatches: false),
        scope: .noFoodCampus
      )
    )
  }

  func testCampusMatchKeepsSixtyMeterBoundaryAndRequiresStableIdentity() {
    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(campusDistanceMeters: 60),
        scope: .noFoodCampus
      ),
      .campus(distanceMeters: 60, stablePlaceIdentifier: "I19TESLA")
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(campusDistanceMeters: 61),
        scope: .noFoodCampus
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(stablePlaceIdentifier: nil),
        scope: .noFoodCampus
      )
    )
  }

  func testCampusMatchRequiresOneStableApplePlaceIdentity() throws {
    let first = try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(stablePlaceIdentifier: "FIRST"),
        scope: .noFoodCampus
      )
    )
    let duplicate = try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(stablePlaceIdentifier: "FIRST"),
        scope: .noFoodCampus
      )
    )
    let second = try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: campusEvidence(stablePlaceIdentifier: "SECOND"),
        scope: .noFoodCampus
      )
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.unambiguousCampusPlaceIdentifier(
        in: [first, duplicate]
      ),
      "FIRST"
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.unambiguousCampusPlaceIdentifier(
        in: [first, second]
      )
    )
  }

  func testOperatorScopedMatchPreservesExistingBroaderNameRule() {
    let evidence = AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: false,
      operatorScopedDistanceMeters: 60,
      hasExactOperatorAddressMatch: false,
      isEVCharger: true,
      campusDistanceMeters: nil,
      hasCampusLocalityMatch: false,
      stablePlaceIdentifier: nil
    )
    let wrongCategoryEvidence = AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: false,
      operatorScopedDistanceMeters: 60,
      hasExactOperatorAddressMatch: false,
      isEVCharger: false,
      campusDistanceMeters: nil,
      hasCampusLocalityMatch: false,
      stablePlaceIdentifier: nil
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: evidence,
        scope: .operatorOnly
      ),
      .operatorScoped(distanceMeters: 60)
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: wrongCategoryEvidence,
        scope: .operatorOnly
      )
    )
  }

  func testCampusLocalityAcceptsCityOrPostalCode() {
    let campusAddress = ChargingLocationAddress(
      street: "Am Fuchsenacker",
      houseNumber: "2",
      postalCode: "97877",
      city: "Wertheim"
    )

    XCTAssertTrue(
      AppleChargingPlaceLookupScope.localityMatches(
        "Almosenberg 12, Bettingen, 97877 Wertheim, Deutschland",
        referenceAddresses: [campusAddress]
      )
    )
    XCTAssertTrue(
      AppleChargingPlaceLookupScope.localityMatches(
        "Andere Straße 1, Wertheim, Deutschland",
        referenceAddresses: [campusAddress]
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceLookupScope.localityMatches(
        "Andere Straße 1, 97070 Würzburg, Deutschland",
        referenceAddresses: [campusAddress]
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceLookupScope.localityMatches(
        "Andere Straße 1, Hessen, Deutschland",
        referenceAddresses: [
          ChargingLocationAddress(
            street: nil,
            houseNumber: nil,
            postalCode: nil,
            city: "Essen"
          )
        ]
      )
    )
  }

  func testChargingPlaceFallbackQueryKeepsExactSelectedOperatorName() {
    XCTAssertEqual(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "  Tesla Germany GmbH  ",
        scope: .noFoodCampus,
        hasSecureCategoryMatch: false
      ),
      "Tesla Germany GmbH"
    )
    XCTAssertEqual(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "IONITY",
        scope: .noFoodCampus,
        hasSecureCategoryMatch: false
      ),
      "IONITY"
    )
  }

  func testChargingPlaceFallbackQueryRequiresNoFoodScopeAndCategoryMiss() {
    XCTAssertNil(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "Tesla Germany GmbH",
        scope: .operatorOnly,
        hasSecureCategoryMatch: false
      )
    )
    XCTAssertNil(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "Tesla Germany GmbH",
        scope: .noFoodCampus,
        hasSecureCategoryMatch: true
      )
    )
  }

  private func campusEvidence(
    canonicalOperatorNameMatches: Bool = true,
    isEVCharger: Bool = true,
    campusDistanceMeters: Double = 44,
    hasCampusLocalityMatch: Bool = true,
    stablePlaceIdentifier: String? = "I19TESLA"
  ) -> AppleChargingPlaceMatchPolicy.Evidence {
    AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: canonicalOperatorNameMatches,
      operatorScopedDistanceMeters: nil,
      hasExactOperatorAddressMatch: false,
      isEVCharger: isEVCharger,
      campusDistanceMeters: campusDistanceMeters,
      hasCampusLocalityMatch: hasCampusLocalityMatch,
      stablePlaceIdentifier: stablePlaceIdentifier
    )
  }

  func testNativeApplePlaceURLUsesOnlyTheStablePlaceIdentifier() throws {
    let url = try XCTUnwrap(
      AppleMapsLauncher.placeURL(placeIdentifier: "I1234567890ABCDEF")
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "maps.apple.com")
    XCTAssertEqual(components.path, "/place")
    XCTAssertEqual(
      components.queryItems,
      [
        URLQueryItem(name: "place-id", value: "I1234567890ABCDEF")
      ])
  }

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
      AppleMapsLauncher.multistopDirectionsURL(
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

  func testPreparationAndCandidateSearchRunAsOneFlowExactlyOnce() async throws {
    let origin = try Coordinate(latitude: 50.1109, longitude: 8.6821)
    let destination = try SavedDestination(
      displayName: "Rostock",
      coordinate: Coordinate(latitude: 54.0924, longitude: 12.0991)
    )
    let route = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination.coordinate]),
      actualDrivingDistance: Meters(666_000),
      expectedTravelTimeSeconds: 22_000
    )
    let coverage = CandidateSearchCoverage(
      status: .complete,
      activeSourceIDs: ["bundesnetzagentur_ladesaeulenregister"],
      unavailableSourceIDs: [],
      projectionUpdatedAt: Date(timeIntervalSince1970: 0)
    )
    let locationProvider = LocationProviderStub(result: .success(origin))
    let routePlanner = RoutePlannerStub(result: .success(route))
    let candidateSearcher = CandidateSearcherStub(
      result: .success(RideCandidateSearchOutcome(results: [], coverage: coverage))
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: locationProvider,
      routePlanner: routePlanner,
      candidateSearcher: candidateSearcher
    )

    await viewModel.prepareRouteAndSearch()

    guard case .ready(let preparedRide) = viewModel.state else {
      return XCTFail("Expected the route to be ready")
    }
    XCTAssertEqual(candidateSearcher.preparedRides, [preparedRide])
    XCTAssertEqual(
      viewModel.candidateSearchState,
      .noResults(RideCandidateSearchOutcome(results: [], coverage: coverage))
    )

    await viewModel.prepareRouteAndSearch()

    XCTAssertEqual(locationProvider.requestCount, 1)
    XCTAssertEqual(routePlanner.requestCount, 1)
    XCTAssertEqual(candidateSearcher.preparedRides.count, 1)
  }

  func testPreparationFailureDoesNotStartCandidateSearch() async throws {
    let destination = try SavedDestination(
      displayName: "Rostock",
      coordinate: Coordinate(latitude: 54.0924, longitude: 12.0991)
    )
    let candidateSearcher = CandidateSearcherStub(
      result: .failure(RideCandidateSearchError.candidateServiceUnavailable)
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: LocationProviderStub(
        result: .failure(CurrentLocationError.authorizationDenied)
      ),
      routePlanner: RoutePlannerStub(result: .failure(RoutePlanningError.noRoute)),
      candidateSearcher: candidateSearcher
    )

    await viewModel.prepareRouteAndSearch()

    XCTAssertEqual(viewModel.state, .failed(.locationPermissionDenied))
    XCTAssertEqual(viewModel.candidateSearchState, .idle)
    XCTAssertTrue(candidateSearcher.preparedRides.isEmpty)
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

  func testDirectionsRequestGateWaitsBeforeExceedingTheRollingLimit() async throws {
    let origin = try Coordinate(latitude: 53.5511, longitude: 9.9937)
    let destination = try Coordinate(latitude: 53.0793, longitude: 8.8017)
    let route = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination]),
      actualDrivingDistance: Meters(120_000),
      expectedTravelTimeSeconds: 5_400
    )
    let clock = DirectionsRequestGateClock()
    let gate = DirectionsRequestGate(
      maximumRequests: 2,
      windowSeconds: 60,
      now: { clock.now },
      sleep: { seconds in clock.advance(by: seconds) }
    )
    let base = RoutePlannerStub(result: .success(route))
    let planner = RateLimitedRoutePlanner(base: base, gate: gate)

    _ = try await planner.automobileRoute(from: origin, to: destination)
    _ = try await planner.automobileRoute(from: origin, to: destination)
    _ = try await planner.automobileRoute(from: origin, to: destination)

    XCTAssertEqual(base.requestCount, 3)
    XCTAssertEqual(clock.sleepDurations, [60])
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
private final class CandidateSearcherStub: RideCandidateSearching {
  let result: Result<RideCandidateSearchOutcome, any Error>
  private(set) var preparedRides: [PreparedRideSearch] = []

  init(result: Result<RideCandidateSearchOutcome, any Error>) {
    self.result = result
  }

  func search(preparedRide: PreparedRideSearch) async throws -> RideCandidateSearchOutcome {
    preparedRides.append(preparedRide)
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

@MainActor
private final class DirectionsRequestGateClock {
  private(set) var now = Date(timeIntervalSince1970: 0)
  private(set) var sleepDurations: [TimeInterval] = []

  func advance(by seconds: TimeInterval) {
    sleepDurations.append(seconds)
    now = now.addingTimeInterval(seconds)
  }
}
