import Foundation
import XCTest

@testable import NextStopCore

final class SearchPolicyTests: XCTestCase {
  private let policy = ChargingParkSearchPolicy()

  func testRouteCorridorUsesInclusiveFiveKilometerBoundary() throws {
    let inside = try makeCandidate(name: "inside", drivingKilometers: 60, routeMeters: 5_000)
    let outside = try makeCandidate(name: "outside", drivingKilometers: 61, routeMeters: 5_001)

    let results = policy.selectResults(
      from: [outside, inside],
      criteria: SearchConfiguration.defaultCriteria
    )

    XCTAssertEqual(results.map(\.candidate.park.name), ["inside"])
  }

  func testDistanceRangeRankingAndMaximumFiveMatchSpecification() throws {
    let distances = [78, 112, 124, 139, 145, 147]
    let candidates = try distances.map {
      try makeCandidate(name: "\($0)", drivingKilometers: $0)
    }
    let criteria = RideCriteria(
      distanceRange: .kilometers100To150,
      minimumChargingPoints: .four,
      minimumPower: .oneHundred,
      foodChain: nil
    )

    let results = policy.selectResults(from: Array(candidates.reversed()), criteria: criteria)

    XCTAssertEqual(
      results.map(\.candidate.actualDrivingDistance.value),
      [112_000, 124_000, 139_000, 145_000, 147_000]
    )
  }

  func testAvailabilityIsInformationalAndNeverExcludesPark() throws {
    let availability = try ParkAvailability(
      knownAvailableCount: 0,
      knownUnavailableCount: 8,
      unknownCount: 0,
      totalCount: 8
    )
    let candidate = try makeCandidate(
      name: "unknown",
      drivingKilometers: 60,
      chargingPoints: 8,
      availability: availability
    )
    let results = policy.selectResults(
      from: [candidate],
      criteria: SearchConfiguration.defaultCriteria
    )

    XCTAssertEqual(results.count, 1)
  }

  func testChargingPointAndPowerFilters() throws {
    let tooSmall = try makeCandidate(
      name: "small",
      drivingKilometers: 60,
      chargingPoints: 2,
      maximumPower: 350
    )
    let tooSlow = try makeCandidate(
      name: "slow",
      drivingKilometers: 61,
      chargingPoints: 8,
      maximumPower: 50
    )
    let matching = try makeCandidate(
      name: "matching",
      drivingKilometers: 62,
      chargingPoints: 8,
      maximumPower: 150
    )
    let criteria = RideCriteria(
      distanceRange: .kilometers50To100,
      minimumChargingPoints: .eight,
      minimumPower: .oneHundredFifty,
      foodChain: nil
    )

    let results = policy.selectResults(
      from: [tooSmall, tooSlow, matching],
      criteria: criteria
    )

    XCTAssertEqual(results.map(\.candidate.park.name), ["matching"])
  }

  func testFoodFilterUsesInclusiveRadiusAndIgnoresOpeningStatus() throws {
    let atBoundary = try makeFoodPOI(
      id: "boundary",
      chain: .mcdonalds,
      meters: 500,
      openingStatus: .closed
    )
    let outside = try makeFoodPOI(
      id: "outside",
      chain: .mcdonalds,
      meters: 501,
      openingStatus: .open
    )
    let matching = try makeCandidate(
      name: "matching",
      drivingKilometers: 60,
      foodPOIs: [outside, atBoundary]
    )
    let noMatch = try makeCandidate(
      name: "no-match",
      drivingKilometers: 61,
      foodPOIs: [outside]
    )
    var criteria = SearchConfiguration.defaultCriteria
    criteria.foodChain = .mcdonalds

    let results = policy.selectResults(from: [noMatch, matching], criteria: criteria)

    XCTAssertEqual(results.map(\.candidate.park.name), ["matching"])
    XCTAssertEqual(results.first?.matchingFoodPOI?.id, "boundary")
    XCTAssertEqual(results.first?.matchingFoodPOI?.openingStatus, .closed)
  }

  func testFoodSearchReturnsOneAggregatedResultPerRestaurant() throws {
    let firstRestaurant = try makeFoodPOI(
      id: "restaurant-a",
      chain: .mcdonalds,
      meters: 100,
      openingStatus: .unknown
    )
    let sameRestaurantFromAnotherPark = try makeFoodPOI(
      id: "restaurant-a",
      chain: .mcdonalds,
      meters: 200,
      openingStatus: .unknown
    )
    let secondRestaurant = try makeFoodPOI(
      id: "restaurant-b",
      chain: .mcdonalds,
      meters: 150,
      openingStatus: .unknown
    )
    let firstPark = try makeCandidate(
      name: "first-park",
      drivingKilometers: 60,
      operatorName: "HomE of Mobility GmbH",
      foodPOIs: [firstRestaurant]
    )
    let secondPark = try makeCandidate(
      name: "second-park",
      drivingKilometers: 61,
      operatorName: "HomE of Mobility GmbH",
      foodPOIs: [sameRestaurantFromAnotherPark]
    )
    let thirdPark = try makeCandidate(
      name: "third-park",
      drivingKilometers: 70,
      foodPOIs: [secondRestaurant]
    )
    var criteria = SearchConfiguration.defaultCriteria
    criteria.foodChain = .mcdonalds

    let results = policy.selectResults(
      from: [thirdPark, secondPark, firstPark],
      criteria: criteria
    )

    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.map(\.matchingFoodPOI?.id), ["restaurant-a", "restaurant-b"])
    XCTAssertEqual(results[0].candidates.map(\.park.name), ["first-park", "second-park"])
    XCTAssertEqual(results[0].chargingPointCount, 8)
    XCTAssertEqual(results[0].operatorChargingPoints.count, 1)
    XCTAssertEqual(results[0].operatorChargingPoints.first?.name, "HomE of Mobility GmbH")
    XCTAssertEqual(results[0].operatorChargingPoints.first?.chargingPointCount, 8)
  }

  func testRankingUsesOnlyActualDrivingDistance() throws {
    let closer = try makeCandidate(
      name: "closer",
      drivingKilometers: 60,
      chargingPoints: 4,
      maximumPower: 100
    )
    let fartherWithSurplus = try makeCandidate(
      name: "farther",
      drivingKilometers: 70,
      chargingPoints: 20,
      maximumPower: 400
    )

    let results = policy.selectResults(
      from: [fartherWithSurplus, closer],
      criteria: SearchConfiguration.defaultCriteria
    )

    XCTAssertEqual(results.map(\.candidate.park.name), ["closer", "farther"])
  }

  func testRankedResultsKeepSixthCandidateBeforeFinalPlaceConfirmation() throws {
    let candidates = try (60...65).map {
      try makeCandidate(name: "park-\($0)", drivingKilometers: $0)
    }
    let criteria = SearchConfiguration.defaultCriteria

    let ranked = policy.rankedResults(from: candidates.reversed(), criteria: criteria)

    XCTAssertEqual(
      ranked.map(\.candidate.actualDrivingDistance.value),
      [60, 61, 62, 63, 64, 65].map { $0 * 1_000 })
    XCTAssertEqual(
      policy.selectResults(from: candidates, criteria: criteria), Array(ranked.prefix(5)))
    // An unmatched early candidate must not hide the sixth qualified result.
    let confirmed = ranked.enumerated().compactMap { index, result in
      policy.restrictToOperators(
        result, operatorNames: index == 0 ? [] : ["Operator"], criteria: criteria)
    }
    XCTAssertEqual(confirmed.count, 5)
    XCTAssertEqual(confirmed.last?.candidate.actualDrivingDistance, Meters(65_000))
  }

  func testNumbatFourAndEnBWTwoCannotMeetSixAfterEitherOperatorIsRemoved() throws {
    let candidate = try makeCandidate(
      name: "mixed-campus", drivingKilometers: 79, maximumPower: 300,
      operatorCounts: ["numbat gmbh": 4, "EnBW": 2]
    )
    let criteria = RideCriteria(
      distanceRange: .kilometers50To100, minimumChargingPoints: .six,
      minimumPower: .threeHundred, foodChain: nil
    )
    let result = try XCTUnwrap(policy.rankedResults(from: [candidate], criteria: criteria).first)

    XCTAssertNil(
      policy.restrictToOperators(result, operatorNames: ["numbat gmbh"], criteria: criteria))
    XCTAssertNil(policy.restrictToOperators(result, operatorNames: ["EnBW"], criteria: criteria))
    XCTAssertEqual(
      policy.restrictToOperators(
        result, operatorNames: ["numbat gmbh", "EnBW"], criteria: criteria)?.chargingPointCount,
      6
    )
  }

  func testEnoughConfirmedEVSEsRetainOriginalParkAndActualDistance() throws {
    let candidate = try makeCandidate(
      name: "old mixed title", drivingKilometers: 79, maximumPower: 300,
      operatorCounts: ["Confirmed": 6, "Missing": 4]
    )
    let criteria = RideCriteria(
      distanceRange: .kilometers50To100, minimumChargingPoints: .six,
      minimumPower: .threeHundred, foodChain: nil
    )
    let result = try XCTUnwrap(policy.rankedResults(from: [candidate], criteria: criteria).first)
    let restricted = try XCTUnwrap(
      policy.restrictToOperators(
        result, operatorNames: ["Confirmed", "Not in this park"], criteria: criteria
      ))

    XCTAssertEqual(restricted.candidate, candidate)
    XCTAssertEqual(restricted.candidate.park.chargingPointCount, 10)
    XCTAssertEqual(restricted.candidate.actualDrivingDistance, Meters(79_000))
    XCTAssertEqual(restricted.chargingPointCount, 6)
    XCTAssertEqual(restricted.eligibleOperatorNames, ["Confirmed"])
    XCTAssertEqual(restricted.operatorChargingPoints.map(\.name), ["Confirmed"])
    XCTAssertEqual(restricted.displayName, "Confirmed")
  }

  func testRestaurantMembersMustMeetMinimumSeparatelyAfterOperatorRestriction() throws {
    let food = try makeFoodPOI(
      id: "restaurant", chain: .mcdonalds, meters: 100, openingStatus: .unknown)
    let candidates = try [60, 61].map {
      try makeCandidate(
        name: "park-\($0)", drivingKilometers: $0,
        operatorCounts: ["Confirmed": 2, "Missing": 2], foodPOIs: [food]
      )
    }
    var criteria = SearchConfiguration.defaultCriteria
    criteria.foodChain = .mcdonalds
    let result = try XCTUnwrap(policy.rankedResults(from: candidates, criteria: criteria).first)

    XCTAssertEqual(result.chargingPointCount, 8)
    // Four retained EVSEs across two undersized fine parks must not rescue the restaurant.
    XCTAssertNil(
      policy.restrictToOperators(result, operatorNames: ["Confirmed"], criteria: criteria))
  }

  func testRestaurantReplacesRemovedRepresentativeWithActualNearestRetainedMember() throws {
    let nearFood = try makeFoodPOI(
      id: "restaurant", chain: .mcdonalds, meters: 100, openingStatus: .unknown)
    let farFood = try makeFoodPOI(
      id: "restaurant", chain: .mcdonalds, meters: 400, openingStatus: .unknown)
    let near = try makeCandidate(
      name: "near", drivingKilometers: 60,
      operatorCounts: ["Confirmed": 2, "Missing": 4], foodPOIs: [nearFood]
    )
    let far = try makeCandidate(
      name: "far", drivingKilometers: 70, operatorName: "Confirmed", foodPOIs: [farFood]
    )
    var criteria = SearchConfiguration.defaultCriteria
    criteria.foodChain = .mcdonalds
    let result = try XCTUnwrap(policy.rankedResults(from: [far, near], criteria: criteria).first)
    let restricted = try XCTUnwrap(
      policy.restrictToOperators(result, operatorNames: ["Confirmed"], criteria: criteria))

    XCTAssertEqual(restricted.candidates, [far])
    XCTAssertEqual(restricted.candidate.actualDrivingDistance, Meters(70_000))
    XCTAssertEqual(restricted.matchingFoodPOI, farFood)
    XCTAssertEqual(restricted.chargingPointCount, 4)
    XCTAssertEqual(restricted.placeLookupCandidates, [near, far])
    XCTAssertEqual(restricted.representativePark(for: "Confirmed"), near.park)
  }

  func testPartiallyRetainedAvailabilityIsUnknownWhileWholeMemberAvailabilitySurvives() throws {
    let food = try makeFoodPOI(
      id: "restaurant", chain: .mcdonalds, meters: 100, openingStatus: .unknown)
    let partial = try makeCandidate(
      name: "partial", drivingKilometers: 60,
      availability: ParkAvailability(
        knownAvailableCount: 4, knownUnavailableCount: 2, unknownCount: 0, totalCount: 6,
        lastLiveObservationAt: Date(timeIntervalSince1970: 200)
      ),
      operatorCounts: ["Confirmed": 4, "Missing": 2], foodPOIs: [food]
    )
    let complete = try makeCandidate(
      name: "complete", drivingKilometers: 70,
      availability: ParkAvailability(
        knownAvailableCount: 1, knownUnavailableCount: 2, unknownCount: 1, totalCount: 4,
        lastLiveObservationAt: Date(timeIntervalSince1970: 100)
      ),
      operatorName: "Confirmed", foodPOIs: [food]
    )
    var criteria = SearchConfiguration.defaultCriteria
    criteria.foodChain = .mcdonalds
    let result = try XCTUnwrap(
      policy.rankedResults(from: [complete, partial], criteria: criteria).first)
    let restricted = try XCTUnwrap(
      policy.restrictToOperators(result, operatorNames: ["Confirmed"], criteria: criteria))

    XCTAssertEqual(
      restricted.availability,
      try ParkAvailability(
        knownAvailableCount: 1, knownUnavailableCount: 2, unknownCount: 5, totalCount: 8,
        lastLiveObservationAt: Date(timeIntervalSince1970: 100)
      ))
    XCTAssertEqual(restricted.chargingPointCount, restricted.availability.totalCount)
    XCTAssertFalse(restricted.availability.isComplete)
    let partialOnly = try XCTUnwrap(
      policy.restrictToOperators(
        RouteSearchResult(candidate: partial, matchingFoodPOI: food),
        operatorNames: ["Confirmed"], criteria: criteria
      ))
    XCTAssertEqual(partialOnly.availability.unknownCount, 4)
    XCTAssertNil(partialOnly.availability.lastLiveObservationAt)
  }

  func testRestrictionRetainsOriginalLookupEvidenceWithoutResurrectingOperators() throws {
    let coordinate = try Coordinate(latitude: 52, longitude: 10)
    let lookups = try ["Confirmed", "Missing"].map {
      try ChargingLocationLookup(
        id: UUID(), operatorName: $0, coordinate: coordinate, address: ChargingLocationAddress())
    }
    let candidate = try makeCandidate(
      name: "mixed", drivingKilometers: 60, operatorCounts: ["Confirmed": 4, "Missing": 4],
      locationLookups: lookups
    )
    let criteria = SearchConfiguration.defaultCriteria
    let original = RouteSearchResult(candidate: candidate, matchingFoodPOI: nil)
    let restricted = try XCTUnwrap(
      policy.restrictToOperators(original, operatorNames: ["Confirmed"], criteria: criteria))
    let repeated = try XCTUnwrap(
      policy.restrictToOperators(
        restricted, operatorNames: ["Confirmed", "Missing"], criteria: criteria
      ))

    XCTAssertEqual(repeated, restricted)
    XCTAssertEqual(repeated.placeLookupCandidates, original.candidates)
    XCTAssertEqual(repeated.locationLookups, lookups)
    XCTAssertEqual(repeated.operatorChargingPoints.map(\.name), ["Confirmed"])
    XCTAssertNil(
      policy.restrictToOperators(restricted, operatorNames: ["Missing"], criteria: criteria))
    XCTAssertEqual(
      try JSONDecoder().decode(RouteSearchResult.self, from: JSONEncoder().encode(restricted)),
      restricted)
  }

  func testUnrestrictedResultPreservesExistingDisplayAndCodableDefaults() throws {
    let candidate = try makeCandidate(name: "existing title", drivingKilometers: 60)
    let result = RouteSearchResult(candidate: candidate, matchingFoodPOI: nil)
    let decoded = try JSONDecoder().decode(
      RouteSearchResult.self, from: JSONEncoder().encode(result))

    XCTAssertNil(decoded.eligibleOperatorNames)
    XCTAssertEqual(decoded.displayName, candidate.park.name)
    XCTAssertEqual(decoded.placeLookupCandidates, [candidate])
    XCTAssertEqual(decoded.availability, candidate.park.availability)
  }

  private func makeCandidate(
    name: String,
    drivingKilometers: Int,
    routeMeters: Int = 1_000,
    chargingPoints: Int = 4,
    availability: ParkAvailability? = nil,
    maximumPower: Int = 100,
    operatorName: String = "Operator",
    operatorCounts: [String: Int]? = nil,
    locationLookups: [ChargingLocationLookup] = [],
    foodPOIs: [FoodPOI] = []
  ) throws -> EnrichedChargingParkCandidate {
    let operators = operatorCounts ?? [operatorName: chargingPoints]
    let chargingPoints = operators.values.reduce(0, +)
    let coordinate = try Coordinate(latitude: 52.0, longitude: 10.0)
    let resolvedAvailability: ParkAvailability
    if let availability {
      resolvedAvailability = availability
    } else {
      resolvedAvailability = try ParkAvailability(
        knownAvailableCount: 0,
        knownUnavailableCount: 0,
        unknownCount: chargingPoints,
        totalCount: chargingPoints
      )
    }
    let source = try DataSourceReference(
      sourceID: "fixture",
      sourceRecordID: name,
      qualityTier: .authority,
      observedAt: nil,
      fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let id = UUID(uuidString: deterministicUUID(for: name)) ?? UUID()
    let park = try ChargingPark(
      id: id,
      name: name,
      coordinate: coordinate,
      navigationCoordinate: coordinate,
      operatorChargingPoints: try operators.map {
        try OperatorChargingPointSummary(name: $0.key, chargingPointCount: $0.value)
      },
      chargingPointCount: chargingPoints,
      availability: resolvedAvailability,
      maximumPower: Kilowatts(maximumPower),
      sourceReferences: [source],
      locationLookups: locationLookups
    )
    return EnrichedChargingParkCandidate(
      park: park,
      distanceFromRoute: Meters(routeMeters),
      actualDrivingDistance: Meters(drivingKilometers * 1_000),
      foodPOIs: foodPOIs
    )
  }

  private func makeFoodPOI(
    id: String,
    chain: FoodChain,
    meters: Int,
    openingStatus: OpeningStatus
  ) throws -> FoodPOI {
    try FoodPOI(
      id: id,
      chain: chain,
      name: id,
      coordinate: Coordinate(latitude: 52.0, longitude: 10.0),
      distanceFromPark: Meters(meters),
      openingStatus: openingStatus
    )
  }

  private func deterministicUUID(for value: String) -> String {
    let scalarSum = value.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 65_535 }
    return String(format: "00000000-0000-0000-0000-%012d", scalarSum)
  }
}
