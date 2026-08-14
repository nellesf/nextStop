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

enum RideCandidateSearchFailure: Equatable {
  case serviceUnavailable
  case responseInvalid
  case drivingDistancesUnavailable
  case foodSearchUnavailable

  var localizationKey: String {
    switch self {
    case .serviceUnavailable:
      "ride.search.error.service"
    case .responseInvalid:
      "ride.search.error.response"
    case .drivingDistancesUnavailable:
      "ride.search.error.driving"
    case .foodSearchUnavailable:
      "ride.search.error.food"
    }
  }
}

enum RideCandidateSearchState: Equatable {
  case idle
  case searching
  case results([RouteSearchResult])
  case noResults
  case failed(RideCandidateSearchFailure)
}

@MainActor
final class RidePreparationViewModel: ObservableObject {
  let draft: RideSearchDraft

  @Published private(set) var state: RidePreparationState = .idle
  @Published private(set) var candidateSearchState: RideCandidateSearchState = .idle

  private let locationProvider: any CurrentLocationProviding
  private let routePlanner: any RoutePlanning
  private let makeRequestID: () -> UUID
  private let candidateSearcher: (any RideCandidateSearching)?

  init(
    draft: RideSearchDraft,
    locationProvider: any CurrentLocationProviding,
    routePlanner: any RoutePlanning,
    candidateSearcher: (any RideCandidateSearching)? = nil,
    makeRequestID: @escaping () -> UUID = UUID.init
  ) {
    self.draft = draft
    self.locationProvider = locationProvider
    self.routePlanner = routePlanner
    self.candidateSearcher = candidateSearcher
    self.makeRequestID = makeRequestID
  }

  func searchCandidates() async {
    guard case .ready(let preparedRide) = state,
      candidateSearchState.canSearch,
      let candidateSearcher
    else {
      return
    }
    candidateSearchState = .searching
    do {
      let results = try await candidateSearcher.search(preparedRide: preparedRide)
      try Task.checkCancellation()
      candidateSearchState = results.isEmpty ? .noResults : .results(results)
    } catch is CancellationError {
      candidateSearchState = .idle
    } catch let error as RideCandidateSearchError {
      candidateSearchState = .failed(Self.mapCandidateSearchError(error))
    } catch {
      candidateSearchState = .failed(.serviceUnavailable)
    }
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

  private static func mapCandidateSearchError(
    _ error: RideCandidateSearchError
  ) -> RideCandidateSearchFailure {
    switch error {
    case .candidateServiceUnavailable:
      .serviceUnavailable
    case .candidateResponseInvalid:
      .responseInvalid
    case .drivingDistancesUnavailable:
      .drivingDistancesUnavailable
    case .foodSearchUnavailable:
      .foodSearchUnavailable
    }
  }
}

extension RideCandidateSearchState {
  fileprivate var canSearch: Bool {
    switch self {
    case .idle, .results, .noResults, .failed:
      true
    case .searching:
      false
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
