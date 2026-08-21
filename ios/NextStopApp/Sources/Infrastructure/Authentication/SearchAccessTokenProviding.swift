import Foundation

enum SearchAccessTokenProviderError: Error, Equatable {
  case invalidConfiguration
  case unsupported
  case invalidResponse
  case unavailable
}

protocol SearchAccessTokenProviding: Sendable {
  func accessToken(forceRefresh: Bool) async throws -> String
}
