import MapKit
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class MapKitDrivingDistanceTests: XCTestCase {
  func testZeroDistanceIsValidForCandidateButNotForCorridorGeometry() async throws {
    let origin = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    let response = MapKitRouteFixture(distance: 0, coordinates: [origin, origin])
    let planner = MapKitRoutePlanner { request in
      XCTAssertEqual(request.transportType, .automobile)
      XCTAssertFalse(request.requestsAlternateRoutes)
      return response
    }

    let distance = try await planner.automobileDrivingDistance(from: origin, to: origin)
    XCTAssertEqual(distance, Meters(0))

    do {
      _ = try await planner.automobileRoute(from: origin, to: origin)
      XCTFail("A destination corridor still requires distinct route coordinates")
    } catch let error as RoutePlanningError {
      XCTAssertEqual(error, .invalidPolyline)
    }
  }

  func testShortCandidateDistanceUsesApplesValue() async throws {
    let origin = try Coordinate(latitude: 49.664170, longitude: 11.470730)
    let destination = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    let planner = MapKitRoutePlanner { _ in
      MapKitRouteFixture(distance: 1, coordinates: [origin, destination])
    }

    let distance = try await planner.automobileDrivingDistance(from: origin, to: destination)

    XCTAssertEqual(distance, Meters(1))
  }

  func testInvalidCandidateDistancesAreRejected() async throws {
    let origin = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    for invalidDistance in [-1.0, .nan, .infinity, Double(Int.max)] {
      let planner = MapKitRoutePlanner { _ in
        MapKitRouteFixture(distance: invalidDistance, coordinates: [origin, origin])
      }
      do {
        _ = try await planner.automobileDrivingDistance(from: origin, to: origin)
        XCTFail("An invalid Apple distance must not become a candidate distance")
      } catch let error as RoutePlanningError {
        XCTAssertEqual(error, .invalidDistance)
      }
    }
  }

  func testMissingRouteDoesNotBecomeZeroDistance() async throws {
    let origin = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    let planner = MapKitRoutePlanner { _ in nil }

    do {
      _ = try await planner.automobileDrivingDistance(from: origin, to: origin)
      XCTFail("A missing route remains unresolved, even at identical coordinates")
    } catch let error as RoutePlanningError {
      XCTAssertEqual(error, .noRoute)
    }
  }

  func testDistanceRetriesUseTheSameRequestGateAsTheMainRoute() async throws {
    let origin = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    let destination = try Coordinate(latitude: 51.337296, longitude: 12.3761666)
    var requests = 0
    var now = Date(timeIntervalSince1970: 0)
    var waits: [TimeInterval] = []
    let planner = RetryingRoutePlanner(
      base: RateLimitedRoutePlanner(
        base: MapKitRoutePlanner { _ in
          requests += 1
          switch requests {
          case 1:
            return MapKitRouteFixture(distance: 237_868, coordinates: [origin, destination])
          case 2:
            throw URLError(.timedOut)
          default:
            return MapKitRouteFixture(distance: 0, coordinates: [origin, origin])
          }
        },
        gate: DirectionsRequestGate(
          maximumRequests: 1,
          windowSeconds: 60,
          now: { now },
          sleep: { seconds in
            waits.append(seconds)
            now = now.addingTimeInterval(seconds)
          }
        )
      ),
      retryDelay: .zero
    )

    let route = try await planner.automobileRoute(from: origin, to: destination)
    let distance = try await planner.automobileDrivingDistance(from: origin, to: origin)

    XCTAssertEqual(route.actualDrivingDistance, Meters(237_868))
    XCTAssertEqual(distance, Meters(0))
    XCTAssertEqual(requests, 3)
    XCTAssertEqual(waits, [60, 60])
  }

  func testCandidateDistanceCancellationIsNotRetried() async throws {
    let origin = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    var requests = 0
    let planner = RetryingRoutePlanner(
      base: MapKitRoutePlanner { _ in
        requests += 1
        throw CancellationError()
      },
      retryDelay: .zero
    )

    do {
      _ = try await planner.automobileDrivingDistance(from: origin, to: origin)
      XCTFail("Cancellation must propagate")
    } catch is CancellationError {
      XCTAssertEqual(requests, 1)
    }
  }

  func testStartCampusIsFilteredByDistanceWithoutBlockingLaterResults() async throws {
    let origin = try Coordinate(latitude: 49.664160, longitude: 11.470720)
    let destination = try Coordinate(latitude: 51.337296, longitude: 12.3761666)
    let nextStop = try Coordinate(latitude: 50.5, longitude: 11.7)
    let startCandidate = try candidate(index: 1, coordinate: origin, lowerBound: 0)
    let laterCandidate = try candidate(index: 2, coordinate: nextStop, lowerBound: 95_000)
    let criteria = RideCriteria(
      distanceRange: .kilometers100To150,
      minimumChargingPoints: .eight,
      minimumPower: .twoHundred,
      foodChain: nil
    )
    let polyline = try RoutePolyline(coordinates: [origin, destination])
    let ride = PreparedRideSearch(
      origin: origin,
      route: PlannedRoute(
        polyline: polyline,
        actualDrivingDistance: Meters(237_868),
        expectedTravelTimeSeconds: 8_027
      ),
      request: RouteSearchRequest(requestID: UUID(), route: polyline, criteria: criteria)
    )
    var requests = 0
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: DistanceRegressionPageSearcher(candidates: [startCandidate, laterCandidate]),
      enricher: MapKitCandidateEnricher(
        distanceProvider: RetryingRoutePlanner(
          base: RateLimitedRoutePlanner(
            base: MapKitRoutePlanner { _ in
              requests += 1
              return requests == 1
                ? MapKitRouteFixture(distance: 0, coordinates: [origin, origin])
                : MapKitRouteFixture(distance: 119_000, coordinates: [origin, nextStop])
            },
            gate: DirectionsRequestGate()
          ),
          retryDelay: .zero
        )
      ),
      enrichmentBatchSize: 1
    )

    let outcome = try await coordinator.search(preparedRide: ride)

    XCTAssertEqual(outcome.results.map(\.id), [laterCandidate.id])
    XCTAssertEqual(outcome.results.first?.candidate.actualDrivingDistance, Meters(119_000))
    XCTAssertEqual(outcome.results.first?.chargingPointCount, 10)
    XCTAssertEqual(requests, 2)

    _ = try await coordinator.search(preparedRide: ride)
    XCTAssertEqual(requests, 2, "Both zero and positive successful distances remain cached")
  }

  private func candidate(index: Int, coordinate: Coordinate, lowerBound: Int) throws
    -> BackendCandidate
  {
    let source = try DataSourceReference(
      sourceID: "regression-fixture",
      sourceRecordID: "\(index)",
      qualityTier: .authority,
      observedAt: Date(timeIntervalSince1970: 0),
      fetchedAt: Date(timeIntervalSince1970: 0)
    )
    return BackendCandidate(
      park: try ChargingPark(
        id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index))!,
        name: "Campus \(index)",
        coordinate: coordinate,
        navigationCoordinate: coordinate,
        operatorChargingPoints: [
          try OperatorChargingPointSummary(name: "Operator", chargingPointCount: 10)
        ],
        chargingPointCount: 10,
        availability: ParkAvailability(
          knownAvailableCount: 0, knownUnavailableCount: 0, unknownCount: 10, totalCount: 10
        ),
        maximumPower: Kilowatts(300),
        sourceReferences: [source]
      ),
      distanceFromRoute: Meters(0),
      straightLineLowerBound: Meters(lowerBound),
      foodPOIs: []
    )
  }
}

private final class MapKitRouteFixture: MKRoute {
  private let meters: CLLocationDistance
  private let geometry: MKPolyline

  init(distance: CLLocationDistance, coordinates: [Coordinate]) {
    meters = distance
    let points = coordinates.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    geometry = MKPolyline(coordinates: points, count: points.count)
    super.init()
  }

  override var distance: CLLocationDistance { meters }
  override var expectedTravelTime: TimeInterval { 0 }
  override var polyline: MKPolyline { geometry }
}

@MainActor
private final class DistanceRegressionPageSearcher: CandidatePageSearching {
  private let candidates: [BackendCandidate]

  init(candidates: [BackendCandidate]) {
    self.candidates = candidates
  }

  func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
    CandidateSearchPage(
      snapshotToken: "regression-snapshot",
      nextCursor: nil,
      candidates: candidates,
      coverage: CandidateSearchCoverage(
        status: .complete,
        activeSourceIDs: ["regression-fixture"],
        unavailableSourceIDs: [],
        projectionUpdatedAt: Date(timeIntervalSince1970: 0)
      )
    )
  }
}
