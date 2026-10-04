import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class RideCandidateSearchCoordinatorTests: XCTestCase {
  func testAvailabilityContextIsRetainedWithoutDoingLiveWorkDuringSearch() async throws {
    let candidate = try makeBackendCandidate(index: 1, lowerBoundKilometers: 30)
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot", nextCursor: nil,
          candidates: [candidate], coverage: coverage, availabilityContext: "live-context")
      ]),
      enricher: CandidateEnricherStub(distances: [candidate.id: Meters(60_000)]),
      resultChecker: ChargingResultCheckerStub()
    )
    let outcome = try await coordinator.search(
      preparedRide: preparedRide(distanceRange: .kilometers50To100))
    XCTAssertEqual(outcome.availabilityContext, "live-context")
    XCTAssertEqual(outcome.results.map(\.id), [candidate.id])
  }

  func testAvailabilityContextCannotChangeAcrossSnapshotPages() async throws {
    let first = try makeBackendCandidate(index: 1, lowerBoundKilometers: 20)
    let second = try makeBackendCandidate(index: 2, lowerBoundKilometers: 30)
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot", nextCursor: "next",
          candidates: [first], coverage: coverage, availabilityContext: "first-context"),
        CandidateSearchPage(
          snapshotToken: "snapshot", nextCursor: nil,
          candidates: [second], coverage: coverage, availabilityContext: "changed-context"),
      ]),
      enricher: CandidateEnricherStub(distances: [
        first.id: Meters(60_000), second.id: Meters(70_000),
      ]),
      resultChecker: ChargingResultCheckerStub()
    )
    await assertInvalidResponse(from: coordinator)
  }

  func testMissingAppleOperatorDoesNotConsumeAResultSlotOrStopPagination() async throws {
    let candidates = try (1...7).map {
      try makeBackendCandidate(index: $0, lowerBoundKilometers: $0 * 5)
    }
    let pages = CandidatePageSearcherStub(pages: [
      CandidateSearchPage(
        snapshotToken: "snapshot", nextCursor: "next",
        candidates: Array(candidates.prefix(5)), coverage: coverage),
      CandidateSearchPage(
        snapshotToken: "snapshot", nextCursor: nil,
        candidates: Array(candidates.suffix(2)), coverage: coverage),
    ])
    let checker = ChargingResultCheckerStub { result in
      result.id == candidates[0].id ? [] : Set(result.operatorChargingPoints.map(\.name))
    }
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: pages,
      enricher: CandidateEnricherStub(
        distances: Dictionary(
          uniqueKeysWithValues:
            candidates.enumerated().map { ($0.element.id, Meters(51_000 + $0.offset * 1_000)) })),
      resultChecker: checker
    )
    let outcome = try await coordinator.search(
      preparedRide: preparedRide(distanceRange: .kilometers50To100))
    XCTAssertEqual(outcome.results.map(\.id), Array(candidates[1...5]).map(\.id))
    XCTAssertEqual(pages.requests.count, 2)
    XCTAssertEqual(checker.checkedResults.filter { $0.id == candidates[0].id }.count, 1)
    XCTAssertFalse(checker.checkedResults.contains { $0.id == candidates[6].id })
  }

  func testAppleLookupFailureIsNotAnEmptyResultAndCancellationPropagates() async throws {
    let candidate = try makeBackendCandidate(index: 1, lowerBoundKilometers: 40)
    for error in [URLError(.notConnectedToInternet) as Error, CancellationError()] {
      let coordinator = RideCandidateSearchCoordinator(
        pageSearcher: CandidatePageSearcherStub(pages: [
          CandidateSearchPage(
            snapshotToken: "snapshot", nextCursor: nil,
            candidates: [candidate], coverage: coverage)
        ]),
        enricher: CandidateEnricherStub(distances: [candidate.id: Meters(60_000)]),
        resultChecker: ChargingResultCheckerStub { _ in throw error }
      )
      do {
        _ = try await coordinator.search(
          preparedRide: preparedRide(distanceRange: .kilometers50To100))
        XCTFail("An incomplete Apple lookup must not become a no-match")
      } catch is CancellationError {
        XCTAssertTrue(error is CancellationError)
      } catch let actual as RideCandidateSearchError {
        XCTAssertFalse(error is CancellationError)
        XCTAssertEqual(actual, .applePlacesUnavailable)
      }
    }
  }

  func testRestaurantAppleCheckWaitsForGroupEvidenceFromLaterPages() async throws {
    let first = try makeBackendCandidate(index: 1, lowerBoundKilometers: 20, foodPOIID: "food")
    let later = try makeBackendCandidate(index: 2, lowerBoundKilometers: 30, foodPOIID: "food")
    let checker = ChargingResultCheckerStub { result in
      result.candidates.count == 2 ? Set(result.operatorChargingPoints.map(\.name)) : []
    }
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot", nextCursor: "next",
          candidates: [first], coverage: coverage),
        CandidateSearchPage(
          snapshotToken: "snapshot", nextCursor: nil,
          candidates: [later], coverage: coverage),
      ]),
      enricher: CandidateEnricherStub(distances: [
        first.id: Meters(60_000), later.id: Meters(70_000),
      ]),
      resultChecker: checker
    )
    let outcome = try await coordinator.search(
      preparedRide: preparedRide(
        distanceRange: .kilometers50To100, foodChain: .mcdonalds))
    XCTAssertEqual(checker.checkedResults.count, 1)
    XCTAssertEqual(outcome.results.first?.chargingPointCount, 8)
  }

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
      resultChecker: ChargingResultCheckerStub(),
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
      resultChecker: ChargingResultCheckerStub(),
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

  func testFoodSearchScansRemainingCandidatesAndCompletesTopRestaurantGroups() async throws {
    let restaurantIDs = [
      "restaurant-a", "restaurant-b", "restaurant-c", "restaurant-d", "restaurant-e",
      "restaurant-f", "restaurant-g", "restaurant-h", "restaurant-a", "restaurant-i",
    ]
    let candidates = try restaurantIDs.enumerated().map { offset, restaurantID in
      try makeBackendCandidate(
        index: offset + 1,
        lowerBoundKilometers: (offset + 1) * 10,
        foodPOIID: restaurantID
      )
    }
    let enricher = CandidateEnricherStub(
      distances: Dictionary(
        uniqueKeysWithValues: candidates.enumerated().map { offset, candidate in
          (candidate.id, Meters((offset + 51) * 1_000))
        }
      )
    )
    let coordinator = RideCandidateSearchCoordinator(
      pageSearcher: CandidatePageSearcherStub(pages: [
        CandidateSearchPage(
          snapshotToken: "snapshot",
          nextCursor: nil,
          candidates: candidates,
          coverage: coverage
        )
      ]),
      enricher: enricher,
      resultChecker: ChargingResultCheckerStub(),
      enrichmentBatchSize: 4
    )

    let outcome = try await coordinator.search(
      preparedRide: try preparedRide(
        distanceRange: .kilometers50To100,
        foodChain: .mcdonalds
      )
    )

    XCTAssertEqual(enricher.requestedIDs.count, 10)
    XCTAssertTrue(enricher.requestedIDs.contains(candidates[9].id))
    XCTAssertEqual(outcome.results.count, 5)
    XCTAssertEqual(outcome.results.first?.matchingFoodPOI?.id, "restaurant-a")
    XCTAssertEqual(outcome.results.first?.candidates.count, 2)
    XCTAssertEqual(outcome.results.first?.chargingPointCount, 8)
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
      ),
      resultChecker: ChargingResultCheckerStub()
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
      ),
      resultChecker: ChargingResultCheckerStub()
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
      enricher: CandidateEnricherStub(distances: [:], failedIDs: [candidate.id]),
      resultChecker: ChargingResultCheckerStub()
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
      ),
      resultChecker: ChargingResultCheckerStub()
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
      ),
      resultChecker: ChargingResultCheckerStub()
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
      ),
      resultChecker: ChargingResultCheckerStub()
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
      enricher: CandidateEnricherStub(distances: [:]),
      resultChecker: ChargingResultCheckerStub()
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

  private func preparedRide(
    distanceRange: DistanceRangeOption,
    foodChain: FoodChain? = nil
  ) throws -> PreparedRideSearch {
    let origin = try Coordinate(latitude: 52, longitude: 10)
    let destination = try Coordinate(latitude: 53, longitude: 11)
    let criteria = RideCriteria(
      distanceRange: distanceRange,
      minimumChargingPoints: .four,
      minimumPower: .oneHundred,
      foodChain: foodChain
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
    lowerBoundKilometers: Int,
    foodPOIID: String? = nil
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
    let foodPOIs: [FoodPOI]
    if let foodPOIID {
      foodPOIs = [
        try FoodPOI(
          id: foodPOIID,
          chain: .mcdonalds,
          name: "McDonald's",
          coordinate: coordinate,
          distanceFromPark: Meters(100),
          openingStatus: .unknown
        )
      ]
    } else {
      foodPOIs = []
    }
    return BackendCandidate(
      park: park,
      distanceFromRoute: Meters(1_000),
      straightLineLowerBound: Meters(lowerBoundKilometers * 1_000),
      foodPOIs: foodPOIs
    )
  }
}

@MainActor
final class ChargingResultCheckerStub: ChargingResultChecking {
  let check: (RouteSearchResult) throws -> Set<String>
  private(set) var checkedResults: [RouteSearchResult] = []

  init(
    check: @escaping (RouteSearchResult) throws -> Set<String> = {
      Set($0.operatorChargingPoints.map(\.name))
    }
  ) {
    self.check = check
  }

  func beginSearch() { checkedResults = [] }

  func confirmedOperatorNames(in result: RouteSearchResult) async throws -> Set<String> {
    checkedResults.append(result)
    return try check(result)
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
      foodPOIs: criteria.foodChain == nil ? [] : candidate.foodPOIs
    )
  }
}
