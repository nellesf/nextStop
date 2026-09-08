import CarPlay
import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class CarPlayPresentationTests: XCTestCase {
  func testSearchStatusTemplateIsReusedAcrossRepeatedRetries() {
    let root = CPListTemplate(title: "Profile", sections: [])
    let summary = CPListTemplate(title: "Fahrt", sections: [])
    var hierarchy: [CPTemplate] = [root, summary]
    var store = CarPlaySearchTemplateStore()

    for attempt in 0..<20 {
      let resolution = store.resolve(in: hierarchy) {
        CPListTemplate(title: "Suche \(attempt)", sections: [])
      }
      if resolution.requiresPush {
        hierarchy.append(resolution.template)
      }
    }

    XCTAssertEqual(hierarchy.count, 3)
    XCTAssertTrue(hierarchy.last === store.current)
  }

  func testSearchStatusTemplateIsReplacedAfterLeavingTheHierarchy() {
    let root = CPListTemplate(title: "Profile", sections: [])
    let summary = CPListTemplate(title: "Fahrt", sections: [])
    var hierarchy: [CPTemplate] = [root, summary]
    var store = CarPlaySearchTemplateStore()
    let first = store.resolve(in: hierarchy) {
      CPListTemplate(title: "Erste Suche", sections: [])
    }
    hierarchy.append(first.template)
    hierarchy.removeLast()

    let second = store.resolve(in: hierarchy) {
      CPListTemplate(title: "Zweite Suche", sections: [])
    }

    XCTAssertTrue(first.requiresPush)
    XCTAssertTrue(second.requiresPush)
    XCTAssertFalse(first.template === second.template)
  }

  func testSearchStatusTemplateIsNotReusedWhileAnotherTemplateIsVisible() {
    let root = CPListTemplate(title: "Profile", sections: [])
    let summary = CPListTemplate(title: "Fahrt", sections: [])
    var hierarchy: [CPTemplate] = [root, summary]
    var store = CarPlaySearchTemplateStore()
    let first = store.resolve(in: hierarchy) {
      CPListTemplate(title: "Suche", sections: [])
    }
    hierarchy.append(first.template)
    hierarchy.append(CPListTemplate(title: "Optionen", sections: []))

    let second = store.resolve(in: hierarchy) {
      CPListTemplate(title: "Neue Suche", sections: [])
    }

    XCTAssertTrue(second.requiresPush)
    XCTAssertFalse(first.template === second.template)
  }

  func testRetryAndResultRefreshSequenceKeepsHierarchyBounded() {
    let root = CPListTemplate(title: "Profile", sections: [])
    let summary = CPListTemplate(title: "Fahrt", sections: [])
    var hierarchy: [CPTemplate] = [root, summary]
    var store = CarPlaySearchTemplateStore()

    for attempt in 0..<20 {
      let retry = store.resolve(in: hierarchy) {
        CPListTemplate(title: "Suche \(attempt)", sections: [])
      }
      if retry.requiresPush {
        hierarchy.append(retry.template)
      }
    }
    XCTAssertEqual(hierarchy.count, 3)

    hierarchy = [root, summary]
    store.clear()
    hierarchy.append(CPListTemplate(title: "Treffer", sections: []))
    XCTAssertEqual(hierarchy.count, 3)

    hierarchy = [root, summary]
    let refresh = store.resolve(in: hierarchy) {
      CPListTemplate(title: "Neue Suche", sections: [])
    }
    hierarchy.append(refresh.template)

    XCTAssertTrue(refresh.requiresPush)
    XCTAssertEqual(hierarchy.count, 3)
  }

  func testTemplateTransitionGateRejectsOverlappingAndStaleCompletions() throws {
    var gate = CarPlayTemplateTransitionGate()
    let first = try XCTUnwrap(gate.begin())

    XCTAssertTrue(gate.isActive)
    XCTAssertNil(gate.begin())

    gate.reset()
    let second = try XCTUnwrap(gate.begin())

    XCTAssertFalse(gate.finish(first))
    XCTAssertTrue(gate.isActive(second))
    XCTAssertTrue(gate.finish(second))
    XCTAssertFalse(gate.isActive)
  }

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
    XCTAssertEqual(summary.searchActionTitle, "Suche starten")
    XCTAssertEqual(summary.searchActionDetail, "Mit den aktuellen Filtern")
    XCTAssertEqual(summary.editActionTitle, "Filter ändern")
    XCTAssertEqual(summary.editActionDetail, "Nur für diese Fahrt")
    XCTAssertEqual(summary.criteriaSummaryTitle, "100–150 km · mind. 8 Ladepunkte")
    XCTAssertEqual(summary.criteriaSummaryDetail, "ab 150 kW · McDonald's")
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
    XCTAssertEqual(
      presenter.rideSummary(draft).criteriaSummaryDetail,
      "ab 150 kW · Ohne Restaurantfilter"
    )
  }

  func testRideSummaryReflectsDraftEditsWithoutChangingSavedProfile() throws {
    let profile = try makeProfile()
    let controller = CarPlayRideDraftController()
    controller.select(profile: profile)

    controller.apply(.distanceRange(.kilometers50To100))
    controller.apply(.minimumChargingPoints(.four))
    controller.apply(.minimumPower(.threeHundredFifty))
    controller.apply(.foodChain(nil))

    let draft = try XCTUnwrap(controller.draft)
    let summary = CarPlayPresenter(localizer: germanLocalizer()).rideSummary(draft)
    XCTAssertEqual(summary.criteriaSummaryTitle, "50–100 km · mind. 4 Ladepunkte")
    XCTAssertEqual(summary.criteriaSummaryDetail, "ab 350 kW · Ohne Restaurantfilter")
    XCTAssertEqual(draft.sourceProfileID, profile.id)
    XCTAssertEqual(profile.criteria.distanceRange, .kilometers100To150)
    XCTAssertEqual(profile.criteria.minimumChargingPoints, .eight)
    XCTAssertEqual(profile.criteria.minimumPower, .oneHundredFifty)
    XCTAssertEqual(profile.criteria.foodChain, .mcdonalds)
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

    XCTAssertEqual(presentation.title, "Passende Ladestopps")
    XCTAssertEqual(presentation.points.map(\.title), ["Ladepark Eins", "Ladepark Zwei"])
    XCTAssertEqual(presentation.points.map(\.id), [first.id, second.id])
    XCTAssertEqual(presentation.points[0].coordinate, first.candidate.park.navigationCoordinate)
    XCTAssertEqual(presentation.points[0].subtitle, "80 km Fahrstrecke · 4 Ladepunkte")
    XCTAssertEqual(presentation.points[0].summary, "Operator")
    XCTAssertEqual(presentation.points[1].summary, "Operator")
    XCTAssertEqual(
      presentation.points[0].detailSummary,
      "4 passende Ladepunkte\nOperator · 4 Ladepunkte\n150 kW oder höher\n2 sicher frei, 2 unbekannt"
    )
    XCTAssertEqual(
      presentation.points[1].detailSummary,
      "4 passende Ladepunkte\nOperator · 4 Ladepunkte\n150 kW oder höher"
    )
    XCTAssertEqual(
      presentation.points[1].detailSubtitle,
      "90 km Fahrstrecke"
    )
    XCTAssertEqual(presentation.points[0].operatorsActionTitle, "Ladeanbieter")
    XCTAssertNil(presentation.points[0].restaurantActionTitle)
    XCTAssertEqual(presentation.coverageMessage, "Live-Daten teilweise verfügbar")
    XCTAssertEqual(presentation.attributionMessage, "© OpenStreetMap contributors")
  }

  func testRestaurantResultCombinesMemberParksAndOperatorsOnce() throws {
    let first = try makeResult(
      id: "10000000-0000-4000-8000-000000000001",
      name: "Ladepark Eins",
      drivingMeters: 80_000,
      knownAvailable: 0,
      unknown: 4,
      operators: [
        try OperatorChargingPointSummary(name: "EnBW mobility+", chargingPointCount: 2),
        try OperatorChargingPointSummary(name: "IONITY", chargingPointCount: 2),
      ]
    )
    let second = try makeResult(
      id: "10000000-0000-4000-8000-000000000002",
      name: "Ladepark Zwei",
      drivingMeters: 81_000,
      knownAvailable: 0,
      unknown: 4,
      operators: [
        try OperatorChargingPointSummary(name: "EnBW mobility+", chargingPointCount: 1),
        try OperatorChargingPointSummary(name: "Aral pulse", chargingPointCount: 3),
      ]
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

    let presenter = CarPlayPresenter(localizer: germanLocalizer())
    let presentation = presenter.results(
      outcome,
      criteria: try makeProfile().criteria
    )

    XCTAssertEqual(presentation.points.count, 1)
    XCTAssertEqual(presentation.points[0].title, "McDonald's")
    XCTAssertEqual(presentation.points[0].coordinate, foodPOI.coordinate)
    XCTAssertEqual(presentation.points[0].subtitle, "80 km Fahrstrecke · 8 Ladepunkte")
    XCTAssertEqual(presentation.points[0].summary, "Aral pulse · EnBW mobility+ · + 1 weiterer")
    XCTAssertEqual(
      presentation.points[0].detailSubtitle,
      "80 km Fahrstrecke"
    )
    XCTAssertEqual(
      presentation.points[0].detailSummary,
      "8 passende Ladepunkte\nAral pulse · 3 Ladepunkte\nEnBW mobility+ · 3 Ladepunkte\nIONITY · 2 Ladepunkte\n150 kW oder höher"
    )
    XCTAssertEqual(presentation.points[0].restaurantActionTitle, "Zum Restaurant")
    XCTAssertEqual(
      presenter.operators(for: groupedResult),
      [
        CarPlayOperatorPresentation(
          name: "Aral pulse", detail: "3 Ladepunkte · In Apple Maps öffnen"
        ),
        CarPlayOperatorPresentation(
          name: "EnBW mobility+", detail: "3 Ladepunkte · In Apple Maps öffnen"
        ),
        CarPlayOperatorPresentation(
          name: "IONITY", detail: "2 Ladepunkte · In Apple Maps öffnen"
        ),
      ]
    )
    XCTAssertNil(presentation.coverageMessage)
    XCTAssertNil(presentation.attributionMessage)
  }

  func testOverviewCompactsProvidersWithoutRemovingAnyFromDetailsOrSelection() throws {
    let result = try makeResult(
      id: "10000000-0000-4000-8000-000000000001",
      name: "Ladepark",
      drivingMeters: 109_499,
      knownAvailable: 4,
      unknown: 0,
      operators: [
        try OperatorChargingPointSummary(name: "Tesla", chargingPointCount: 1),
        try OperatorChargingPointSummary(name: "IONITY", chargingPointCount: 1),
        try OperatorChargingPointSummary(name: "EnBW mobility+", chargingPointCount: 1),
        try OperatorChargingPointSummary(name: "Aral pulse", chargingPointCount: 1),
      ]
    )
    let outcome = RideCandidateSearchOutcome(
      results: [result],
      coverage: CandidateSearchCoverage(
        status: .stale,
        activeSourceIDs: ["bundesnetzagentur_ladesaeulenregister"],
        unavailableSourceIDs: [],
        projectionUpdatedAt: Date(timeIntervalSince1970: 0)
      )
    )
    let presenter = CarPlayPresenter(localizer: germanLocalizer())

    let presentation = presenter.results(outcome, criteria: try makeProfile().criteria)
    let point = try XCTUnwrap(presentation.points.first)

    XCTAssertEqual(point.subtitle, "109 km Fahrstrecke · 4 Ladepunkte")
    XCTAssertEqual(point.summary, "Aral pulse · EnBW mobility+ · + 2 weitere")
    XCTAssertEqual(
      point.detailSummary,
      "4 passende Ladepunkte\nAral pulse · 1 Ladepunkt\nEnBW mobility+ · 1 Ladepunkt\nIONITY · 1 Ladepunkt\nTesla · 1 Ladepunkt\n150 kW oder höher\n4 Ladepunkte frei"
    )
    XCTAssertEqual(
      presenter.operators(for: result).map(\.name),
      ["Aral pulse", "EnBW mobility+", "IONITY", "Tesla"]
    )
    XCTAssertEqual(
      presenter.operators(for: result).map(\.detail),
      Array(repeating: "1 Ladepunkt · In Apple Maps öffnen", count: 4)
    )
    XCTAssertEqual(presentation.coverageMessage, "Ladedaten nicht aktuell")
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
    unknown: Int,
    operators: [OperatorChargingPointSummary]? = nil
  ) throws -> RouteSearchResult {
    let coordinate = try Coordinate(latitude: 52, longitude: 10)
    let chargingOperators =
      try operators ?? [
        OperatorChargingPointSummary(name: "Operator", chargingPointCount: 4)
      ]
    let chargingPointCount = chargingOperators.reduce(0) { $0 + $1.chargingPointCount }
    let availability = try ParkAvailability(
      knownAvailableCount: knownAvailable,
      knownUnavailableCount: chargingPointCount - knownAvailable - unknown,
      unknownCount: unknown,
      totalCount: chargingPointCount
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
      operatorChargingPoints: chargingOperators,
      chargingPointCount: chargingPointCount,
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
      "carplay.search.action": "Suche starten",
      "carplay.search.action.detail": "Mit den aktuellen Filtern",
      "carplay.filters.action": "Filter ändern",
      "carplay.filters.action.detail": "Nur für diese Fahrt",
      "carplay.criteria.summary.title.format": "%@ · mind. %lld Ladepunkte",
      "carplay.criteria.summary.detail.format": "ab %lld kW · %@",
      "carplay.criteria.no_restaurant": "Ohne Restaurantfilter",
      "profile.distance_range": "Ladestopp",
      "profile.minimum_charging_points": "Mindestens Ladepunkte",
      "profile.minimum_power": "Mindestleistung",
      "profile.restaurant.title": "Restaurant",
      "profile.restaurant.not_required": "Kein Restaurant erforderlich",
      "search.distance_range.100_150_km": "100–150 km",
      "search.distance_range.50_100_km": "50–100 km",
      "unit.minimum_count.format": "mindestens %lld",
      "unit.kilowatts.format": "%lld kW",
      "unit.minimum_kilowatts.format": "%lld kW oder höher",
      "unit.kilometers.format": "%lld km",
      "unit.charging_points.one": "%lld Ladepunkt",
      "unit.charging_points.other": "%lld Ladepunkte",
      "search.food_chain.mcdonalds": "McDonald's",
      "carplay.result.metrics.format": "%lld km Fahrstrecke · %@",
      "carplay.result.driving_distance.format": "%lld km Fahrstrecke",
      "carplay.result.operator.format": "%@ · %@",
      "carplay.result.more_operators.one": "+ %lld weiterer",
      "carplay.result.more_operators.format": "+ %lld weitere",
      "carplay.result.operators.action": "Ladeanbieter",
      "carplay.result.restaurant.action": "Zum Restaurant",
      "carplay.operator.detail.format": "%@ · %@",
      "ride.result.matching_charging_points.format": "%lld passende Ladepunkte",
      "ride.result.availability.complete.format": "%lld Ladepunkte frei",
      "ride.result.availability.partial.format": "%lld sicher frei, %lld unbekannt",
      "ride.result.navigate": "In Apple Maps öffnen",
      "ride.results.screen.title": "Passende Ladestopps",
      "carplay.coverage.degraded": "Live-Daten teilweise verfügbar",
      "carplay.coverage.stale": "Ladedaten nicht aktuell",
    ]
    return CarPlayLocalizer(locale: Locale(identifier: "de_DE")) { key in
      values[key] ?? key
    }
  }
}
