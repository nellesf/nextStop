import CarPlay
import CoreLocation
import Foundation
import MapKit
import NextStopCore
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import NextStopApp

@MainActor
final class ProfileRepositoryTests: XCTestCase {
  func testCaptureWebsiteResultScreenshots() async throws {
    #if targetEnvironment(simulator)
      guard ProcessInfo.processInfo.environment["NEXTSTOP_CARPLAY_CAPTURE"] == "1" else {
        throw XCTSkip("Website result capture requires explicit simulator opt-in.")
      }
      executionTimeAllowance = 900
      let session = try WebsiteResultCaptureSession()
      do {
        try await session.capture()
      } catch {
        try? session.recordFailure(error)
        throw error
      }
    #else
      throw XCTSkip("Website result capture is supported only in the simulator.")
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

  func testSwiftDataRepositoryCreatesUpdatesAndDeletesProfile() throws {
    let (container, repository) = try makeRepository()
    defer { withExtendedLifetime(container) {} }
    let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let original = try makeProfile(
      id: profileID,
      name: "Original",
      timestamp: firstTimestamp
    )

    try repository.save(original)
    XCTAssertEqual(try repository.fetchProfiles(), [original])

    let updated = try UserProfile(
      id: profileID,
      name: "Updated",
      destination: original.destination,
      criteria: RideCriteria(
        distanceRange: .kilometers100To150,
        minimumChargingPoints: .eight,
        minimumPower: .oneHundredFifty,
        foodChain: .mcdonalds
      ),
      createdAt: firstTimestamp,
      updatedAt: firstTimestamp.addingTimeInterval(60)
    )
    try repository.save(updated)

    XCTAssertEqual(try repository.fetchProfiles(), [updated])

    let withoutRestaurant = try UserProfile(
      id: profileID,
      name: "Updated",
      destination: original.destination,
      criteria: RideCriteria(
        distanceRange: updated.criteria.distanceRange,
        minimumChargingPoints: updated.criteria.minimumChargingPoints,
        minimumPower: updated.criteria.minimumPower,
        foodChain: nil
      ),
      createdAt: firstTimestamp,
      updatedAt: firstTimestamp.addingTimeInterval(120)
    )
    try repository.save(withoutRestaurant)

    XCTAssertEqual(try repository.fetchProfiles(), [withoutRestaurant])

    try repository.delete(id: profileID)
    XCTAssertTrue(try repository.fetchProfiles().isEmpty)
  }

  func testInMemoryRepositorySortsMostRecentlyUpdatedFirst() throws {
    let older = try makeProfile(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Older",
      timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let newer = try makeProfile(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      name: "Newer",
      timestamp: Date(timeIntervalSince1970: 1_700_000_060)
    )
    let repository = InMemoryProfileRepository(profiles: [older, newer])

    XCTAssertEqual(repository.fetchProfiles().map(\.id), [newer.id, older.id])
  }

  func testLegacyAvailabilityValueIsIgnoredWhenLoadingAProfile() throws {
    let (container, repository) = try makeRepository()
    let profile = try makeProfile(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Legacy",
      timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let stored = StoredProfile(profile: profile)
    stored.minimumAvailablePointsRawValue = 999
    container.mainContext.insert(stored)
    try container.mainContext.save()

    XCTAssertEqual(try repository.fetchProfiles(), [profile])
  }

  private func makeRepository() throws -> (ModelContainer, SwiftDataProfileRepository) {
    let schema = Schema([StoredProfile.self])
    let configuration = ModelConfiguration(
      "ProfileRepositoryTests-\(UUID().uuidString)",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let repository = SwiftDataProfileRepository(modelContext: container.mainContext)
    return (container, repository)
  }

  private func makeProfile(id: UUID, name: String, timestamp: Date) throws -> UserProfile {
    try UserProfile(
      id: id,
      name: name,
      destination: SavedDestination(
        displayName: "Hamburg",
        coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937),
        applePlaceIdentifier: "hamburg",
        displayAddress: "Hamburg, Deutschland"
      ),
      criteria: SearchConfiguration.defaultCriteria,
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }
}

#if targetEnvironment(simulator)
  private struct WebsiteCaptureFailure: Error, CustomStringConvertible {
    let description: String
  }

  @MainActor
  private final class WebsiteResultCaptureSession {
    private let directory: URL
    private let deadline = Date().addingTimeInterval(900)
    private var window: UIWindow?
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
      let fixture = WebsiteCandidatePageFixture(directory: directory)
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
      let profileItem = try item(named: profile.name, in: profiles)
      try await invoke(profileItem)
      try await wait("CarPlay ride summary") {
        controller.topTemplate !== profiles && controller.topTemplate is CPListTemplate
      }
      let summary = try XCTUnwrap(controller.topTemplate as? CPListTemplate)
      try await invoke(item(named: "Suche starten", in: summary))
      try await wait("CarPlay search results") {
        (controller.topTemplate as? CPPointOfInterestTemplate)?.pointsOfInterest.isEmpty == false
      }
      let results = try XCTUnwrap(controller.topTemplate as? CPPointOfInterestTemplate)
      try await phase(
        "carplay-results", display: "external", file: "carplay-results.png",
        expected: ["Passende Ladestopps", "Ladepunkte", "Fahrstrecke"])

      let point = try XCTUnwrap(results.pointsOfInterest.first)
      results.selectedIndex = 0
      delegate.pointOfInterestTemplate(results, didSelectPointOfInterest: point)
      try await phase(
        "carplay-result-actions", display: "external", file: "carplay-result-actions.png",
        expected: ["Ladeanbieter", "Zum Restaurant"])
      try await phase(
        "carplay-open-charging-places", display: "external",
        action: "click", label: "Ladeanbieter")
      try await wait("CarPlay charging-provider selection") {
        (controller.topTemplate as? CPListTemplate)?.title == "Ladeanbieter"
      }
      try await phase(
        "carplay-charging-places", display: "external", file: "carplay-charging-places.png",
        expected: ["Ladeanbieter", "Ladepunkte"])

      // The app delegate may restore production dependencies when the phone
      // foregrounds. CarPlay capture is complete before that transition.
      try await phase("activate-iphone", display: "internal", action: "activate-app")
      let phoneScene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .first { $0.session.role == .windowApplication })
      let routePlanner = RetryingRoutePlanner(
        base: RateLimitedRoutePlanner(base: MapKitRoutePlanner(), gate: DirectionsRequestGate()))
      let viewModel = RidePreparationViewModel(
        draft: RideSearchDraft(profile: profile),
        locationProvider: CoreLocationProvider(),
        routePlanner: routePlanner,
        candidateSearcher: RideCandidateSearchCoordinator(
          pageSearcher: fixture, enricher: MapKitCandidateEnricher(distanceProvider: routePlanner)))
      let hosting = UIHostingController(
        rootView: NavigationStack {
          RidePreparationView(viewModel: viewModel)
        }
        .preferredColorScheme(.light)
        .dynamicTypeSize(.large))
      let phoneWindow = UIWindow(windowScene: phoneScene)
      phoneWindow.overrideUserInterfaceStyle = .light
      phoneWindow.rootViewController = hosting
      window = phoneWindow
      phoneWindow.makeKeyAndVisible()
      try await wait("iPhone search result rendering") {
        switch viewModel.candidateSearchState {
        case .results: return true
        case .failed(let failure):
          throw WebsiteCaptureFailure(description: "iPhone search failed: \(failure)")
        case .noResults:
          throw WebsiteCaptureFailure(
            description: "No fixture locations passed the real route filters.")
        default:
          if case .failed(let failure) = viewModel.state {
            throw WebsiteCaptureFailure(description: "iPhone route failed: \(failure)")
          }
          return false
        }
      }
      guard case .results(let outcome) = viewModel.candidateSearchState else {
        throw WebsiteCaptureFailure(description: "The iPhone result state disappeared.")
      }
      try fixture.recordOutcome(outcome)
      try await phase(
        "iphone-results", display: "internal", file: "iphone-results.png",
        expected: ["Passende Ladestopps", "McDonald's", "Ladepunkte"])

      let selected = try XCTUnwrap(outcome.results.first)
      let restaurant = try XCTUnwrap(selected.matchingFoodPOI)
      let resolver = MapKitApplePlaceResolver()
      let resolvedRestaurant = await resolver.resolveRestaurantPlace(restaurant)
      let restaurantPlace = try XCTUnwrap(resolvedRestaurant)
      try fixture.recordResolvedPlace(restaurantPlace, kind: "restaurant")
      try require(
        AppleMapsLauncher().openPlace(restaurantPlace), "Apple Maps restaurant launch failed.")
      try await phase(
        "iphone-restaurant-place", display: "internal", file: "iphone-restaurant-place.png",
        expected: [restaurantPlace.name ?? restaurant.name], ownerApp: "Apple Maps")

      try await phase("return-to-iphone", display: "internal", action: "activate-app")
      let chargingOperator = try XCTUnwrap(selected.operatorChargingPoints.first)
      let park = try XCTUnwrap(selected.representativePark(for: chargingOperator.name))
      let related = AppleChargingPlaceLookupScope.restaurantGroupLocations(
        candidateLocations: selected.locationLookups, operatorName: chargingOperator.name)
      let group = AppleChargingPlaceResultGroup(
        id: "restaurant:\(restaurant.id)", kind: .restaurant,
        evidenceLocations: selected.locationLookups,
        searchCoordinates: selected.candidates.map(\.park.navigationCoordinate),
        restaurantCoordinate: restaurant.coordinate)
      let resolvedCharging = await resolver.resolveChargingPlace(
        park: park, operatorName: chargingOperator.name,
        relatedLocations: related, resultGroup: group)
      let chargingPlace = try XCTUnwrap(resolvedCharging)
      try fixture.recordResolvedPlace(chargingPlace, kind: "charging")
      try require(
        AppleMapsLauncher().openPlace(chargingPlace), "Apple Maps charging-place launch failed.")
      try await phase(
        "iphone-charging-place", display: "internal", file: "iphone-charging-place.png",
        expected: [chargingPlace.name ?? chargingOperator.name], ownerApp: "Apple Maps")
      try writeState(["phase": "complete", "screenshots": 6])
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

    private func phase(
      _ name: String, display: String, file: String? = nil, expected: [String] = [],
      action: String? = nil, label: String? = nil, ownerApp: String = "nextStop"
    ) async throws {
      currentPhase = name
      var state: [String: Any] = [
        "phase": name, "display": display, "expected": expected, "ownerApp": ownerApp,
      ]
      if let file { state["file"] = file }
      if let action { state["action"] = action }
      if let label { state["label"] = label }
      if ownerApp == "Apple Maps" { state["returnToAppAfterCapture"] = true }
      try writeState(state)
      try await wait("host acknowledgement for \(name)") {
        let commandURL = self.directory.appendingPathComponent("website-capture-command.json")
        guard let data = try? Data(contentsOf: commandURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return false }
        return object["phase"] == name && object["command"] == "continue"
      }
    }

    private func writeState(_ value: [String: Any]) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("website-capture-state.json"), options: .atomic)
    }

    private func wait(_ description: String, until condition: () throws -> Bool) async throws {
      let phaseDeadline = min(deadline, Date().addingTimeInterval(180))
      while try !condition() {
        guard Date() < phaseDeadline else {
          throw WebsiteCaptureFailure(description: "Timed out waiting for \(description).")
        }
        try await Task.sleep(for: .milliseconds(300))
      }
    }

    private func require(_ value: Bool, _ description: String) throws {
      if !value { throw WebsiteCaptureFailure(description: description) }
    }
  }

  @MainActor
  private final class WebsiteCandidatePageFixture: CandidatePageSearching {
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
    private var renderedResults: [[String: Any]] = []
    private var resolvedPlaces: [[String: Any]] = []

    init(directory: URL) {
      self.directory = directory
    }

    func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
      if discovered.isEmpty { try await discoverPlaces() }
      let origin = try Coordinate(latitude: 49.4521, longitude: 11.0767)
      let routeStart = try XCTUnwrap(request.route.coordinates.first)
      guard distance(origin, routeStart) < 1_000 else {
        throw WebsiteCaptureFailure(
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
        throw WebsiteCaptureFailure(
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

    func recordOutcome(_ outcome: RideCandidateSearchOutcome) throws {
      renderedResults = outcome.results.map { result in
        [
          "id": result.id.uuidString, "restaurant": result.matchingFoodPOI?.name ?? "",
          "actualMapKitDrivingDistanceMeters": result.candidate.actualDrivingDistance.value,
          "chargingPoints": result.chargingPointCount,
          "operators": result.operatorChargingPoints.map {
            ["name": $0.name, "exampleChargingPointCount": $0.chargingPointCount] as [String: Any]
          },
        ]
      }
      try writeMetadata()
    }

    func recordResolvedPlace(_ item: MKMapItem, kind: String) throws {
      var value = describe(item)
      value["kind"] = kind
      value["resolver"] = "unchanged MapKitApplePlaceResolver"
      resolvedPlaces.append(value)
      try writeMetadata()
    }

    func writeMetadata() throws {
      let value: [String: Any] = [
        "fixtureType": "Provider-only example EVSE counts and power at live MapKit places",
        "sourceCode":
          "Unchanged main app UI, search coordinator, filters, routing, resolver and launcher",
        "exampleValues": ["chargingPointsPerAppleChargingPlace": 8, "powerKilowatts": 150],
        "availability": "Unknown; no live availability claim",
        "locationNamesAndCoordinates": "Queried from Apple MapKit during this run",
        "drivingDistances": "Calculated by unchanged MapKit routing; never fixture values",
        "sourceID": "website_example_fixture",
        "fetchedAt": ISO8601DateFormatter().string(from: fetchedAt),
        "queries": queries, "candidatePages": pages, "renderedResults": renderedResults,
        "resolvedApplePlaces": resolvedPlaces,
        "captureLimitations": [
          [
            "scope": "Apple Maps place views on CarPlay",
            "environment": "GitHub macOS runner with iOS 26.5 Simulator",
            "observedRunURL": "https://github.com/nellesf/nextStop/actions/runs/34936686885",
            "observation":
              "The restaurant handoff returned success, but the CarPlay content remained blank "
              + "while the iPhone displayed the resolved place correctly.",
            "captureDecision":
              "Capture the three nextStop CarPlay views and three iPhone views; omit both "
              + "Apple Maps CarPlay place views. This observation does not establish a general "
              + "Simulator support limitation.",
          ]
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
        throw WebsiteCaptureFailure(
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
