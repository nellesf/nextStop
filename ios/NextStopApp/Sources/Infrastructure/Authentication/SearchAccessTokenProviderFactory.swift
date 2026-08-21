import Foundation

enum SearchAccessTokenProviderFactory {
  @MainActor
  static func make(
    baseURL: URL,
    session: URLSession = .shared,
    bundle: Bundle = .main,
    service: (any AppAttestServicing)? = nil
  ) -> any SearchAccessTokenProviding {
    let environment: AppAttestEnvironment
    #if DEBUG
      environment = .development
    #else
      environment = .production
    #endif

    let bundleIdentifier = bundle.bundleIdentifier ?? "de.nextstop.app"
    let keyStore = KeychainAppAttestKeyStore(
      bundleIdentifier: bundleIdentifier,
      environment: environment,
      baseURL: baseURL
    )

    #if DEBUG && targetEnvironment(simulator)
      let fallback = SimulatorSearchAccessTokenProvider(
        brokerURL: SimulatorSearchAccessTokenProvider.configuredBrokerURL(),
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
