import Foundation
import UIKit

@MainActor
final class NextStopAppDelegate: NSObject, UIApplicationDelegate {
  let candidatePageSearcher: any CandidatePageSearching

  override init() {
    let session = URLSession.shared
    let baseURL = HTTPCandidateSearchService.configuredBaseURL()
    let accessTokenProvider = baseURL.map {
      SearchAccessTokenProviderFactory.make(baseURL: $0, session: session)
    }
    candidatePageSearcher = HTTPCandidateSearchService(
      baseURL: baseURL,
      accessTokenProvider: accessTokenProvider,
      session: session
    )
    super.init()
  }

  init(candidatePageSearcher: any CandidatePageSearching) {
    self.candidatePageSearcher = candidatePageSearcher
    super.init()
  }
}
