@preconcurrency import CoreLocation
import NextStopCore

@MainActor
final class CoreLocationProvider: NSObject, CurrentLocationProviding {
  private let locationManager: CLLocationManager
  private var authorizationContinuation: CheckedContinuation<Void, any Error>?
  private var locationContinuation: CheckedContinuation<Coordinate, any Error>?

  override init() {
    locationManager = CLLocationManager()
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
  }

  func currentLocation() async throws -> Coordinate {
    guard authorizationContinuation == nil, locationContinuation == nil else {
      throw CurrentLocationError.requestAlreadyInProgress
    }

    try await authorizeIfNeeded()
    return try await withCheckedThrowingContinuation { continuation in
      locationContinuation = continuation
      locationManager.requestLocation()
    }
  }

  private func authorizeIfNeeded() async throws {
    switch locationManager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      return
    case .denied:
      throw CurrentLocationError.authorizationDenied
    case .restricted:
      throw CurrentLocationError.authorizationRestricted
    case .notDetermined:
      try await withCheckedThrowingContinuation { continuation in
        authorizationContinuation = continuation
        locationManager.requestWhenInUseAuthorization()
      }
    @unknown default:
      throw CurrentLocationError.unavailable
    }
  }

  private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
    guard let continuation = authorizationContinuation else {
      return
    }

    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      authorizationContinuation = nil
      continuation.resume()
    case .denied:
      authorizationContinuation = nil
      continuation.resume(throwing: CurrentLocationError.authorizationDenied)
    case .restricted:
      authorizationContinuation = nil
      continuation.resume(throwing: CurrentLocationError.authorizationRestricted)
    case .notDetermined:
      break
    @unknown default:
      authorizationContinuation = nil
      continuation.resume(throwing: CurrentLocationError.unavailable)
    }
  }

  private func handleLocations(_ locations: [CLLocation]) {
    guard let continuation = locationContinuation else {
      return
    }
    locationContinuation = nil

    guard let location = locations.last,
      let coordinate = try? Coordinate(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude
      )
    else {
      continuation.resume(throwing: CurrentLocationError.unavailable)
      return
    }
    continuation.resume(returning: coordinate)
  }

  private func handleLocationError() {
    guard let continuation = locationContinuation else {
      return
    }
    locationContinuation = nil
    continuation.resume(throwing: CurrentLocationError.unavailable)
  }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor [weak self] in
      self?.handleAuthorizationChange(status)
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    Task { @MainActor [weak self] in
      self?.handleLocations(locations)
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error)
  {
    Task { @MainActor [weak self] in
      self?.handleLocationError()
    }
  }
}
