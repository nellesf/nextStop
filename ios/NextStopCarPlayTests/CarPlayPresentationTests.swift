import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayPresentationTests: XCTestCase {
  func testDestinationSelectionUsesDefaultsWithoutAProfileReference() throws {
    let destination = try SavedDestination(
      displayName: "Hamburg",
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
    let controller = CarPlayRideDraftController()

    controller.select(destination: destination)

    XCTAssertEqual(controller.draft?.destination, destination)
    XCTAssertEqual(controller.draft?.criteria, SearchConfiguration.defaultCriteria)
    XCTAssertNil(controller.draft?.sourceProfileID)
  }

  func testProfileSelectionCreatesAnIndependentRideDraft() throws {
    var profile = try makeProfile()
    let originalCriteria = profile.criteria
    let controller = CarPlayRideDraftController()

    controller.select(profile: profile)
    controller.apply(.minimumPower(.threeHundredFifty))
    profile.criteria.minimumPower = .eleven

    XCTAssertEqual(controller.draft?.criteria.minimumPower, .threeHundredFifty)
    XCTAssertEqual(originalCriteria.minimumPower, .oneHundredFifty)
  }

  func testGermanSummaryUsesOnlyFixedCriteriaOptions() throws {
    let profile = try makeProfile()
    let draft = RideSearchDraft(profile: profile)
    let presenter = CarPlayPresenter(localizer: germanLocalizer())

    let summary = presenter.rideSummary(draft)

    XCTAssertEqual(summary.title, "Fahrt")
    XCTAssertEqual(summary.destination, "Berlin Hauptbahnhof")
    XCTAssertEqual(summary.criteria.count, 4)
    XCTAssertEqual(summary.criteria[0].value, "100–150 km")
    XCTAssertEqual(summary.criteria[1].value, "mindestens 8")
    XCTAssertEqual(summary.criteria[2].value, "150 kW")
    XCTAssertEqual(summary.criteria[3].value, "McDonald's")
    XCTAssertEqual(
      presenter.options(for: .minimumPower, draft: draft).filter(\.selected).count,
      1
    )
  }

  func testNoRestaurantModeUsesExplicitCopyInsteadOfAny() throws {
    let profile = try makeProfile(foodChain: nil)
    let draft = RideSearchDraft(profile: profile)
    let presenter = CarPlayPresenter(localizer: germanLocalizer())

    let restaurantCriterion = presenter.rideSummary(draft).criteria[3]
    let restaurantOptions = presenter.options(for: .foodChain, draft: draft)

    XCTAssertEqual(restaurantCriterion.title, "Restaurant")
    XCTAssertEqual(restaurantCriterion.value, "Kein Restaurant erforderlich")
    XCTAssertEqual(restaurantOptions.first?.title, "Kein Restaurant erforderlich")
    XCTAssertEqual(restaurantOptions.filter(\.selected).count, 1)
  }

  func testResultsKeepDistanceOrderAndDescribePartialAvailabilityHonestly() throws {
    let first = try makeResult(
      id: "10000000-0000-4000-8000-000000000001",
      name: "Ladepark Eins",
      drivingMeters: 80_000,
      knownAvailable: 2,
      unknown: 2
    )
    let second = try makeResult(
      id: "10000000-0000-4000-8000-000000000002",
      name: "Ladepark Zwei",
      drivingMeters: 90_000,
      knownAvailable: 0,
      unknown: 4
    )
    let outcome = RideCandidateSearchOutcome(
      results: [first, second],
      coverage: CandidateSearchCoverage(
        status: .degraded,
        activeSourceIDs: ["bundesnetzagentur_ladesaeulenregister", "ich_tanke_strom"],
        unavailableSourceIDs: ["ich_tanke_strom:live"],
        projectionUpdatedAt: Date(timeIntervalSince1970: 0)
      ),
      attributions: [
        DataAttribution(
          id: "openstreetmap_food_poi",
          name: "OpenStreetMap",
          notice: "© OpenStreetMap contributors",
          licenseName: "Open Database License (ODbL) 1.0",
          licenseURL: URL(string: "https://www.openstreetmap.org/copyright")!,
          transportName: "Geofabrik",
          transportURL: URL(string: "https://download.geofabrik.de/")!
        )
      ]
    )

    let presentation = CarPlayPresenter(localizer: germanLocalizer()).results(
      outcome,
      criteria: try makeProfile().criteria
    )

    XCTAssertEqual(presentation.points.map(\.title), ["Ladepark Eins", "Ladepark Zwei"])
    XCTAssertEqual(presentation.points[0].subtitle, "80 km · 1 km von der Route")
    XCTAssertEqual(
      presentation.points[0].summary,
      "4 Ladepunkte · 150 kW oder höher · 2 sicher frei, 2 unbekannt"
    )
    XCTAssertEqual(
      presentation.points[1].summary,
      "4 Ladepunkte · 150 kW oder höher"
    )
    XCTAssertEqual(
      presentation.points[0].detailSummary,
      "Operator · 4 Ladepunkte\n4 Ladepunkte · 150 kW oder höher · 2 sicher frei, 2 unbekannt"
    )
    XCTAssertEqual(presentation.points[1].detailSubtitle, "90 km")
    XCTAssertEqual(presentation.coverageMessage, "Live-Daten teilweise verfügbar")
    XCTAssertEqual(presentation.attributionMessage, "© OpenStreetMap contributors")
  }

  func testRestaurantResultCombinesMemberParksAndOperatorsOnce() throws {
    let first = try makeResult(
      id: "10000000-0000-4000-8000-000000000001",
      name: "Ladepark Eins",
      drivingMeters: 80_000,
      knownAvailable: 0,
      unknown: 4
    )
    let second = try makeResult(
      id: "10000000-0000-4000-8000-000000000002",
      name: "Ladepark Zwei",
      drivingMeters: 81_000,
      knownAvailable: 0,
      unknown: 4
    )
    let foodPOI = try FoodPOI(
      id: "osm:node:1",
      chain: .mcdonalds,
      name: "McDonald's",
      coordinate: Coordinate(latitude: 52, longitude: 10),
      distanceFromPark: Meters(100),
      openingStatus: .unknown
    )
    let groupedResult = RouteSearchResult(
      candidate: first.candidate,
      relatedCandidates: [second.candidate],
      matchingFoodPOI: foodPOI
    )
    let outcome = RideCandidateSearchOutcome(
      results: [groupedResult],
      coverage: CandidateSearchCoverage(
        status: .complete,
        activeSourceIDs: ["bundesnetzagentur_ladesaeulenregister"],
        unavailableSourceIDs: [],
        projectionUpdatedAt: Date(timeIntervalSince1970: 0)
      )
    )

    let presentation = CarPlayPresenter(localizer: germanLocalizer()).results(
      outcome,
      criteria: try makeProfile().criteria
    )

    XCTAssertEqual(presentation.points.count, 1)
    XCTAssertEqual(presentation.points[0].title, "McDonald's")
    XCTAssertEqual(presentation.points[0].summary, "8 Ladepunkte · 150 kW oder höher")
    XCTAssertEqual(
      presentation.points[0].detailSummary,
      "Operator · 8 Ladepunkte\n8 Ladepunkte · 150 kW oder höher\nMcDonald's · 100 m"
    )
  }

  private func makeProfile(foodChain: FoodChain? = .mcdonalds) throws -> UserProfile {
    try UserProfile(
      id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
      name: "Langstrecke",
      destination: SavedDestination(
        displayName: "Berlin Hauptbahnhof",
        coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694)
      ),
      criteria: RideCriteria(
        distanceRange: .kilometers100To150,
        minimumChargingPoints: .eight,
        minimumPower: .oneHundredFifty,
        foodChain: foodChain
      ),
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
  }

  private func makeResult(
    id: String,
    name: String,
    drivingMeters: Int,
    knownAvailable: Int,
    unknown: Int
  ) throws -> RouteSearchResult {
    let coordinate = try Coordinate(latitude: 52, longitude: 10)
    let availability = try ParkAvailability(
      knownAvailableCount: knownAvailable,
      knownUnavailableCount: 4 - knownAvailable - unknown,
      unknownCount: unknown,
      totalCount: 4
    )
    let source = try DataSourceReference(
      sourceID: "authority",
      sourceRecordID: id,
      qualityTier: .authority,
      observedAt: Date(timeIntervalSince1970: 0),
      fetchedAt: Date(timeIntervalSince1970: 0)
    )
    let park = try ChargingPark(
      id: UUID(uuidString: id)!,
      name: name,
      coordinate: coordinate,
      navigationCoordinate: coordinate,
      operatorChargingPoints: [
        try OperatorChargingPointSummary(name: "Operator", chargingPointCount: 4)
      ],
      chargingPointCount: 4,
      availability: availability,
      maximumPower: Kilowatts(150),
      sourceReferences: [source]
    )
    return RouteSearchResult(
      candidate: EnrichedChargingParkCandidate(
        park: park,
        distanceFromRoute: Meters(1_000),
        actualDrivingDistance: Meters(drivingMeters),
        foodPOIs: []
      ),
      matchingFoodPOI: nil
    )
  }

  private func germanLocalizer() -> CarPlayLocalizer {
    let values = [
      "carplay.ride.title": "Fahrt",
      "ride.search.action": "Ladeparks suchen",
      "profile.distance_range": "Ladestopp",
      "profile.minimum_charging_points": "Mindestens Ladepunkte",
      "profile.minimum_power": "Mindestleistung",
      "profile.restaurant.title": "Restaurant",
      "profile.restaurant.not_required": "Kein Restaurant erforderlich",
      "search.distance_range.100_150_km": "100–150 km",
      "unit.minimum_count.format": "mindestens %lld",
      "unit.kilowatts.format": "%lld kW",
      "unit.minimum_kilowatts.format": "%lld kW oder höher",
      "unit.kilometers.format": "%lld km",
      "search.food_chain.mcdonalds": "McDonald's",
      "carplay.result.route_distance.format": "%lld km von der Route",
      "carplay.result.charging_summary.format": "%lld Ladepunkte · %@",
      "carplay.result.food.format": "%@ · %lld m",
      "carplay.result.operator.format": "%@ · %lld Ladepunkte",
      "ride.result.availability.complete.format": "%lld Ladepunkte frei",
      "ride.result.availability.partial.format": "%lld sicher frei, %lld unbekannt",
      "ride.result.navigate": "In Apple Maps öffnen",
      "ride.results.title": "Passende Ladeparks",
      "carplay.coverage.degraded": "Live-Daten teilweise verfügbar",
      "carplay.coverage.stale": "Ladedaten nicht aktuell",
    ]
    return CarPlayLocalizer(locale: Locale(identifier: "de_DE")) { key in
      values[key] ?? key
    }
  }
}
