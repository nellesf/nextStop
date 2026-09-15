// Hosted simulator fixture. Overlay only into the capture checkout test target.
import CarPlay
import CoreLocation
import Foundation
import MapKit
import NextStopCore
import SwiftData
import UIKit
import XCTest

@testable import NextStopApp

@MainActor
final class ProfileRepositoryTests: XCTestCase {
  func testCaptureWebsiteResultScreenshots() async throws {
    #if targetEnvironment(simulator)
      guard ProcessInfo.processInfo.environment["NEXTSTOP_CARPLAY_CAPTURE"] == "1" else {
        throw XCTSkip("CarPlay layout capture requires explicit simulator opt-in.")
      }
      executionTimeAllowance = 900
      let session = try CarPlayLayoutCaptureSession()
      do {
        try await session.capture()
      } catch {
        try? session.recordFailure(error)
        throw error
      }
    #else
      throw XCTSkip("CarPlay layout capture is supported only in the simulator.")
    #endif
  }

  func testPrepareCarPlayScreenshotProfile() throws {
    #if targetEnvironment(simulator)
      guard ProcessInfo.processInfo.environment["NEXTSTOP_CARPLAY_CAPTURE"] == "1" else {
        throw XCTSkip("The persistent screenshot fixture requires explicit opt-in.")
      }

      // Use the production schema and default persistent URL in the hosted app's
      // sandbox, exactly as the SwiftUI root and CarPlay scene do.
      let container = try ModelContainer(for: StoredProfile.self, StoredDestinationRecord.self)
      let repository = SwiftDataProfileRepository(modelContext: container.mainContext)
      guard
        try repository.fetchProfiles().isEmpty,
        try container.mainContext.fetchCount(FetchDescriptor<StoredDestinationRecord>()) == 0
      else {
        XCTFail("Screenshot preparation requires a fresh store; existing data is never deleted.")
        return
      }

      let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
      let profile = try UserProfile(
        id: UUID(uuidString: "B7303CD0-6EC3-4D25-8FD2-61F8CEDDCA00")!,
        name: "Leipzig",
        destination: SavedDestination(
          displayName: "Leipzig",
          coordinate: Coordinate(latitude: 51.3397, longitude: 12.3731),
          applePlaceIdentifier: nil,
          displayAddress: "Leipzig, Deutschland"
        ),
        criteria: RideCriteria(
          distanceRange: SearchConfiguration.defaultCriteria.distanceRange,
          minimumChargingPoints: .four,
          minimumPower: .oneHundredFifty,
          foodChain: .mcdonalds
        ),
        createdAt: timestamp,
        updatedAt: timestamp
      )
      try repository.save(profile)

      // Fetch through a separate context so validation does not reuse inserted
      // model instances from the writing context.
      let readback = SwiftDataProfileRepository(modelContext: ModelContext(container))
      XCTAssertEqual(try readback.fetchProfiles(), [profile])

      let attachment = XCTAttachment(
        string: """
          Fixture: public Leipzig example, prepared by an opt-in hosted unit test.
          Repository: unchanged SwiftDataProfileRepository.
          Store: production default persistent container in the simulator app sandbox.
          Profile ID: \(profile.id.uuidString)
          Destination: Leipzig, Deutschland (51.3397, 12.3731).
          Criteria: default distance range, 150 kW, 4 EVSEs, McDonald's.
          Existing data: required empty; nothing deleted.
          """
      )
      attachment.name = "carplay-screenshot-profile-fixture"
      attachment.lifetime = .keepAlways
      add(attachment)
    #else
      throw XCTSkip("Persistent screenshot fixtures are supported only in the iOS simulator.")
    #endif
  }
}

#if targetEnvironment(simulator)
  private struct CarPlayLayoutCaptureFailure: Error, CustomStringConvertible {
    let description: String
  }

  @MainActor
  private final class CarPlayLayoutCaptureSession {
    private let directory: URL
    private let deadline = Date().addingTimeInterval(900)
    private var screenshotCount = 0
    private var currentPhase = "initializing"

    init() throws {
      directory = try FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    func capture() async throws {
      let container = try ModelContainer(for: StoredProfile.self, StoredDestinationRecord.self)
      let repository = SwiftDataProfileRepository(modelContext: container.mainContext)
      let profile = try exampleProfile()
      let existing = try repository.fetchProfiles()
      try require(existing.isEmpty || existing == [profile], "Unexpected persistent profile data.")
      if existing.isEmpty { try repository.save(profile) }
      let fixture = CarPlayLayoutCandidatePageFixture(directory: directory)
      try fixture.writeMetadata()

      if carPlayScene() == nil {
        try await phase(
          "waiting-for-carplay", display: "external", action: "click", label: "nextStop")
      }
      try await wait("CarPlay scene connection") { self.carPlayScene() != nil }
      let scene = try XCTUnwrap(carPlayScene())
      let delegate = try XCTUnwrap(scene.delegate as? NextStopCarPlaySceneDelegate)
      delegate.receiveSceneDependencies(NextStopSceneDependencies(candidatePageSearcher: fixture))
      let controller = scene.interfaceController
      let profiles = try XCTUnwrap(controller.rootTemplate as? CPListTemplate)
      try await phase(
        "carplay-profiles", display: "external", file: "carplay-profiles.png",
        expected: ["Fahrt wählen", profile.name])
      let profileItem = try item(named: profile.name, in: profiles)
      try await invoke(profileItem)
      try await wait("CarPlay ride summary") {
        controller.topTemplate !== profiles && controller.topTemplate is CPListTemplate
      }
      let summary = try XCTUnwrap(controller.topTemplate as? CPListTemplate)
      let presentation = CarPlayPresenter().rideSummary(RideSearchDraft(profile: profile))
      try await phase(
        "carplay-ride-summary", display: "external", file: "carplay-ride-summary.png",
        expected: [
          presentation.destination, presentation.searchActionTitle,
          presentation.editActionTitle,
        ])
      try await invoke(item(named: presentation.editActionTitle, in: summary))
      try await wait("CarPlay criteria") {
        controller.topTemplate !== summary && controller.topTemplate is CPListTemplate
      }
      let criteria = try XCTUnwrap(controller.topTemplate as? CPListTemplate)
      try await phase(
        "carplay-criteria", display: "external", file: "carplay-criteria.png",
        expected: ["Filter", "Ladestopp"])
      let optionPhases: [(CarPlayCriteriaField, String, String)] = [
        (.distanceRange, "carplay-options-distance-range", "km"),
        (.minimumChargingPoints, "carplay-options-charging-points", "Ladepunkte"),
        (.minimumPower, "carplay-options-power", "kW"),
        (.foodChain, "carplay-options-food-chain", "Restaurant"),
      ]
      for (field, phaseName, readinessAnchor) in optionPhases {
        let criterion = try XCTUnwrap(presentation.criteria.first { $0.field == field })
        try await invoke(item(named: criterion.title, in: criteria))
        try await wait("CarPlay options for \(criterion.title)") {
          controller.topTemplate !== criteria
            && (controller.topTemplate as? CPListTemplate)?.title == criterion.title
        }
        try await phase(
          phaseName, display: "external", file: "\(phaseName).png",
          expected: [readinessAnchor])
        // Back returns without selecting a new value or changing the ride draft.
        try await popTemplate(in: controller, returningTo: criteria)
      }
      try await popTemplate(in: controller, returningTo: summary)
      try await invoke(item(named: presentation.searchActionTitle, in: summary))
      try await wait("CarPlay search results") {
        (controller.topTemplate as? CPPointOfInterestTemplate)?.pointsOfInterest.isEmpty == false
      }
      let results = try XCTUnwrap(controller.topTemplate as? CPPointOfInterestTemplate)
      try fixture.recordPresentedPoints(results)
      try await phase(
        "carplay-results", display: "external", file: "carplay-results.png",
        expected: ["Ladepunkte", "Fahr"])

      let point = try XCTUnwrap(results.pointsOfInterest.first)
      results.selectedIndex = 0
      delegate.pointOfInterestTemplate(results, didSelectPointOfInterest: point)
      try await phase(
        "carplay-result-actions", display: "external", file: "carplay-result-actions.png",
        expected: ["Ladean", "Restaurant"])
      try await phase(
        "carplay-open-charging-places", display: "external",
        action: "click", label: "Ladeanbieter")
      try await wait("CarPlay charging-provider selection") {
        (controller.topTemplate as? CPListTemplate)?.title == "Ladeanbieter"
      }
      try await phase(
        "carplay-charging-places", display: "external", file: "carplay-charging-places.png",
        expected: ["Ladeanbieter", "Ladepunkte"])

      try writeState(["phase": "complete", "screenshots": screenshotCount])
      withExtendedLifetime(container) {}
    }

    func recordFailure(_ error: Error) throws {
      try writeState([
        "phase": "failed", "failedPhase": currentPhase, "error": String(describing: error),
      ])
    }

    private func exampleProfile() throws -> UserProfile {
      let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
      return try UserProfile(
        id: UUID(uuidString: "B7303CD0-6EC3-4D25-8FD2-61F8CEDDCA00")!, name: "Leipzig",
        destination: SavedDestination(
          displayName: "Leipzig", coordinate: Coordinate(latitude: 51.3397, longitude: 12.3731),
          displayAddress: "Leipzig, Deutschland"),
        criteria: RideCriteria(
          distanceRange: SearchConfiguration.defaultCriteria.distanceRange,
          minimumChargingPoints: .four, minimumPower: .oneHundredFifty, foodChain: .mcdonalds),
        createdAt: timestamp, updatedAt: timestamp)
    }

    private func carPlayScene() -> CPTemplateApplicationScene? {
      UIApplication.shared.connectedScenes.compactMap { $0 as? CPTemplateApplicationScene }
        .first { $0.activationState == .foregroundActive }
    }

    private func item(named name: String, in template: CPListTemplate) throws -> CPListItem {
      try XCTUnwrap(
        template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
          .first { $0.text == name })
    }

    @MainActor
    private final class HandlerCompletion {
      var hasCompleted = false
    }

    private func invoke(_ item: CPListItem) async throws {
      let handler = try XCTUnwrap(item.handler)
      let completion = HandlerCompletion()
      handler(item) {
        Task { @MainActor in
          completion.hasCompleted = true
        }
      }
      // A template can become topTemplate before its push animation completes.
      // The app releases its transition gate before calling this completion;
      // await that signal so the next action cannot be silently discarded.
      try await wait("handler completion for \(item.text ?? "CarPlay item")") {
        completion.hasCompleted
      }
    }

    @MainActor
    private final class TemplatePopCompletion {
      var hasCompleted = false
      var succeeded = false
      var failureDescription: String?
    }

    private func popTemplate(
      in controller: CPInterfaceController, returningTo template: CPTemplate
    ) async throws {
      let completion = TemplatePopCompletion()
      controller.popTemplate(animated: false) { succeeded, error in
        let failureDescription = error?.localizedDescription
        Task { @MainActor in
          completion.succeeded = succeeded
          completion.failureDescription = failureDescription
          completion.hasCompleted = true
        }
      }
      try await wait("CarPlay Back completion") { completion.hasCompleted }
      try require(
        completion.succeeded,
        completion.failureDescription ?? "CarPlay did not complete the Back transition.")
      try await wait("CarPlay previous template") { controller.topTemplate === template }
    }

    private func phase(
      _ name: String, display: String, file: String? = nil, expected: [String] = [],
      action: String? = nil, label: String? = nil, ownerApp: String = "nextStop"
    ) async throws {
      currentPhase = name
      var state: [String: Any] = [
        "phase": name, "display": display, "expected": expected, "ownerApp": ownerApp,
      ]
      if let file {
        state["file"] = file
        let content = templateContent(carPlayScene()?.interfaceController.topTemplate)
        state["templateContent"] = content.metadata
        state["expectedTexts"] = content.texts
        state["textAuditScope"] =
          "Template strings include scrollable content; OCR absence requires visual review. "
          + "Readiness anchors do not prove that complete strings fit."
      }
      if let action { state["action"] = action }
      if let label { state["label"] = label }
      try writeState(state)
      try await wait("host acknowledgement for \(name)") {
        let commandURL = self.directory.appendingPathComponent("website-capture-command.json")
        guard let data = try? Data(contentsOf: commandURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return false }
        return object["phase"] == name && object["command"] == "continue"
      }
      if file != nil { screenshotCount += 1 }
    }

    private func templateContent(_ template: CPTemplate?) -> (
      metadata: [String: Any], texts: [String]
    ) {
      var metadata: [String: Any] = [:]
      var texts: [String] = []
      if let list = template as? CPListTemplate {
        let rows = list.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        let headers = list.sections.compactMap(\.header)
        let buttons = list.leadingNavigationBarButtons + list.trailingNavigationBarButtons
        metadata = [
          "kind": "CPListTemplate", "title": list.title ?? "", "sectionHeaders": headers,
          "rows": rows.map { ["text": $0.text ?? "", "detailText": $0.detailText ?? ""] },
          "navigationButtonTitles": buttons.compactMap(\.title),
        ]
        texts =
          [list.title].compactMap { $0 } + headers
          + rows.flatMap { [$0.text, $0.detailText].compactMap { $0 } }
          + buttons.compactMap(\.title)
      } else if let poi = template as? CPPointOfInterestTemplate {
        let buttons = poi.leadingNavigationBarButtons + poi.trailingNavigationBarButtons
        metadata = [
          "kind": "CPPointOfInterestTemplate", "title": poi.title,
          "selectedIndex": poi.selectedIndex,
          "points": poi.pointsOfInterest.map { point in
            [
              "title": point.title, "subtitle": point.subtitle ?? "",
              "summary": point.summary ?? "", "detailTitle": point.detailTitle ?? "",
              "detailSubtitle": point.detailSubtitle ?? "",
              "detailSummary": point.detailSummary ?? "",
              "primaryButtonTitle": point.primaryButton?.title ?? "",
              "secondaryButtonTitle": point.secondaryButton?.title ?? "",
            ]
          },
          "navigationButtonTitles": buttons.compactMap(\.title),
        ]
        texts = buttons.compactMap(\.title)
        if poi.pointsOfInterest.indices.contains(poi.selectedIndex) {
          let point = poi.pointsOfInterest[poi.selectedIndex]
          texts += [
            point.detailTitle, point.detailSubtitle, point.detailSummary,
            point.primaryButton?.title, point.secondaryButton?.title,
          ].compactMap { $0 }
        } else {
          texts +=
            [poi.title]
            + poi.pointsOfInterest.flatMap { point in
              [point.title, point.subtitle, point.summary].compactMap { $0 }
            }
        }
      }
      return (metadata, texts.filter { !$0.isEmpty })
    }

    private func writeState(_ value: [String: Any]) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("website-capture-state.json"), options: .atomic)
    }

    private func wait(_ description: String, until condition: () throws -> Bool) async throws {
      let phaseDeadline = min(deadline, Date().addingTimeInterval(180))
      while try !condition() {
        guard Date() < phaseDeadline else {
          throw CarPlayLayoutCaptureFailure(description: "Timed out waiting for \(description).")
        }
        try await Task.sleep(for: .milliseconds(300))
      }
    }

    private func require(_ value: Bool, _ description: String) throws {
      if !value { throw CarPlayLayoutCaptureFailure(description: description) }
    }
  }

  @MainActor
  private final class CarPlayLayoutCandidatePageFixture: CandidatePageSearching {
    private struct DiscoveredPlace {
      let restaurant: MKMapItem
      let charger: MKMapItem
      let id: UUID
    }

    private let directory: URL
    private let fetchedAt = Date()
    private var discovered: [DiscoveredPlace] = []
    private var queries: [[String: Any]] = []
    private var pages: [[String: Any]] = []
    private var presentedPoints: [[String: Any]] = []

    init(directory: URL) {
      self.directory = directory
    }

    func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
      if discovered.isEmpty { try await discoverPlaces() }
      let origin = try Coordinate(latitude: 49.4521, longitude: 11.0767)
      let routeStart = try XCTUnwrap(request.route.coordinates.first)
      guard distance(origin, routeStart) < 1_000 else {
        throw CarPlayLayoutCaptureFailure(
          description: "The real route does not start at the Nürnberg example location.")
      }
      var candidates: [BackendCandidate] = []
      var pageMetadata: [[String: Any]] = []
      for place in discovered {
        let chargerCoordinate = try coordinate(place.charger)
        let restaurantCoordinate = try coordinate(place.restaurant)
        let corridorDistance = distanceToRoute(chargerCoordinate, route: request.route)
        let foodDistance = distance(chargerCoordinate, restaurantCoordinate)
        // Leave a margin for integer rounding and the spherical corridor metric;
        // no borderline point is admitted to the production 5 km / 500 m filters.
        guard corridorDistance < 4_500, foodDistance < 490 else { continue }
        let name = place.charger.name ?? "EV charging"
        let restaurantID = stablePlaceID(place.restaurant)
        let food = try FoodPOI(
          id: restaurantID, applePlaceIdentifier: applePlaceID(place.restaurant), chain: .mcdonalds,
          name: place.restaurant.name ?? "McDonald's", coordinate: restaurantCoordinate,
          distanceFromPark: Meters(Int(foodDistance.rounded(.up))), openingStatus: .unknown)
        let lookup = try ChargingLocationLookup(
          id: place.id, operatorName: name, coordinate: chargerCoordinate,
          address: ChargingLocationAddress(
            street: place.charger.placemark.thoroughfare,
            houseNumber: place.charger.placemark.subThoroughfare,
            postalCode: place.charger.placemark.postalCode,
            city: place.charger.placemark.locality))
        let park = try ChargingPark(
          id: place.id, name: name, coordinate: chargerCoordinate,
          navigationCoordinate: chargerCoordinate,
          operatorChargingPoints: [OperatorChargingPointSummary(name: name, chargingPointCount: 8)],
          chargingPointCount: 8,
          availability: ParkAvailability(
            knownAvailableCount: 0, knownUnavailableCount: 0, unknownCount: 8, totalCount: 8),
          maximumPower: Kilowatts(150),
          sourceReferences: [
            DataSourceReference(
              sourceID: "website_example_fixture", sourceRecordID: stablePlaceID(place.charger),
              qualityTier: .community, observedAt: nil, fetchedAt: fetchedAt)
          ], locationLookups: [lookup])
        // The fixed public origin is within 1 km of the MapKit route's snapped
        // start. Subtract that full tolerance to retain a conservative bound.
        let lowerBound = max(0, Int(distance(routeStart, chargerCoordinate).rounded(.down)) - 1_000)
        candidates.append(
          BackendCandidate(
            park: park, distanceFromRoute: Meters(Int(corridorDistance.rounded(.up))),
            straightLineLowerBound: Meters(lowerBound), foodPOIs: [food]))
        pageMetadata.append([
          "parkID": place.id.uuidString, "charger": describe(place.charger),
          "restaurant": describe(place.restaurant), "distanceFromRouteMeters": corridorDistance,
          "restaurantDistanceMeters": foodDistance,
          "exampleChargingPoints": 8, "exampleMinimumPowerKilowatts": 150,
          "availability": "unknown",
        ])
      }
      guard !candidates.isEmpty else {
        throw CarPlayLayoutCaptureFailure(
          description: "No real MapKit restaurant/charger pair lies within the route corridor.")
      }
      candidates.sort { $0.straightLineLowerBound < $1.straightLineLowerBound }
      pages.append([
        "requestID": request.requestID.uuidString,
        "routeCoordinateCount": request.route.coordinates.count,
        "routeDistanceMethod":
          "Spherical geodesic point-to-segment distance along the actual MapKit polyline",
        "candidates": pageMetadata,
      ])
      try writeMetadata()
      return CandidateSearchPage(
        snapshotToken: "website-example-\(Int(fetchedAt.timeIntervalSince1970))", nextCursor: nil,
        candidates: candidates,
        coverage: CandidateSearchCoverage(
          status: .complete, activeSourceIDs: ["website_example_fixture"],
          unavailableSourceIDs: [], projectionUpdatedAt: fetchedAt))
    }

    func recordPresentedPoints(_ template: CPPointOfInterestTemplate) throws {
      presentedPoints = template.pointsOfInterest.map { point in
        [
          "templateTitle": template.title,
          "title": point.title,
          "subtitle": point.subtitle ?? "",
          "summary": point.summary ?? "",
          "detailTitle": point.detailTitle ?? "",
          "detailSubtitle": point.detailSubtitle ?? "",
          "detailSummary": point.detailSummary ?? "",
        ]
      }
      try writeMetadata()
    }

    func writeMetadata() throws {
      let value: [String: Any] = [
        "fixtureType": "Provider-only example EVSE counts and power at live MapKit places",
        "sourceCode":
          "Unchanged app UI, CarPlay templates, search coordinator, filters and MapKit routing",
        "exampleValues": ["chargingPointsPerAppleChargingPlace": 8, "powerKilowatts": 150],
        "availability": "Unknown; no live availability claim",
        "locationNamesAndCoordinates": "Queried from Apple MapKit during this run",
        "drivingDistances": "Calculated by unchanged MapKit routing; never fixture values",
        "sourceID": "website_example_fixture",
        "fetchedAt": ISO8601DateFormatter().string(from: fetchedAt),
        "queries": queries, "candidatePages": pages, "presentedCarPlayPoints": presentedPoints,
        "captureScope": [
          "Profiles, ride summary, criteria, all four option lists, results, detail and operators",
          "Every screen uses the production CarPlay templates and unchanged localized strings",
          "No iPhone screens or Apple Maps place handoff are captured",
          "Option lists return with the public Back API without changing selected criteria",
        ],
      ]
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(
          to: directory.appendingPathComponent("website-capture-fixture.json"), options: .atomic)
    }

    private func discoverPlaces() async throws {
      let towns: [(String, CLLocationCoordinate2D)] = [
        ("Pegnitz", CLLocationCoordinate2D(latitude: 49.7548, longitude: 11.5374)),
        ("Bayreuth", CLLocationCoordinate2D(latitude: 49.9456, longitude: 11.5713)),
        ("Himmelkron", CLLocationCoordinate2D(latitude: 50.0637, longitude: 11.5986)),
      ]
      var seenRestaurants = Set<String>()
      var seenChargers = Set<String>()
      for (town, center) in towns {
        let query = "McDonald's \(town)"
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
          center: center, latitudinalMeters: 15_000, longitudinalMeters: 15_000)
        request.resultTypes = .pointOfInterest
        let restaurantItems = try await searchPlaces(
          MKLocalSearch(request: request), query: query, kind: "restaurant")
        let restaurants = restaurantItems.filter { item in
          let letters = (item.name ?? "").lowercased().filter(\.isLetter)
          return letters.contains("mcdonald")
            && location(item).distance(
              from: CLLocation(latitude: center.latitude, longitude: center.longitude)) < 15_000
        }.prefix(2)
        for restaurant in restaurants {
          guard seenRestaurants.insert(stablePlaceID(restaurant)).inserted else { continue }
          let poiRequest = MKLocalPointsOfInterestRequest(
            center: location(restaurant).coordinate, radius: 500)
          poiRequest.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
          let chargingItems = try await searchPlaces(
            MKLocalSearch(request: poiRequest),
            query: "EV chargers within 500 m of \(restaurant.name ?? town)", kind: "evCharger")
          let chargers = chargingItems.filter {
            $0.pointOfInterestCategory == .evCharger
              && location($0).distance(from: location(restaurant)) < 490
          }.sorted {
            location($0).distance(from: location(restaurant))
              < location($1).distance(from: location(restaurant))
          }
          for charger in chargers.prefix(2) {
            guard seenChargers.insert(stablePlaceID(charger)).inserted else { continue }
            discovered.append(DiscoveredPlace(restaurant: restaurant, charger: charger, id: UUID()))
          }
        }
      }
      guard !discovered.isEmpty else {
        throw CarPlayLayoutCaptureFailure(
          description: "MapKit returned no McDonald's/EV-charger pair within 500 m.")
      }
    }

    private func searchPlaces(_ search: MKLocalSearch, query: String, kind: String) async throws
      -> [MKMapItem]
    {
      do {
        let items = try await search.start().mapItems
        queries.append(["query": query, "kind": kind, "items": items.map(describe)])
        try writeMetadata()
        return items
      } catch {
        let nsError = error as NSError
        queries.append([
          "query": query, "kind": kind, "errorDomain": nsError.domain, "errorCode": nsError.code,
        ])
        try writeMetadata()
        if nsError.domain == MKErrorDomain, nsError.code == MKError.Code.placemarkNotFound.rawValue
        {
          return []
        }
        throw error
      }
    }

    private func location(_ item: MKMapItem) -> CLLocation {
      if #available(iOS 26.0, *) { return item.location }
      return CLLocation(
        latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude
      )
    }

    private func coordinate(_ item: MKMapItem) throws -> Coordinate {
      let value = location(item).coordinate
      return try Coordinate(latitude: value.latitude, longitude: value.longitude)
    }

    private func applePlaceID(_ item: MKMapItem) -> String? {
      if #available(iOS 18.4, *) { return item.identifier?.rawValue }
      return nil
    }

    private func stablePlaceID(_ item: MKMapItem) -> String {
      applePlaceID(item)
        ?? "\(item.name ?? ""):\(location(item).coordinate.latitude),\(location(item).coordinate.longitude)"
    }

    private func describe(_ item: MKMapItem) -> [String: Any] {
      [
        "name": item.name ?? "", "applePlaceID": applePlaceID(item) ?? "",
        "latitude": location(item).coordinate.latitude,
        "longitude": location(item).coordinate.longitude,
        "category": item.pointOfInterestCategory?.rawValue ?? "",
        "address": item.placemark.title ?? "",
      ]
    }

    private func distance(_ first: Coordinate, _ second: Coordinate) -> Double {
      CLLocation(latitude: first.latitude, longitude: first.longitude).distance(
        from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }

    private func distanceToRoute(_ point: Coordinate, route: RoutePolyline) -> Double {
      let radius = 6_371_008.8
      func angle(_ first: Coordinate, _ second: Coordinate) -> Double {
        let a = first.latitude * .pi / 180
        let b = second.latitude * .pi / 180
        let deltaLatitude = b - a
        let deltaLongitude = (second.longitude - first.longitude) * .pi / 180
        let h = pow(sin(deltaLatitude / 2), 2) + cos(a) * cos(b) * pow(sin(deltaLongitude / 2), 2)
        return 2 * asin(min(1, sqrt(max(0, h))))
      }
      func bearing(_ first: Coordinate, _ second: Coordinate) -> Double {
        let a = first.latitude * .pi / 180
        let b = second.latitude * .pi / 180
        let delta = (second.longitude - first.longitude) * .pi / 180
        return atan2(sin(delta) * cos(b), cos(a) * sin(b) - sin(a) * cos(b) * cos(delta))
      }
      var minimum = Double.infinity
      for (start, end) in zip(route.coordinates, route.coordinates.dropFirst()) {
        let segment = angle(start, end)
        let toPoint = angle(start, point)
        let difference = bearing(start, point) - bearing(start, end)
        let along = atan2(sin(toPoint) * cos(difference), cos(toPoint))
        let meters: Double
        if segment > 0, along >= 0, along <= segment {
          meters = abs(asin(max(-1, min(1, sin(toPoint) * sin(difference))))) * radius
        } else {
          meters = min(angle(start, point), angle(end, point)) * radius
        }
        minimum = min(minimum, meters)
      }
      return minimum
    }
  }
#endif
