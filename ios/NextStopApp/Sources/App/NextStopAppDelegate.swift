import Foundation
import UIKit

@MainActor
final class NextStopSceneDependencies {
  let candidatePageSearcher: any CandidatePageSearching
  let diagnostics: any AppDiagnosticRecording

  init(
    candidatePageSearcher: any CandidatePageSearching,
    diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics()
  ) {
    self.candidatePageSearcher = candidatePageSearcher
    self.diagnostics = diagnostics
  }
}

@MainActor
protocol NextStopSceneDependencyReceiving: AnyObject {
  func receiveSceneDependencies(_ dependencies: NextStopSceneDependencies)
}

@MainActor
final class NextStopAppDelegate: NSObject, UIApplicationDelegate {
  let dependencies: NextStopSceneDependencies
  let diagnosticsStore: AppDiagnosticsStore
  let errorReportSender: any UserErrorReportSending
  let errorReportReceipts: UserErrorReportReceiptStore
  #if DEBUG && targetEnvironment(simulator)
    private(set) var uiTestSupport: UITestSupport?
  #endif

  var candidatePageSearcher: any CandidatePageSearching {
    dependencies.candidatePageSearcher
  }

  override init() {
    #if DEBUG && targetEnvironment(simulator)
      do {
        if let testSupport = try UITestSupport.requested() {
          uiTestSupport = testSupport
          diagnosticsStore = testSupport.diagnostics
          errorReportReceipts = testSupport.receipts
          errorReportSender = testSupport.reportSender
          dependencies = NextStopSceneDependencies(
            candidatePageSearcher: testSupport.candidateSearcher,
            diagnostics: testSupport.diagnostics
          )
          super.init()
          return
        }
      } catch {
        // A misspelled test scenario must never open real stores or clients.
        fatalError("Unable to initialize isolated UI test dependencies")
      }
    #endif
    let diagnostics = AppDiagnosticsStore()
    diagnosticsStore = diagnostics
    let session = URLSession.shared
    let baseURL = HTTPCandidateSearchService.configuredBaseURL()
    let accessTokenProvider = baseURL.map {
      SearchAccessTokenProviderFactory.make(baseURL: $0, session: session)
    }
    let receipts = UserErrorReportReceiptStore()
    errorReportReceipts = receipts
    errorReportSender = HTTPUserErrorReportService(
      baseURL: baseURL,
      accessTokenProvider: accessTokenProvider,
      receiptStore: receipts
    )
    let candidatePageSearcher = HTTPCandidateSearchService(
      baseURL: baseURL,
      accessTokenProvider: accessTokenProvider,
      session: session,
      diagnostics: diagnostics
    )
    dependencies = NextStopSceneDependencies(
      candidatePageSearcher: candidatePageSearcher, diagnostics: diagnostics
    )
    super.init()
  }

  init(candidatePageSearcher: any CandidatePageSearching) {
    let diagnostics = AppDiagnosticsStore()
    diagnosticsStore = diagnostics
    let receipts = UserErrorReportReceiptStore()
    errorReportReceipts = receipts
    errorReportSender = HTTPUserErrorReportService(
      baseURL: nil, accessTokenProvider: nil, receiptStore: receipts
    )
    dependencies = NextStopSceneDependencies(
      candidatePageSearcher: candidatePageSearcher, diagnostics: diagnostics
    )
    super.init()
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(sceneDidActivate(_:)),
      name: UIScene.didActivateNotification,
      object: nil
    )
    return true
  }

  func injectDependencies(into sceneDelegate: Any?) {
    guard let receiver = sceneDelegate as? any NextStopSceneDependencyReceiving else {
      return
    }
    receiver.receiveSceneDependencies(dependencies)
  }

  @objc
  private func sceneDidActivate(_ notification: Notification) {
    guard let scene = notification.object as? UIScene else {
      return
    }
    injectDependencies(into: scene.delegate)
  }
}
