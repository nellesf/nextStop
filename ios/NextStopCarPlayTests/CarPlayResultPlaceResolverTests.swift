import Foundation
import MapKit
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayResultPlaceResolverTests: XCTestCase {
  func testNoFoodResultUsesSelectedOperatorsRepresentativeParkAndAddressScope() async throws {
    let result = try makeResult()
    let nativePlace = MKMapItem()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nativePlace)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    let resolved = try await service.resolveOperator(named: "IONITY", in: result)

    XCTAssertTrue(resolved === nativePlace)
    XCTAssertTrue(resolver.restaurantRequests.isEmpty)
    let request = try XCTUnwrap(resolver.requests.first)
    XCTAssertEqual(resolver.requests.count, 1)
    XCTAssertEqual(request.park, result.relatedCandidates[0].park)
    XCTAssertEqual(request.operatorName, "IONITY")
    XCTAssertEqual(
      request.relatedLocations,
      result.relatedCandidates.prefix(2).flatMap(\.park.locationLookups)
    )
    XCTAssertEqual(request.resultGroup.id, "park:\(result.id.uuidString)")
    XCTAssertEqual(request.resultGroup.kind, .noFoodCampus)
    XCTAssertEqual(request.resultGroup.evidenceLocations, result.locationLookups)
    XCTAssertEqual(
      request.resultGroup.searchCoordinates,
      result.candidates.map(\.park.navigationCoordinate)
    )
    XCTAssertNil(request.resultGroup.restaurantCoordinate)
  }

  func testRestaurantGroupIncludesSelectedOperatorsLocationsAtDifferentAddresses() async throws {
    let result = try makeResult(withRestaurant: true)
    let nativePlace = MKMapItem()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nativePlace)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    let resolved = try await service.resolveOperator(named: "IONITY", in: result)

    XCTAssertTrue(resolved === nativePlace)
    XCTAssertTrue(resolver.restaurantRequests.isEmpty)
    let request = try XCTUnwrap(resolver.requests.first)
    XCTAssertEqual(resolver.requests.count, 1)
    XCTAssertEqual(request.park, result.relatedCandidates[0].park)
    XCTAssertEqual(request.operatorName, "IONITY")
    XCTAssertEqual(
      request.relatedLocations,
      result.relatedCandidates.flatMap(\.park.locationLookups)
    )
    XCTAssertEqual(request.resultGroup.id, "restaurant:osm:node:1")
    XCTAssertEqual(request.resultGroup.kind, .restaurant)
    XCTAssertEqual(request.resultGroup.evidenceLocations, result.locationLookups)
    XCTAssertEqual(
      request.resultGroup.searchCoordinates,
      result.candidates.map(\.park.navigationCoordinate)
    )
    XCTAssertEqual(request.resultGroup.restaurantCoordinate, result.matchingFoodPOI?.coordinate)
  }

  func testOperatorWithoutARepresentativeParkIsRejectedBeforeNativeLookup() async throws {
    let result = try makeResult()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: MKMapItem())
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    do {
      _ = try await service.resolveOperator(named: "IONITY GmbH", in: result)
      XCTFail("Expected an operator outside the result to be rejected")
    } catch let error as CarPlayPlaceResolutionError {
      XCTAssertEqual(error, .operatorUnavailable)
    }

    XCTAssertTrue(resolver.requests.isEmpty)
  }

  func testMissingNativePlaceFailsWithoutCreatingACoordinateFallback() async throws {
    let result = try makeResult()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nil)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    do {
      _ = try await service.resolveOperator(named: "IONITY", in: result)
      XCTFail("Expected no match instead of a coordinate fallback")
    } catch let error as CarPlayPlaceResolutionError {
      XCTAssertEqual(error, .placeNotFound)
    }

    XCTAssertEqual(resolver.requests.count, 1)
  }

  func testCancellationBeforeLookupDoesNotStartNativeSearch() async throws {
    let result = try makeResult()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: MKMapItem())
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)
    let task = Task { @MainActor in
      _ = try await service.resolveOperator(named: "IONITY", in: result)
    }
    task.cancel()

    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(resolver.requests.isEmpty)
    }
  }

  func testCancellationDuringLookupDiscardsNativePlace() async throws {
    let result = try makeResult()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: MKMapItem())
    resolver.onResolve = {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)
    let task = Task { @MainActor in
      _ = try await service.resolveOperator(named: "IONITY", in: result)
    }

    do {
      try await task.value
      XCTFail("Expected the cancelled lookup to discard its resolved place")
    } catch is CancellationError {
      XCTAssertEqual(resolver.requests.count, 1)
    }
  }

  func testCancelledLookupWithoutAMatchRemainsCancellation() async throws {
    let result = try makeResult()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nil)
    resolver.onResolve = {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)
    let task = Task { @MainActor in
      _ = try await service.resolveOperator(named: "IONITY", in: result)
    }

    do {
      try await task.value
      XCTFail("Expected cancellation rather than a place-not-found error")
    } catch is CancellationError {
      XCTAssertEqual(resolver.requests.count, 1)
    }
  }

  func testRestaurantResolutionReturnsTheSameNativePlaceUsedByIPhone() async throws {
    let result = try makeResult(withRestaurant: true)
    let nativePlace = MKMapItem()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nativePlace)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    let resolved = try await service.resolveRestaurant(in: result)

    XCTAssertTrue(resolved === nativePlace)
    XCTAssertEqual(resolver.restaurantRequests, [try XCTUnwrap(result.matchingFoodPOI)])
    XCTAssertTrue(resolver.requests.isEmpty)
  }

  func testRestaurantResolutionReusesTheNativePlaceDuringTheRide() async throws {
    let result = try makeResult(withRestaurant: true)
    let nativePlace = MKMapItem()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nativePlace)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    let first = try await service.resolveRestaurant(in: result)
    let repeated = try await service.resolveRestaurant(in: result)

    XCTAssertTrue(first === nativePlace)
    XCTAssertTrue(repeated === nativePlace)
    XCTAssertEqual(resolver.restaurantRequests.count, 1)
  }

  func testRestaurantCacheDoesNotShareChangedCoordinatesOrNativePlaceEvidence() async throws {
    let result = try makeResult(withRestaurant: true)
    let foodPOI = try XCTUnwrap(result.matchingFoodPOI)
    let originalPlace = MKMapItem()
    let changedPlace = MKMapItem()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: originalPlace)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)
    _ = try await service.resolveRestaurant(in: result)
    resolver.mapItem = changedPlace

    let changedRestaurants = [
      try FoodPOI(
        id: foodPOI.id,
        applePlaceIdentifier: foodPOI.applePlaceIdentifier,
        chain: foodPOI.chain,
        name: foodPOI.name,
        coordinate: Coordinate(latitude: 52.001, longitude: 10),
        distanceFromPark: foodPOI.distanceFromPark,
        openingStatus: foodPOI.openingStatus
      ),
      try FoodPOI(
        id: foodPOI.id,
        applePlaceIdentifier: "updated-native-place",
        chain: foodPOI.chain,
        name: foodPOI.name,
        coordinate: foodPOI.coordinate,
        distanceFromPark: foodPOI.distanceFromPark,
        openingStatus: foodPOI.openingStatus
      ),
    ]
    for restaurant in changedRestaurants {
      let changedResult = RouteSearchResult(
        candidate: result.candidate,
        relatedCandidates: result.relatedCandidates,
        matchingFoodPOI: restaurant
      )

      let resolved = try await service.resolveRestaurant(in: changedResult)

      XCTAssertTrue(resolved === changedPlace)
    }

    XCTAssertEqual(resolver.restaurantRequests, [foodPOI] + changedRestaurants)
    let originalAgain = try await service.resolveRestaurant(in: result)
    XCTAssertTrue(originalAgain === originalPlace)
    XCTAssertEqual(resolver.restaurantRequests.count, 3)
  }

  func testMissingRestaurantIsRejectedBeforeNativeLookup() async throws {
    let result = try makeResult()
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: MKMapItem())
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    do {
      _ = try await service.resolveRestaurant(in: result)
      XCTFail("Expected a result without a restaurant to be rejected")
    } catch let error as CarPlayPlaceResolutionError {
      XCTAssertEqual(error, .restaurantUnavailable)
    }

    XCTAssertTrue(resolver.restaurantRequests.isEmpty)
    XCTAssertTrue(resolver.requests.isEmpty)
  }

  func testMissingNativeRestaurantFailsWithoutAFallbackAndCanBeRetried() async throws {
    let result = try makeResult(withRestaurant: true)
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: nil)
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)

    do {
      _ = try await service.resolveRestaurant(in: result)
      XCTFail("Expected no match instead of a coordinate fallback")
    } catch let error as CarPlayPlaceResolutionError {
      XCTAssertEqual(error, .placeNotFound)
    }

    XCTAssertEqual(resolver.restaurantRequests.count, 1)
    XCTAssertTrue(resolver.requests.isEmpty)

    let nativePlace = MKMapItem()
    resolver.mapItem = nativePlace
    let resolved = try await service.resolveRestaurant(in: result)

    XCTAssertTrue(resolved === nativePlace)
    XCTAssertEqual(resolver.restaurantRequests.count, 2)
  }

  func testCancellationBeforeRestaurantLookupDoesNotStartNativeSearch() async throws {
    let result = try makeResult(withRestaurant: true)
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: MKMapItem())
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)
    let task = Task { @MainActor in
      _ = try await service.resolveRestaurant(in: result)
    }
    task.cancel()

    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertTrue(resolver.restaurantRequests.isEmpty)
      XCTAssertTrue(resolver.requests.isEmpty)
    }
  }

  func testCancellationDuringRestaurantLookupDiscardsNativePlaceWithoutCachingIt() async throws {
    let result = try makeResult(withRestaurant: true)
    let resolver = CarPlayApplePlaceResolverSpy(mapItem: MKMapItem())
    resolver.onResolve = {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    let service = CarPlayResultPlaceResolver(placeResolver: resolver)
    let task = Task { @MainActor in
      _ = try await service.resolveRestaurant(in: result)
    }

    do {
      try await task.value
      XCTFail("Expected the cancelled lookup to discard its resolved restaurant")
    } catch is CancellationError {
      XCTAssertEqual(resolver.restaurantRequests.count, 1)
      XCTAssertTrue(resolver.requests.isEmpty)
    }

    resolver.onResolve = nil
    _ = try await service.resolveRestaurant(in: result)

    XCTAssertEqual(resolver.restaurantRequests.count, 2)
  }

  private func makeResult(withRestaurant: Bool = false) throws -> RouteSearchResult {
    let sharedAddress = ChargingLocationAddress(
      street: "Ladestraße",
      houseNumber: "1",
      postalCode: "10000",
      city: "Berlin"
    )
    let differentAddress = ChargingLocationAddress(
      street: "Parkstraße",
      houseNumber: "2",
      postalCode: "10000",
      city: "Berlin"
    )
    let candidates = try (1...4).map { index in
      let operatorName = index == 1 ? "EnBW" : "IONITY"
      let coordinate = try Coordinate(latitude: 52 + Double(index) * 0.0001, longitude: 10)
      let id = UUID(uuidString: "10000000-0000-4000-8000-00000000000\(index)")!
      let park = try ChargingPark(
        id: id,
        name: "Ladepark \(index)",
        coordinate: coordinate,
        navigationCoordinate: coordinate,
        operatorChargingPoints: [
          OperatorChargingPointSummary(name: operatorName, chargingPointCount: 4)
        ],
        chargingPointCount: 4,
        availability: ParkAvailability(
          knownAvailableCount: 0,
          knownUnavailableCount: 0,
          unknownCount: 4,
          totalCount: 4
        ),
        maximumPower: Kilowatts(150),
        sourceReferences: [
          DataSourceReference(
            sourceID: "authority",
            sourceRecordID: id.uuidString,
            qualityTier: .authority,
            observedAt: Date(timeIntervalSince1970: 0),
            fetchedAt: Date(timeIntervalSince1970: 0)
          )
        ],
        locationLookups: [
          ChargingLocationLookup(
            id: id,
            operatorName: operatorName,
            coordinate: coordinate,
            address: index == 4 ? differentAddress : sharedAddress
          )
        ]
      )
      return EnrichedChargingParkCandidate(
        park: park,
        distanceFromRoute: Meters(100),
        actualDrivingDistance: Meters(80_000 + index),
        foodPOIs: []
      )
    }
    return RouteSearchResult(
      candidate: candidates[0],
      relatedCandidates: Array(candidates.dropFirst()),
      matchingFoodPOI: withRestaurant
        ? try FoodPOI(
          id: "osm:node:1",
          chain: .mcdonalds,
          name: "McDonald's",
          coordinate: Coordinate(latitude: 52, longitude: 10),
          distanceFromPark: Meters(100),
          openingStatus: .unknown
        ) : nil
    )
  }
}

@MainActor
private final class CarPlayApplePlaceResolverSpy: ApplePlaceResolving {
  struct Request {
    let park: ChargingPark
    let operatorName: String
    let relatedLocations: [ChargingLocationLookup]
    let resultGroup: AppleChargingPlaceResultGroup
  }

  var mapItem: MKMapItem?
  private(set) var requests: [Request] = []
  private(set) var restaurantRequests: [FoodPOI] = []
  var onResolve: (() -> Void)?

  init(mapItem: MKMapItem?) {
    self.mapItem = mapItem
  }

  func resolveChargingPlace(
    park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup],
    resultGroup: AppleChargingPlaceResultGroup
  ) async -> MKMapItem? {
    requests.append(
      Request(
        park: park,
        operatorName: operatorName,
        relatedLocations: relatedLocations,
        resultGroup: resultGroup
      ))
    onResolve?()
    return mapItem
  }

  func resolveRestaurantPlace(_ foodPOI: FoodPOI) async -> MKMapItem? {
    restaurantRequests.append(foodPOI)
    onResolve?()
    return mapItem
  }
}
