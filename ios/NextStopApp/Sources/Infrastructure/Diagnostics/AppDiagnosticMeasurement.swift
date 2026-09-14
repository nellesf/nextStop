import CoreLocation
import Foundation
import MapKit

/// Measures failed operations without retaining their inputs or raw error payloads.
@MainActor
struct AppDiagnosticMeasurement {
  typealias Now = @MainActor () -> Date

  let recorder: any AppDiagnosticRecording
  var now: Now = Date.init

  func perform<Value>(
    _ operation: AppDiagnosticOperation,
    action: @MainActor () async throws -> Value
  ) async throws -> Value {
    let startedAt = now()
    do {
      return try await action()
    } catch {
      let nsError = error as NSError
      // A cancelled search is a user action, not a reliability failure.
      guard !Task.isCancelled, !(error is CancellationError),
        !(nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue)
      else { throw error }
      recordFailure(operation, startedAt: startedAt, error: error)
      throw error
    }
  }

  /// Boolean platform callbacks expose no raw error; keep their failure useful
  /// without inventing a reason or storing the selected place or launch URL.
  func recordFailure(
    _ operation: AppDiagnosticOperation, startedAt: Date, error: Error? = nil
  ) {
    let timestamp = now()
    let elapsed = timestamp.timeIntervalSince(startedAt) * 1_000
    let classification = error.map(Self.classify)
    recorder.record(
      AppDiagnosticEvent(
        timestamp: timestamp,
        operation: operation,
        outcome: .failure,
        category: classification?.category ?? .unknown,
        durationMilliseconds: elapsed.isFinite ? Int(min(max(elapsed, 0), 300_000)) : 0,
        errorDomain: classification?.domain,
        errorCode: classification?.code
      )
    )
  }

  private static func classify(_ error: Error) -> (
    category: AppDiagnosticCategory, domain: AppDiagnosticErrorDomain, code: Int?
  ) {
    if let routeError = error as? RoutePlanningError {
      // Stable diagnostic codes, independent of Swift's NSError enum bridging.
      let code =
        switch routeError {
        case .noRoute: 1
        case .invalidDistance: 2
        case .invalidTravelTime: 3
        case .invalidPolyline: 4
        }
      return (routeError == .noRoute ? .noRoute : .invalidRoute, .routePlanning, code)
    }
    let nsError = error as NSError
    if nsError.domain == kCLErrorDomain {
      return (
        nsError.code == CLError.network.rawValue ? .connection : .unknown,
        .coreLocation,
        nsError.code
      )
    }
    if nsError.domain == MKErrorDomain {
      let category: AppDiagnosticCategory =
        switch nsError.code {
        case Int(MKError.directionsNotFound.rawValue): .noRoute
        case Int(MKError.loadingThrottled.rawValue): .throttled
        case Int(MKError.serverFailure.rawValue): .connection
        default: .unknown
        }
      return (category, .mapKit, nsError.code)
    }
    if nsError.domain == NSURLErrorDomain {
      let category: AppDiagnosticCategory =
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut: .networkTimeout
        case .networkConnectionLost: .networkLost
        case .notConnectedToInternet: .offline
        case .cannotConnectToHost, .dnsLookupFailed: .connection
        default: .unknown
        }
      return (category, .url, nsError.code)
    }
    return (.unknown, .unknown, nil)
  }
}
