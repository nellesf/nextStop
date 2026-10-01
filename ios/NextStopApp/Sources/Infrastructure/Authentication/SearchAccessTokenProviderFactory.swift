import Foundation

enum SearchAccessTokenProviderFactory {
  @MainActor
  static func make(
    baseURL: URL,
    session: URLSession = .shared,
    bundle: Bundle = .main,
    launchEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    service: (any AppAttestServicing)? = nil
  ) -> any SearchAccessTokenProviding {
    guard let value = bundle.object(forInfoDictionaryKey: "NextStopAppAttestEnvironment") as? String,
      let environment = AppAttestEnvironment(rawValue: value)
    else { return InvalidConfigurationAccessTokenProvider() }

    let bundleIdentifier = bundle.bundleIdentifier ?? "de.nextstop.app"
    let keyStore = KeychainAppAttestKeyStore(
      bundleIdentifier: bundleIdentifier,
      environment: environment,
      baseURL: baseURL
    )

    #if DEBUG && targetEnvironment(simulator)
      let fallback = SimulatorSearchAccessTokenProvider(
        brokerURL: BackendEnvironmentConfiguration.brokerURL(for: baseURL, environment: launchEnvironment),
        session: session
      )
      return AppAttestSearchAccessTokenProvider(
        service: service ?? DCAppAttestServiceAdapter(),
        keyStore: keyStore,
        client: AppAttestAuthenticationClient(baseURL: baseURL, session: session),
        unsupportedFallback: fallback
      )
    #else
      return AppAttestSearchAccessTokenProvider(
        service: service ?? DCAppAttestServiceAdapter(),
        keyStore: keyStore,
        client: AppAttestAuthenticationClient(baseURL: baseURL, session: session)
      )
    #endif
  }
}

private struct InvalidConfigurationAccessTokenProvider: SearchAccessTokenProviding {
  func accessToken(forceRefresh: Bool) async throws -> String {
    throw SearchAccessTokenProviderError.invalidConfiguration
  }
}
