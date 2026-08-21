#if DEBUG && targetEnvironment(simulator)
  import Foundation

  actor SimulatorSearchAccessTokenProvider: SearchAccessTokenProviding {
    static let defaultBrokerURL = URL(string: "http://127.0.0.1:9482/token")!
    private static let maximumResponseBytes = 16 * 1_024
    private static let refreshLeeway: TimeInterval = 60

    private let brokerURL: URL?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cachedToken: AppAttestAccessToken?
    private var refreshTask: Task<AppAttestAccessToken, any Error>?

    init(
      brokerURL: URL?,
      session: URLSession = .shared,
      now: @escaping @Sendable () -> Date = Date.init
    ) {
      self.brokerURL = Self.validatedLoopbackURL(brokerURL)
      self.session = session
      self.now = now
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
      if !forceRefresh,
        let cachedToken,
        cachedToken.expiresAt.timeIntervalSince(now()) > Self.refreshLeeway
      {
        return cachedToken.value
      }
      guard let brokerURL else {
        throw SearchAccessTokenProviderError.invalidConfiguration
      }

      if let refreshTask {
        do {
          let token = try await refreshTask.value
          try Task.checkCancellation()
          return token.value
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as SearchAccessTokenProviderError {
          throw error
        } catch {
          throw SearchAccessTokenProviderError.unavailable
        }
      }
      let task = Task {
        try await self.fetchToken(from: brokerURL, forceRefresh: forceRefresh)
      }
      refreshTask = task
      do {
        let token = try await task.value
        cachedToken = token
        refreshTask = nil
        try Task.checkCancellation()
        return token.value
      } catch {
        refreshTask = nil
        if error is CancellationError {
          throw CancellationError()
        }
        if let error = error as? SearchAccessTokenProviderError {
          throw error
        }
        throw SearchAccessTokenProviderError.unavailable
      }
    }

    private func fetchToken(
      from brokerURL: URL,
      forceRefresh: Bool
    ) async throws -> AppAttestAccessToken {
      var request = URLRequest(url: brokerURL)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("1", forHTTPHeaderField: "X-NextStop-Simulator-Auth")
      if forceRefresh {
        request.setValue("1", forHTTPHeaderField: "X-NextStop-Simulator-Force-Refresh")
      }
      request.timeoutInterval = 2

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await session.data(for: request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw SearchAccessTokenProviderError.unavailable
      }
      guard let response = response as? HTTPURLResponse,
        response.statusCode == 200,
        data.count <= Self.maximumResponseBytes,
        let dto = try? JSONDecoder().decode(TokenDTO.self, from: data),
        dto.tokenType == "Bearer",
        (61...900).contains(dto.expiresInSeconds),
        (32...2_048).contains(dto.accessToken.utf8.count),
        !dto.accessToken.contains(where: \.isWhitespace)
      else {
        throw SearchAccessTokenProviderError.invalidResponse
      }

      let token = AppAttestAccessToken(
        value: dto.accessToken,
        expiresAt: now().addingTimeInterval(TimeInterval(dto.expiresInSeconds))
      )
      return token
    }

    static func configuredBrokerURL() -> URL? {
      guard
        let override = ProcessInfo.processInfo.environment[
          "NEXTSTOP_DEBUG_SIMULATOR_TOKEN_BROKER_URL"
        ], !override.isEmpty
      else {
        return defaultBrokerURL
      }
      return URL(string: override)
    }

    static func validatedLoopbackURL(_ value: URL?) -> URL? {
      guard let value,
        value.scheme?.lowercased() == "http",
        value.user == nil,
        value.password == nil,
        value.query == nil,
        value.fragment == nil,
        value.path == "/token",
        value.host == "127.0.0.1" || value.host == "::1"
      else {
        return nil
      }
      return value
    }
  }

  private struct TokenDTO: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresInSeconds: Int
  }
#endif
