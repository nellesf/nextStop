import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class ChargingAvailabilityTests: XCTestCase {
  func testRestaurantRefreshUsesOnlySurvivingMembersAndAggregatesTheirConfirmedEVSEs() async throws
  {
    let first = try Fixture()
    let second = try Fixture()
    let removed = try Fixture()
    let result = RouteSearchResult(
      candidate: first.result.candidate, relatedCandidates: [second.result.candidate],
      matchingFoodPOI: try FoodPOI(
        id: "synthetic-food", chain: .mcdonalds, name: "Synthetic restaurant",
        coordinate: Coordinate(latitude: 52, longitude: 10), distanceFromPark: Meters(100),
        openingStatus: .unknown),
      eligibleOperatorNames: ["Confirmed"],
      placeLookupCandidates: [
        removed.result.candidate, first.result.candidate, second.result.candidate,
      ]
    )
    let fetcher = Fetcher { _, selections in
      XCTAssertEqual(Set(selections.map(\.id)), [first.result.id, second.result.id])
      XCTAssertFalse(selections.contains { $0.id == removed.result.id })
      return ChargingAvailabilityBatch(
        generatedAt: first.now, contextExpiresAt: first.now.addingTimeInterval(3_600),
        refreshPending: false, retryAfterSeconds: nil,
        candidates: try Dictionary(
          uniqueKeysWithValues: selections.map {
            (
              $0.id,
              try ParkAvailability(
                knownAvailableCount: 1, knownUnavailableCount: 0, unknownCount: 3,
                totalCount: 4, lastLiveObservationAt: first.now)
            )
          })
      )
    }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { first.now })
    defer { controller.cancel() }
    await controller.refresh(
      RideCandidateSearchOutcome(
        results: [result], coverage: first.outcome().coverage, availabilityContext: "context"))
    XCTAssertEqual(controller.availability(for: result, onDemand: true).knownAvailableCount, 2)
    XCTAssertEqual(controller.availability(for: result, onDemand: true).unknownCount, 6)
    XCTAssertEqual(result.chargingPointCount, 8)
    XCTAssertEqual(result.placeLookupCandidates.count, 3)
  }

  func testLargeRestaurantGroupUsesSequentialBatchesOfAtMostFifty() async throws {
    let fixtures = try (0..<51).map { _ in try Fixture() }
    let first = try XCTUnwrap(fixtures.first)
    let result = RouteSearchResult(
      candidate: first.result.candidate,
      relatedCandidates: fixtures.dropFirst().map(\.result.candidate),
      matchingFoodPOI: try FoodPOI(
        id: "synthetic-food", chain: .mcdonalds, name: "Synthetic restaurant",
        coordinate: Coordinate(latitude: 52, longitude: 10), distanceFromPark: Meters(100),
        openingStatus: .unknown),
      eligibleOperatorNames: ["Confirmed"]
    )
    let fetcher = Fetcher { _, selections in
      ChargingAvailabilityBatch(
        generatedAt: first.now, contextExpiresAt: first.now.addingTimeInterval(3_600),
        refreshPending: false, retryAfterSeconds: nil,
        candidates: try Dictionary(
          uniqueKeysWithValues: selections.map {
            (
              $0.id,
              try ParkAvailability(
                knownAvailableCount: 0, knownUnavailableCount: 0, unknownCount: 4, totalCount: 4)
            )
          })
      )
    }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { first.now })
    await controller.refresh(
      RideCandidateSearchOutcome(
        results: [result], coverage: first.outcome().coverage, availabilityContext: "context"))
    XCTAssertEqual(fetcher.requests.map(\.count), [50, 1])
    XCTAssertEqual(controller.availability(for: result, onDemand: true).unknownCount, 204)
  }

  func testLegacyOutcomeNeverRequestsLiveData() async throws {
    let fixture = try Fixture()
    let fetcher = Fetcher { _, _ in throw ChargingAvailabilityError.unavailable }
    let controller = RideAvailabilityController(fetcher: fetcher)
    await controller.refresh(fixture.outcome(context: nil))
    XCTAssertTrue(fetcher.requests.isEmpty)
    XCTAssertEqual(
      controller.availability(for: fixture.result, onDemand: false), fixture.result.availability)
  }

  func testOperatorPrunedCountsAndOriginalEvidenceAreUntouchedByLiveOverlay() async throws {
    let fixture = try Fixture()
    let original = fixture.result
    let fetcher = Fetcher { _, selections in
      XCTAssertEqual(selections.map(\.operatorNames), [["Confirmed"]])
      XCTAssertEqual(selections.map(\.expectedChargingPoints), [4])
      return try fixture.batch(available: 2)
    }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { fixture.now })
    defer { controller.cancel() }
    XCTAssertEqual(controller.availability(for: original, onDemand: true).unknownCount, 4)
    await controller.refresh(fixture.outcome())
    let live = controller.availability(for: original, onDemand: true)
    XCTAssertEqual(live.knownAvailableCount, 2)
    XCTAssertEqual(live.unknownCount, 2)
    XCTAssertEqual(live.totalCount, 4)
    XCTAssertEqual(fixture.result, original)
    XCTAssertEqual(original.candidate.park.chargingPointCount, 6)
    XCTAssertEqual(original.candidate.actualDrivingDistance, Meters(60_000))
    XCTAssertEqual(original.placeLookupCandidates, [original.candidate])
  }

  func testReturningToActiveRestartsLiveRefreshWithoutChangingTheSearch() async throws {
    let fixture = try Fixture()
    let outcome = fixture.outcome()
    let active = RideAvailabilityRefreshIdentity(outcome: outcome, isActive: true)
    let inactive = RideAvailabilityRefreshIdentity(outcome: outcome, isActive: false)
    XCTAssertNotEqual(active, inactive)
    XCTAssertEqual(active, RideAvailabilityRefreshIdentity(outcome: outcome, isActive: true))
    XCTAssertNotEqual(
      active, RideAvailabilityRefreshIdentity(outcome: try Fixture().outcome(), isActive: true))
    let fetcher = Fetcher { _, _ in try fixture.batch(available: 4) }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { fixture.now })
    defer { controller.cancel() }
    await controller.refresh(outcome, isActive: active.isActive)
    XCTAssertEqual(fetcher.requests.count, 1)
    await controller.refresh(outcome, isActive: inactive.isActive)
    XCTAssertEqual(fetcher.requests.count, 1)
    XCTAssertEqual(controller.availability(for: fixture.result, onDemand: true).unknownCount, 4)
    await controller.refresh(outcome, isActive: active.isActive)
    XCTAssertEqual(fetcher.requests.count, 2)
    XCTAssertEqual(
      controller.availability(for: fixture.result, onDemand: true).knownAvailableCount, 4)
    let cancelledInactiveTask = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await controller.refresh(outcome, isActive: false)
    }
    await cancelledInactiveTask.value
    XCTAssertEqual(
      controller.availability(for: fixture.result, onDemand: true).knownAvailableCount, 4)
  }

  func testInconsistentLiveAggregationFallsBackToUnknownInsteadOfOriginalKnownCounts() async throws
  {
    let fixture = try Fixture()
    let original = fixture.result.candidate.park
    let known = try ParkAvailability(
      knownAvailableCount: 6, knownUnavailableCount: 0,
      unknownCount: 0, totalCount: 6, lastLiveObservationAt: fixture.now)
    let park = try ChargingPark(
      id: original.id, name: original.name,
      coordinate: original.coordinate, navigationCoordinate: original.navigationCoordinate,
      operatorChargingPoints: original.operatorChargingPoints, chargingPointCount: 6,
      availability: known, maximumPower: original.maximumPower, sourceReferences: [])
    let result = RouteSearchResult(
      candidate: EnrichedChargingParkCandidate(
        park: park, distanceFromRoute: fixture.result.candidate.distanceFromRoute,
        actualDrivingDistance: fixture.result.candidate.actualDrivingDistance, foodPOIs: []),
      matchingFoodPOI: nil)
    // A protocol implementation can decode invalid synthesized-Codable values without the domain initializer.
    var malformed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
    malformed["unknownCount"] = 2
    let invalid = try JSONDecoder().decode(
      ParkAvailability.self,
      from: JSONSerialization.data(withJSONObject: malformed))
    let fetcher = Fetcher { _, _ in
      ChargingAvailabilityBatch(
        generatedAt: fixture.now,
        contextExpiresAt: fixture.now.addingTimeInterval(3_600), refreshPending: false,
        retryAfterSeconds: nil, candidates: [result.id: invalid])
    }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { fixture.now })
    defer { controller.cancel() }
    await controller.refresh(
      RideCandidateSearchOutcome(
        results: [result],
        coverage: fixture.outcome().coverage, availabilityContext: "context"))
    XCTAssertEqual(result.availability.knownAvailableCount, 6)
    let overlay = controller.availability(for: result, onDemand: true)
    XCTAssertEqual(overlay.knownAvailableCount, 0)
    XCTAssertEqual(overlay.unknownCount, 6)
    XCTAssertEqual(overlay.totalCount, 6)
  }

  func testPendingRefreshGetsThreeBoundedTenSecondFollowupsAndCanFinishLate() async throws {
    let fixture = try Fixture()
    var requests = 0
    var delays: [TimeInterval] = []
    let fetcher = Fetcher { _, _ in
      requests += 1
      return try fixture.batch(available: requests == 4 ? 3 : 0, pending: requests < 4)
    }
    let controller = RideAvailabilityController(
      fetcher: fetcher, now: { fixture.now },
      sleep: { seconds in
        if seconds >= 300 {
          try await Task.sleep(for: .seconds(3_600))
          return
        }
        delays.append(seconds)
      })
    defer { controller.cancel() }
    await controller.refresh(fixture.outcome())
    XCTAssertEqual(requests, 4)
    XCTAssertEqual(delays, [10, 10, 10])
    XCTAssertEqual(
      controller.availability(for: fixture.result, onDemand: true).knownAvailableCount, 3)
  }

  func testContinuouslyPendingRefreshStopsAndKeepsUnknownResults() async throws {
    let fixture = try Fixture()
    let fetcher = Fetcher { _, _ in try fixture.batch(available: 0, pending: true) }
    let controller = RideAvailabilityController(
      fetcher: fetcher, now: { fixture.now }, sleep: { _ in })
    await controller.refresh(fixture.outcome())
    XCTAssertEqual(fetcher.requests.count, 4)
    XCTAssertEqual(controller.availability(for: fixture.result, onDemand: true).unknownCount, 4)
    controller.cancel()
  }

  func testOldSearchCompletionCannotPublishAfterCancellation() async throws {
    let fixture = try Fixture()
    var continuation: CheckedContinuation<ChargingAvailabilityBatch, Error>?
    let fetcher = Fetcher { _, _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { fixture.now })
    let pending = Task { await controller.refresh(fixture.outcome()) }
    while continuation == nil { await Task.yield() }
    controller.cancel()
    continuation?.resume(returning: try fixture.batch(available: 4))
    await pending.value
    XCTAssertTrue(controller.values.isEmpty)
    XCTAssertEqual(controller.availability(for: fixture.result, onDemand: true).unknownCount, 4)
  }

  func testLiveValuesExpireLocallyWithoutAnotherRequest() async throws {
    let fixture = try Fixture()
    var now = fixture.now
    let fetcher = Fetcher { _, _ in try fixture.batch(available: 4) }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { now })
    defer { controller.cancel() }
    await controller.refresh(fixture.outcome())
    XCTAssertEqual(
      controller.availability(for: fixture.result, onDemand: true).knownAvailableCount, 4)
    now = now.addingTimeInterval(300)
    XCTAssertEqual(controller.availability(for: fixture.result, onDemand: true).unknownCount, 4)
    XCTAssertEqual(fetcher.requests.count, 1)
  }

  func testAlreadyCancelledScreenTaskCannotResetCurrentLiveOverlay() async throws {
    let fixture = try Fixture()
    let fetcher = Fetcher { _, _ in try fixture.batch(available: 4) }
    let controller = RideAvailabilityController(fetcher: fetcher, now: { fixture.now })
    defer { controller.cancel() }
    await controller.refresh(fixture.outcome())
    let stale = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await controller.refresh(fixture.outcome())
    }
    await stale.value
    XCTAssertEqual(fetcher.requests.count, 1)
    XCTAssertEqual(
      controller.availability(for: fixture.result, onDemand: true).knownAvailableCount, 4)
  }

  func testUnavailableAndWrongUnitCountsNeverChangeSearchResult() async throws {
    let fixture = try Fixture()
    for invalidCounts in [false, true] {
      let fetcher = Fetcher { _, _ in
        if !invalidCounts { throw URLError(.notConnectedToInternet) }
        return ChargingAvailabilityBatch(
          generatedAt: fixture.now, contextExpiresAt: fixture.now.addingTimeInterval(3_600),
          refreshPending: false, retryAfterSeconds: nil,
          candidates: [
            fixture.result.id: try ParkAvailability(
              knownAvailableCount: 6, knownUnavailableCount: 0, unknownCount: 0, totalCount: 6)
          ]
        )
      }
      let controller = RideAvailabilityController(fetcher: fetcher, now: { fixture.now })
      await controller.refresh(fixture.outcome())
      XCTAssertTrue(controller.values.isEmpty)
      XCTAssertEqual(controller.availability(for: fixture.result, onDemand: true).unknownCount, 4)
    }
  }

  func testRequestContainsOnlyContextAndVisibleOperatorUnitSelection() async throws {
    let fixture = try Fixture()
    let service = HTTPChargingAvailabilityService(
      baseURL: URL(string: "https://example.invalid"), accessTokenProvider: TokenProvider(),
      load: { request in
        XCTAssertEqual(request.url?.path, "/v1/charging-parks/availability")
        XCTAssertEqual(request.timeoutInterval, 20)
        let body = try XCTUnwrap(
          JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["context", "candidates"])
        let candidate = try XCTUnwrap((body["candidates"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(candidate.keys), ["id", "operatorNames"])
        XCTAssertEqual(candidate["operatorNames"] as? [String], ["Confirmed"])
        return (try fixture.responseData(), response(status: 200))
      }
    )
    let result = try await service.fetchAvailability(
      context: "context", candidates: fixture.selection)
    XCTAssertEqual(result.candidates[fixture.result.id]?.knownAvailableCount, 2)
  }

  func testResponseRejectsWrongScopeTotalsFreshnessAndMalformedCounts() async throws {
    let fixture = try Fixture()
    let mutations: [([String: Any]) -> [String: Any]] = [
      {
        var value = $0
        value["context"] = "another-context"
        return value
      },
      {
        var value = $0
        value["candidates"] = []
        return value
      },
      { value in mutateCandidate(value) { $0["operatorNames"] = ["Missing"] } },
      { value in mutateCandidate(value) { $0["id"] = UUID().uuidString } },
      { value in mutateAvailability(value) { $0["total"] = 6 } },
      { value in mutateAvailability(value) { $0["knownAvailable"] = -1 } },
      { value in mutateAvailability(value) { $0["knownAvailable"] = Int.max } },
      { value in mutateAvailability(value) { $0["observedAt"] = "2026-01-01T00:00:00Z" } },
      { value in mutateAvailability(value) { $0["observedAt"] = NSNull() } },
    ]
    for mutation in mutations {
      let body = mutation(try fixture.responseObject())
      let service = HTTPChargingAvailabilityService(
        baseURL: URL(string: "https://example.invalid"), accessTokenProvider: TokenProvider(),
        load: { _ in (try JSONSerialization.data(withJSONObject: body), response(status: 200)) }
      )
      do {
        _ = try await service.fetchAvailability(context: "context", candidates: fixture.selection)
        XCTFail("Malformed availability must not override an immutable result")
      } catch let error as ChargingAvailabilityError {
        XCTAssertEqual(error, .invalidResponse)
      }
    }
  }

  func testUnauthorizedRefreshesTokenOnceAndDoesNotRetryOtherFailures() async throws {
    let fixture = try Fixture()
    let tokens = TokenProvider()
    var attempts = 0
    let service = HTTPChargingAvailabilityService(
      baseURL: URL(string: "https://example.invalid"), accessTokenProvider: tokens,
      load: { _ in
        attempts += 1
        return (Data(), response(status: 401))
      }
    )
    do {
      _ = try await service.fetchAvailability(context: "context", candidates: fixture.selection)
      XCTFail("A second 401 must fail")
    } catch let error as ChargingAvailabilityError { XCTAssertEqual(error, .unavailable) }
    XCTAssertEqual(attempts, 2)
    let refreshes = await tokens.refreshes
    XCTAssertEqual(refreshes, [false, true])
    attempts = 0
    let failing = HTTPChargingAvailabilityService(
      baseURL: URL(string: "https://example.invalid"), accessTokenProvider: tokens,
      load: { _ in
        attempts += 1
        return (Data(), response(status: 503))
      }
    )
    do {
      _ = try await failing.fetchAvailability(context: "context", candidates: fixture.selection)
      XCTFail("An unavailable endpoint must keep its request bound")
    } catch let error as ChargingAvailabilityError { XCTAssertEqual(error, .unavailable) }
    XCTAssertEqual(attempts, 1)
  }
}

@MainActor
private final class Fetcher: ChargingAvailabilityFetching {
  var requests: [[ChargingAvailabilitySelection]] = []
  let handle:
    @MainActor (String, [ChargingAvailabilitySelection]) async throws -> ChargingAvailabilityBatch
  init(
    _ handle:
      @escaping @MainActor (String, [ChargingAvailabilitySelection]) async throws ->
      ChargingAvailabilityBatch
  ) {
    self.handle = handle
  }
  func fetchAvailability(context: String, candidates: [ChargingAvailabilitySelection]) async throws
    -> ChargingAvailabilityBatch
  {
    requests.append(candidates)
    return try await handle(context, candidates)
  }
}

private actor TokenProvider: SearchAccessTokenProviding {
  var refreshes: [Bool] = []
  func accessToken(forceRefresh: Bool) async throws -> String {
    refreshes.append(forceRefresh)
    return "synthetic-access-token-for-availability-tests"
  }
}

private struct Fixture {
  let now = Date(timeIntervalSince1970: 1_791_072_000)
  let result: RouteSearchResult
  init() throws {
    let coordinate = try Coordinate(latitude: 52, longitude: 10)
    let park = try ChargingPark(
      id: UUID(), name: "Synthetic", coordinate: coordinate, navigationCoordinate: coordinate,
      operatorChargingPoints: [
        OperatorChargingPointSummary(name: "Confirmed", chargingPointCount: 4),
        OperatorChargingPointSummary(name: "Missing", chargingPointCount: 2),
      ], chargingPointCount: 6,
      availability: ParkAvailability(
        knownAvailableCount: 0, knownUnavailableCount: 0, unknownCount: 6, totalCount: 6),
      maximumPower: Kilowatts(300), sourceReferences: []
    )
    result = RouteSearchResult(
      candidate: EnrichedChargingParkCandidate(
        park: park, distanceFromRoute: Meters(100), actualDrivingDistance: Meters(60_000),
        foodPOIs: []),
      matchingFoodPOI: nil, eligibleOperatorNames: ["Confirmed"]
    )
  }
  var selection: [ChargingAvailabilitySelection] { ChargingAvailabilitySelection.from([result]) }
  func outcome(context: String? = "context") -> RideCandidateSearchOutcome {
    RideCandidateSearchOutcome(
      results: [result],
      coverage: CandidateSearchCoverage(
        status: .complete, activeSourceIDs: [], unavailableSourceIDs: [], projectionUpdatedAt: now),
      availabilityContext: context)
  }
  func batch(available: Int, pending: Bool = false) throws -> ChargingAvailabilityBatch {
    ChargingAvailabilityBatch(
      generatedAt: now, contextExpiresAt: now.addingTimeInterval(3_600),
      refreshPending: pending, retryAfterSeconds: 2,
      candidates: [
        result.id: try ParkAvailability(
          knownAvailableCount: available, knownUnavailableCount: 0, unknownCount: 4 - available,
          totalCount: 4,
          lastLiveObservationAt: available > 0 ? now : nil)
      ]
    )
  }
  func responseObject() throws -> [String: Any] {
    [
      "context": "context", "generatedAt": now.ISO8601Format(),
      "expiresAt": now.addingTimeInterval(3_600).ISO8601Format(),
      "refreshPending": false,
      "candidates": [
        [
          "id": result.id.uuidString, "operatorNames": ["Confirmed"],
          "availability": [
            "knownAvailable": 2, "knownUnavailable": 0, "unknown": 2, "total": 4, "complete": false,
            "observedAt": now.ISO8601Format(),
          ],
        ]
      ],
    ]
  }
  func responseData() throws -> Data {
    try JSONSerialization.data(withJSONObject: responseObject())
  }
}

private func response(status: Int) -> HTTPURLResponse {
  HTTPURLResponse(
    url: URL(string: "https://example.invalid/v1/charging-parks/availability")!, statusCode: status,
    httpVersion: nil, headerFields: nil)!
}

private func mutateCandidate(_ original: [String: Any], _ mutation: (inout [String: Any]) -> Void)
  -> [String: Any]
{
  var value = original
  var candidates = value["candidates"] as! [[String: Any]]
  mutation(&candidates[0])
  value["candidates"] = candidates
  return value
}

private func mutateAvailability(
  _ original: [String: Any], _ mutation: (inout [String: Any]) -> Void
) -> [String: Any] {
  mutateCandidate(original) { candidate in
    var availability = candidate["availability"] as! [String: Any]
    mutation(&availability)
    candidate["availability"] = availability
  }
}
