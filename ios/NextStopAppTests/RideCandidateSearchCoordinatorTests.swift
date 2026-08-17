import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class RideCandidateSearchCoordinatorTests: XCTestCase {
  func testStopsEnrichmentAsSoonAsTheRemainingLowerBoundsCannotBeatTheTopFive() async throws {
    let lowerBounds = [10, 15, 20, 25, 30, 35, 40, 45] + Array(stride(from: 60, to: 84, by: 2))
    let candidates = try lowerBounds.enumerated().map { offset, lowerBound in
      try makeBackendCandidate(
        index: offset + 1,
        lowerBoundKilometers: lowerBound
      )
    }
    let enricher = CandidateEnricherStub(
      distances: Dictionary(
        uniqueKeysWithValues: zip(candidates, lowerBounds).enumerated().map {
          offset, pair in
          (pair.0.id, Meters(max(offset + 51, pair.1) * 1_000))
        }
      )
    )
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: "unused-next-page",
          candidates: candidates,
          coverage: coverage
        )
      ]),
      enricher: enricher,
      enrichmentBatchSize: 4
    )

    let outcome = try await coordinator.search(
      preparedRide: try preparedRide(distanceRange: .kilometers50To100)
    )

    XCTAssertEqual(
      outcome.results.map(\.candidate.actualDrivingDistance.value),
      [51_000, 52_000, 53_000, 54_000, 55_000]
    )
    XCTAssertEqual(enricher.requestedIDs.count, 8)
  }

  func testUsesExactDrivingDistanceForFilteringRankingAndMaximumFive() async throws {
    let candidates = try (1...6).map { index in
      try makeBackendCandidate(index: index, lowerBoundKilometers: index * 10)
    }
    let distances = [78, 112, 124, 139, 145, 147]
    let enricher = CandidateEnricherStub(
      distances: Dictionary(
        uniqueKeysWithValues: zip(candidates.map(\.id), distances.map { Meters($0 * 1_000) })
      )
    )
    let pageSearcher = CandidatePageSearcherStub(pages: [
      CandidateSearchPage(
        snapshotToken: "snapshot",
        nextCursor: nil,
        candidates: candidates,
        coverage: coverage
      )
    ])
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: pageSearcher,
      enricher: enricher,
      enrichmentBatchSize: 2
    )

    let outcome = try await coordinator.search(
      preparedRide: try preparedRide(distanceRange: .kilometers100To150)
    )

    XCTAssertEqual(
      outcome.results.map(\.candidate.actualDrivingDistance.value),
      [112_000, 124_000, 139_000, 145_000, 147_000]
    )
  }

  func testContinuesWithTheSignedSnapshotUntilExhausted() async throws {
    let first = try makeBackendCandidate(index: 1, lowerBoundKilometers: 40)
    let second = try makeBackendCandidate(index: 2, lowerBoundKilometers: 50)
    let pageSearcher = CandidatePageSearcherStub(pages: [
      CandidateSearchPage(
        snapshotToken: "snapshot",
        nextCursor: "cursor-1",
        candidates: [first],
        coverage: coverage
      ),
      CandidateSearchPage(
        snapshotToken: "snapshot",
        nextCursor: nil,
        candidates: [second],
        coverage: coverage
      ),
    ])
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: pageSearcher,
      enricher: CandidateEnricherStub(
        distances: [first.id: Meters(60_000), second.id: Meters(70_000)]
      )
    )

    let outcome = try await coordinator.search(
      preparedRide: try preparedRide(distanceRange: .kilometers50To100)
    )

    XCTAssertEqual(outcome.results.map(\.candidate.actualDrivingDistance.value), [60_000, 70_000])
    XCTAssertEqual(pageSearcher.requests.count, 2)
    XCTAssertEqual(pageSearcher.requests[1].snapshotToken, "snapshot")
    XCTAssertEqual(pageSearcher.requests[1].cursor, "cursor-1")
  }

  func testRestartsOnceFromTheFirstPageWhenSnapshotExpires() async throws {
    let staleCandidate = try makeBackendCandidate(index: 1, lowerBoundKilometers: 40)
    let freshCandidate = try makeBackendCandidate(index: 2, lowerBoundKilometers: 50)
    let pageSearcher = CandidatePageSearcherStub(responses: [
      .success(
        CandidateSearchPage(
          snapshotToken: "stale-snapshot",
          nextCursor: "stale-cursor",
          candidates: [staleCandidate],
          coverage: coverage
        )
      ),
      .failure(.snapshotExpired),
      .success(
        CandidateSearchPage(
          snapshotToken: "fresh-snapshot",
          nextCursor: nil,
          candidates: [freshCandidate],
          coverage: coverage
        )
      ),
    ])
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: pageSearcher,
      enricher: CandidateEnricherStub(
        distances: [
          staleCandidate.id: Meters(60_000),
          freshCandidate.id: Meters(70_000),
        ]
      )
    )

    let outcome = try await coordinator.search(
      preparedRide: try preparedRide(distanceRange: .kilometers50To100)
    )

    XCTAssertEqual(outcome.results.map(\.id), [freshCandidate.id])
    XCTAssertEqual(pageSearcher.requests.count, 3)
    XCTAssertEqual(pageSearcher.requests[1].snapshotToken, "stale-snapshot")
    XCTAssertEqual(pageSearcher.requests[1].cursor, "stale-cursor")
    XCTAssertNil(pageSearcher.requests[2].snapshotToken)
    XCTAssertNil(pageSearcher.requests[2].cursor)
  }

  func testDoesNotClaimNoMatchesWhenAnUnresolvedRouteCouldStillQualify() async throws {
    let candidate = try makeBackendCandidate(index: 1, lowerBoundKilometers: 50)
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: nil,
          candidates: [candidate],
          coverage: coverage
        )
      ]),
      enricher: CandidateEnricherStub(distances: [:], failedIDs: [candidate.id])
    )

    do {
      _ = try await coordinator.search(
        preparedRide: try preparedRide(distanceRange: .kilometers50To100)
      )
      XCTFail("Expected an unresolved driving-distance error")
    } catch let error as RideCandidateSearchError {
      XCTAssertEqual(error, .drivingDistancesUnavailable)
    }
  }

  func testCanIgnoreARouteFailureOnlyWhenItsLowerBoundIsPastTheFifthResult() async throws {
    let candidates = try (1...6).map { index in
      try makeBackendCandidate(
        index: index,
        lowerBoundKilometers: index == 6 ? 95 : index * 10
      )
    }
    let successful = Array(candidates.prefix(5))
    let distances = [50, 60, 70, 80, 90]
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: nil,
          candidates: candidates,
          coverage: coverage
        )
      ]),
      enricher: CandidateEnricherStub(
        distances: Dictionary(
          uniqueKeysWithValues: zip(
            successful.map(\.id),
            distances.map { Meters($0 * 1_000) }
          )
        ),
        failedIDs: [try XCTUnwrap(candidates.last).id]
      )
    )

    let outcome = try await coordinator.search(
      preparedRide: try preparedRide(distanceRange: .kilometers50To100)
    )

    XCTAssertEqual(
      outcome.results.map(\.candidate.actualDrivingDistance.value),
      distances.map { $0 * 1_000 }
    )
  }

  func testRejectsChangedSnapshotAcrossPages() async throws {
    let first = try makeBackendCandidate(index: 1, lowerBoundKilometers: 40)
    let second = try makeBackendCandidate(index: 2, lowerBoundKilometers: 50)
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot-a",
          nextCursor: "cursor-1",
          candidates: [first],
          coverage: coverage
        ),
        CandidateSearchPage(
          snapshotToken: "snapshot-b",
          nextCursor: nil,
          candidates: [second],
          coverage: coverage
        ),
      ]),
      enricher: CandidateEnricherStub(
        distances: [first.id: Meters(60_000), second.id: Meters(70_000)]
      )
    )

    await assertInvalidResponse(from: coordinator)
  }

  func testRejectsSafeLowerBoundRegressionAcrossPages() async throws {
    let first = try makeBackendCandidate(index: 1, lowerBoundKilometers: 50)
    let second = try makeBackendCandidate(index: 2, lowerBoundKilometers: 40)
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: "cursor-1",
          candidates: [first],
          coverage: coverage
        ),
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: nil,
          candidates: [second],
          coverage: coverage
        ),
      ]),
      enricher: CandidateEnricherStub(
        distances: [first.id: Meters(60_000), second.id: Meters(70_000)]
      )
    )

    await assertInvalidResponse(from: coordinator)
  }

  func testRejectsEmptyPageThatClaimsAnotherCursor() async throws {
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: "cursor-1",
          candidates: [],
          coverage: coverage
        )
      ]),
      enricher: CandidateEnricherStub(distances: [:])
    )

    await assertInvalidResponse(from: coordinator)
  }

  private func assertInvalidResponse(from coordinator: RideCandidateSearchCoordinator) async {
    do {
      _ = try await coordinator.search(
        preparedRide: try preparedRide(distanceRange: .kilometers50To100)
      )
      XCTFail("Expected an invalid candidate response")
    } catch let error as RideCandidateSearchError {
      XCTAssertEqual(error, .candidateResponseInvalid)
    } catch {
      XCTFail("Expected an invalid candidate response, got \(error)")
    }
  }

  private var coverage: CandidateSearchCoverage {
    CandidateSearchCoverage(
      status: .complete,
      activeSourceIDs: ["bundesnetzagentur_ladesaeulenregister"],
      unavailableSourceIDs: [],
      projectionUpdatedAt: Date(timeIntervalSince1970: 0)
    )
  }

  private func preparedRide(distanceRange: DistanceRangeOption) throws -> PreparedRideSearch {
    let origin = try Coordinate(latitude: 52, longitude: 10)
    let destination = try Coordinate(latitude: 53, longitude: 11)
    let criteria = RideCriteria(
      distanceRange: distanceRange,
      minimumChargingPoints: .four,
      minimumPower: .oneHundred,
      foodChain: nil
    )
    let polyline = try RoutePolyline(coordinates: [origin, destination])
    return PreparedRideSearch(
      origin: origin,
      route: PlannedRoute(
        polyline: polyline,
        actualDrivingDistance: Meters(150_000),
        expectedTravelTimeSeconds: 7_200
      ),
      request: RouteSearchRequest(
        requestID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
        route: polyline,
        criteria: criteria
      )
    )
  }

  private func makeBackendCandidate(
    index: Int,
    lowerBoundKilometers: Int
  ) throws -> BackendCandidate {
    let id = UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index))!
    let coordinate = try Coordinate(latitude: 52, longitude: 10 + Double(index) / 100)
    let source = try DataSourceReference(
      sourceID: "bundesnetzagentur",
      sourceRecordID: "\(index)",
      qualityTier: .authority,
      observedAt: Date(timeIntervalSince1970: 0),
      fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let park = try ChargingPark(
      id: id,
      name: "Park \(index)",
      coordinate: coordinate,
      navigationCoordinate: coordinate,
      operatorChargingPoints: [
        try OperatorChargingPointSummary(name: "Operator", chargingPointCount: 4)
      ],
      chargingPointCount: 4,
      availability: ParkAvailability(
        knownAvailableCount: 0,
        knownUnavailableCount: 0,
        unknownCount: 4,
        totalCount: 4
      ),
      maximumPower: Kilowatts(150),
      sourceReferences: [source]
    )
    return BackendCandidate(
      park: park,
      distanceFromRoute: Meters(1_000),
      straightLineLowerBound: Meters(lowerBoundKilometers * 1_000)
    )
  }
}

@MainActor
private final class CandidatePageSearcherStub: CandidatePageSearching {
  private var responses: [Result<CandidateSearchPage, CandidateSearchServiceError>]
  private(set) var requests: [RouteSearchRequest] = []

  init(pages: [CandidateSearchPage]) {
    responses = pages.map { .success($0) }
  }

  init(responses: [Result<CandidateSearchPage, CandidateSearchServiceError>]) {
    self.responses = responses
  }

  func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
    requests.append(request)
    guard !responses.isEmpty else {
      throw CandidateSearchServiceError.invalidResponse
    }
    return try responses.removeFirst().get()
  }
}

@MainActor
private final class CandidateEnricherStub: CandidateEnriching {
  let distances: [UUID: Meters]
  let failedIDs: Set<UUID>
  private(set) var requestedIDs: [UUID] = []

  init(distances: [UUID: Meters], failedIDs: Set<UUID> = []) {
    self.distances = distances
    self.failedIDs = failedIDs
  }

  func enrich(
    candidate: BackendCandidate,
    origin: Coordinate,
    criteria: RideCriteria
  ) async throws -> EnrichedChargingParkCandidate {
    _ = origin
    _ = criteria
    requestedIDs.append(candidate.id)
    if failedIDs.contains(candidate.id) {
      throw CandidateEnrichmentError.drivingRouteUnavailable
    }
    guard let distance = distances[candidate.id] else {
      throw CandidateEnrichmentError.drivingRouteUnavailable
    }
    return EnrichedChargingParkCandidate(
      park: candidate.park,
      distanceFromRoute: candidate.distanceFromRoute,
      actualDrivingDistance: distance,
      foodPOIs: []
    )
  }
}
