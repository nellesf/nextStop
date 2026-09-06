import Foundation
import UIKit

@MainActor
final class NextStopSceneDependencies: NSObject {
  let candidatePageSearcher: any CandidatePageSearching

  init(candidatePageSearcher: any CandidatePageSearching) {
    self.candidatePageSearcher = candidatePageSearcher
  }
}

@MainActor
enum NextStopSceneDependencyBridge {
  static let userInfoKey = "de.nextstop.app.scene-dependencies"

  static func install(
    _ dependencies: NextStopSceneDependencies,
    in session: UISceneSession
  ) {
    session.userInfo = userInfo(
      merging: session.userInfo,
      dependencies: dependencies
    )
  }

  static func dependencies(from session: UISceneSession) -> NextStopSceneDependencies? {
    dependencies(from: session.userInfo)
  }

  static func dependencies(from userInfo: [String: Any]?) -> NextStopSceneDependencies? {
    userInfo?[userInfoKey] as? NextStopSceneDependencies
  }

  static func userInfo(
    merging existing: [String: Any]?,
    dependencies: NextStopSceneDependencies
  ) -> [String: Any] {
    var result = existing ?? [:]
    result[userInfoKey] = dependencies
    return result
  }
}

@MainActor
final class NextStopAppDelegate: NSObject, UIApplicationDelegate {
  let dependencies: NextStopSceneDependencies

  var candidatePageSearcher: any CandidatePageSearching {
    dependencies.candidatePageSearcher
  }

  override init() {
    let session = URLSession.shared
    let baseURL = HTTPCandidateSearchService.configuredBaseURL()
    let accessTokenProvider = baseURL.map {
      SearchAccessTokenProviderFactory.make(baseURL: $0, session: session)
    }
    let candidatePageSearcher = HTTPCandidateSearchService(
      baseURL: baseURL,
      accessTokenProvider: accessTokenProvider,
      session: session
    )
    dependencies = NextStopSceneDependencies(candidatePageSearcher: candidatePageSearcher)
    super.init()
  }

  init(candidatePageSearcher: any CandidatePageSearching) {
    dependencies = NextStopSceneDependencies(candidatePageSearcher: candidatePageSearcher)
    super.init()
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    NextStopSceneDependencyBridge.install(dependencies, in: connectingSceneSession)
    return connectingSceneSession.configuration
  }
}
