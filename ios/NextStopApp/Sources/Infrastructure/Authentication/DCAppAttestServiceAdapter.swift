import DeviceCheck
import Foundation

enum AppAttestEnvironment: String, Sendable {
  case development
  case production
}

enum AppAttestServiceError: Error, Equatable {
  case invalidKey
  case serverUnavailable
  case unsupported
  case other
}

@MainActor
protocol AppAttestServicing: AnyObject, Sendable {
  var isSupported: Bool { get }
  func generateKey() async throws -> String
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

@MainActor
final class DCAppAttestServiceAdapter: AppAttestServicing {
  private let service: DCAppAttestService

  init(service: DCAppAttestService = .shared) {
    self.service = service
  }

  var isSupported: Bool { service.isSupported }

  func generateKey() async throws -> String {
    do {
      return try await service.generateKey()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.map(error)
    }
  }

  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    do {
      return try await service.attestKey(keyID, clientDataHash: clientDataHash)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.map(error)
    }
  }

  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    do {
      return try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.map(error)
    }
  }

  private static func map(_ error: any Error) -> AppAttestServiceError {
    let nsError = error as NSError
    guard nsError.domain == DCErrorDomain,
      let code = DCError.Code(rawValue: nsError.code)
    else {
      return .other
    }
    switch code {
    case .invalidKey:
      return .invalidKey
    case .serverUnavailable:
      return .serverUnavailable
    case .featureUnsupported:
      return .unsupported
    case .invalidInput, .unknownSystemFailure:
      return .other
    @unknown default:
      return .other
    }
  }
}
