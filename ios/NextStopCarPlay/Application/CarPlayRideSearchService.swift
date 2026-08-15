import CoreLocation
import Foundation
import NextStopCore

enum CarPlayRideSearchError: Error, Equatable {
  case phoneSetupRequired
  case locationUnavailable
  case routeUnavailable
  case dataPreparing
  case serviceUnavailable
  case snapshotExpired
  case responseInvalid
  case drivingDistancesUnavailable
  case foodSearchUnavailable
}

@MainActor
protocol CarPlayLocationReadinessChecking: AnyObject {
  var isReadyForRouteSearch: Bool { get }
}

@MainActor
final class SystemCarPlayLocationReadinessChecker: CarPlayLocationReadinessChecking {
  private let locationManager: CLLocationManager

  init(locationManager: CLLocationManager = CLLocationManager()) {
    self.locationManager = locationManager
  }

  var isReadyForRouteSearch: Bool {
    switch locationManager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      locationManager.accuracyAuthorization == .fullAccuracy
    case .denied, .restricted, .notDetermined:
      false
    @unknown default:
      false
    }
  }
}

@MainActor
protocol CarPlayRideSearchExecuting: AnyObject {
  func search(draft: RideSearchDraft) async throws -> RideCandidateSearchOutcome
}

@MainActor
final class CarPlayRideSearchService: CarPlayRideSearchExecuting {
  private let locationReadiness: any CarPlayLocationReadinessChecking
  private let locationProvider: any CurrentLocationProviding
  private let routePlanner: any RoutePlanning
  private let candidateSearcher: any RideCandidateSearching
  private let makeRequestID: () -> UUID

  init(
    locationReadiness: any CarPlayLocationReadinessChecking =
      SystemCarPlayLocationReadinessChecker(),
    locationProvider: any CurrentLocationProviding = CoreLocationProvider(),
    routePlanner: any RoutePlanning = MapKitRoutePlanner(),
    candidateSearcher: any RideCandidateSearching = RideCandidateSearchCoordinator(
      pageSearcher: HTTPCandidateSearchService(),
      enricher: MapKitCandidateEnricher()
    ),
    makeRequestID: @escaping () -> UUID = UUID.init
  ) {
    self.locationReadiness = locationReadiness
    self.locationProvider = locationProvider
    self.routePlanner = routePlanner
    self.candidateSearcher = candidateSearcher
    self.makeRequestID = makeRequestID
  }

  func search(draft: RideSearchDraft) async throws -> RideCandidateSearchOutcome {
    guard locationReadiness.isReadyForRouteSearch else {
      throw CarPlayRideSearchError.phoneSetupRequired
    }

    let origin: Coordinate
    do {
      origin = try await locationProvider.currentLocation()
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CarPlayRideSearchError.locationUnavailable
    }

    let route: PlannedRoute
    do {
      route = try await routePlanner.automobileRoute(
        from: origin,
        to: draft.destination.coordinate
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CarPlayRideSearchError.routeUnavailable
    }

    let preparedRide = PreparedRideSearch(
      origin: origin,
      route: route,
      request: RouteSearchRequest(
        requestID: makeRequestID(),
        route: route.polyline,
        criteria: draft.criteria
      )
    )

    do {
      return try await candidateSearcher.search(preparedRide: preparedRide)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RideCandidateSearchError {
      throw Self.map(error)
    } catch {
      throw CarPlayRideSearchError.serviceUnavailable
    }
  }

  private static func map(_ error: RideCandidateSearchError) -> CarPlayRideSearchError {
    switch error {
    case .candidateDataPreparing:
      .dataPreparing
    case .candidateServiceUnavailable:
      .serviceUnavailable
    case .candidateSnapshotExpired:
      .snapshotExpired
    case .candidateResponseInvalid:
      .responseInvalid
    case .drivingDistancesUnavailable:
      .drivingDistancesUnavailable
    case .foodSearchUnavailable:
      .foodSearchUnavailable
    }
  }
}
