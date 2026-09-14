@preconcurrency import CoreLocation
import Foundation
import NextStopCore

@MainActor
final class CoreLocationProvider: NSObject, CurrentLocationProviding {
  private static let temporaryFullAccuracyPurposeKey = "RouteSearch"

  private let locationManager: CLLocationManager
  private let measurement: AppDiagnosticMeasurement
  private var authorizationContinuation: CheckedContinuation<Void, any Error>?
  private var accuracyContinuation: CheckedContinuation<Void, any Error>?
  private var locationContinuation: CheckedContinuation<Coordinate, any Error>?

  init(
    diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics(),
    now: @escaping AppDiagnosticMeasurement.Now = Date.init,
    locationManager: CLLocationManager = CLLocationManager()
  ) {
    self.locationManager = locationManager
    measurement = AppDiagnosticMeasurement(recorder: diagnostics, now: now)
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
  }

  func currentLocation() async throws -> Coordinate {
    try Task.checkCancellation()
    guard authorizationContinuation == nil, accuracyContinuation == nil,
      locationContinuation == nil
    else {
      throw CurrentLocationError.requestAlreadyInProgress
    }

    let startedAt = measurement.now()
    do {
      try await authorizeIfNeeded()
      try await requestFullAccuracyIfNeeded()
      let coordinate: Coordinate = try await withCheckedThrowingContinuation { continuation in
        locationContinuation = continuation
        locationManager.requestLocation()
      }
      try Task.checkCancellation()
      return coordinate
    } catch {
      let nsError = error as NSError
      if Task.isCancelled || error is CancellationError
        || (nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue)
      {
        throw CancellationError()
      }
      // Permission and precision are deliberate user choices, not defects.
      let isPermissionChoice =
        switch error as? CurrentLocationError {
        case .authorizationDenied, .authorizationRestricted, .reducedAccuracy: true
        default: nsError.domain == kCLErrorDomain && nsError.code == CLError.denied.rawValue
        }
      if !isPermissionChoice {
        measurement.recordFailure(.location, startedAt: startedAt, error: error)
      }
      throw error as? CurrentLocationError ?? .unavailable
    }
  }

  private func requestFullAccuracyIfNeeded() async throws {
    guard locationManager.accuracyAuthorization != .fullAccuracy else {
      return
    }

    try await withCheckedThrowingContinuation { continuation in
      accuracyContinuation = continuation
      locationManager.requestTemporaryFullAccuracyAuthorization(
        withPurposeKey: Self.temporaryFullAccuracyPurposeKey
      ) { [weak self] error in
        let requestFailed = error != nil
        Task { @MainActor [weak self] in
          self?.handleFullAccuracyResponse(requestFailed: requestFailed)
        }
      }
    }
  }

  private func handleFullAccuracyResponse(requestFailed: Bool) {
    guard let continuation = accuracyContinuation else {
      return
    }
    accuracyContinuation = nil

    if requestFailed {
      continuation.resume(throwing: CurrentLocationError.reducedAccuracy)
    } else if locationManager.accuracyAuthorization == .fullAccuracy {
      continuation.resume()
    } else {
      continuation.resume(throwing: CurrentLocationError.reducedAccuracy)
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

  private func handleLocationError(_ error: any Error) {
    guard let continuation = locationContinuation else {
      return
    }
    locationContinuation = nil
    // Keep the platform error only across this operation's continuation. The
    // caller receives the existing coarse app error after allowlisted recording.
    continuation.resume(throwing: error)
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
      self?.handleLocationError(error)
    }
  }
}
