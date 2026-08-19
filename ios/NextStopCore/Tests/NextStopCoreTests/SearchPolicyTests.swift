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

  private func makeCandidate(
    name: String,
    drivingKilometers: Int,
    routeMeters: Int = 1_000,
    chargingPoints: Int = 4,
    availability: ParkAvailability? = nil,
    maximumPower: Int = 100,
    operatorName: String = "Operator",
    foodPOIs: [FoodPOI] = []
  ) throws -> EnrichedChargingParkCandidate {
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
      operatorChargingPoints: [
        try OperatorChargingPointSummary(
          name: operatorName,
          chargingPointCount: chargingPoints
        )
      ],
      chargingPointCount: chargingPoints,
      availability: resolvedAvailability,
      maximumPower: Kilowatts(maximumPower),
      sourceReferences: [source]
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
