import Combine
import Foundation
import NextStopCore

struct PreparedRideSearch: Equatable {
  let origin: Coordinate
  let route: PlannedRoute
  let request: RouteSearchRequest
}

enum RidePreparationFailure: Equatable {
  case locationPermissionDenied
  case locationRestricted
  case preciseLocationRequired
  case locationUnavailable
  case routeUnavailable

  var localizationKey: String {
    switch self {
    case .locationPermissionDenied:
      "ride.error.location_denied"
    case .locationRestricted:
      "ride.error.location_restricted"
    case .preciseLocationRequired:
      "ride.error.precise_location"
    case .locationUnavailable:
      "ride.error.location_unavailable"
    case .routeUnavailable:
      "ride.error.route_unavailable"
    }
  }

  var canOpenSettings: Bool {
    switch self {
    case .locationPermissionDenied, .preciseLocationRequired:
      true
    case .locationRestricted, .locationUnavailable, .routeUnavailable:
      false
    }
  }
}

enum RidePreparationState: Equatable {
  case idle
  case requestingLocation
  case calculatingRoute
  case ready(PreparedRideSearch)
  case failed(RidePreparationFailure)
}

@MainActor
final class RidePreparationViewModel: ObservableObject {
  let draft: RideSearchDraft

  @Published private(set) var state: RidePreparationState = .idle

  private let locationProvider: any CurrentLocationProviding
  private let routePlanner: any RoutePlanning
  private let makeRequestID: () -> UUID

  init(
    draft: RideSearchDraft,
    locationProvider: any CurrentLocationProviding,
    routePlanner: any RoutePlanning,
    makeRequestID: @escaping () -> UUID = UUID.init
  ) {
    self.draft = draft
    self.locationProvider = locationProvider
    self.routePlanner = routePlanner
    self.makeRequestID = makeRequestID
  }

  func prepareRoute() async {
    guard state.canPrepare else {
      return
    }

    state = .requestingLocation

    do {
      let origin = try await locationProvider.currentLocation()
      try Task.checkCancellation()

      state = .calculatingRoute
      let route = try await routePlanner.automobileRoute(
        from: origin,
        to: draft.destination.coordinate
      )
      try Task.checkCancellation()

      let request = RouteSearchRequest(
        requestID: makeRequestID(),
        route: route.polyline,
        criteria: draft.criteria
      )
      state = .ready(
        PreparedRideSearch(
          origin: origin,
          route: route,
          request: request
        )
      )
    } catch is CancellationError {
      state = .idle
    } catch let error as CurrentLocationError {
      state = .failed(Self.mapLocationError(error))
    } catch {
      state = .failed(.routeUnavailable)
    }
  }

  private static func mapLocationError(_ error: CurrentLocationError) -> RidePreparationFailure {
    switch error {
    case .authorizationDenied:
      .locationPermissionDenied
    case .authorizationRestricted:
      .locationRestricted
    case .reducedAccuracy:
      .preciseLocationRequired
    case .requestAlreadyInProgress, .unavailable:
      .locationUnavailable
    }
  }
}

extension RidePreparationState {
  fileprivate var canPrepare: Bool {
    switch self {
    case .idle, .failed:
      true
    case .requestingLocation, .calculatingRoute, .ready:
      false
    }
  }
}
