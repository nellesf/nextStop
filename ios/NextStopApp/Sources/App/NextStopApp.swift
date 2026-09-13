import AppIntents
import SwiftData
import SwiftUI

@main
struct NextStopApp: App {
  @UIApplicationDelegateAdaptor(NextStopAppDelegate.self)
  private var appDelegate
  @StateObject private var rideIntentRouter: RideIntentRouter
  private let directionsRequestGate: DirectionsRequestGate

  @MainActor
  init() {
    let router = RideIntentRouter()
    _rideIntentRouter = StateObject(wrappedValue: router)
    directionsRequestGate = DirectionsRequestGate()
    #if DEBUG && targetEnvironment(simulator)
      // UI tests navigate through the normal root but never register a live
      // MapKit-backed intent dependency.
      if UITestSupport.isRequested() { return }
    #endif
    let rideIntentHandler = RideIntentHandler(
      destinationSearcher: MapKitDestinationSearchService(),
      router: router
    )
    AppDependencyManager.shared.add(dependency: rideIntentHandler)
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG && targetEnvironment(simulator)
        if let testSupport = appDelegate.uiTestSupport {
          profileListView
            .modelContainer(testSupport.modelContainer)
            .preferredColorScheme(testSupport.preferredColorScheme)
        } else {
          persistentProfileListView
        }
      #else
        persistentProfileListView
      #endif
    }
  }

  private var profileListView: some View {
    ProfileListView(
      rideIntentRouter: rideIntentRouter,
      directionsRequestGate: directionsRequestGate,
      candidatePageSearcher: appDelegate.candidatePageSearcher,
      diagnosticsStore: appDelegate.diagnosticsStore,
      errorReportSender: appDelegate.errorReportSender,
      errorReportReceipts: appDelegate.errorReportReceipts
    )
  }

  private var persistentProfileListView: some View {
    profileListView.modelContainer(for: [StoredProfile.self, StoredDestinationRecord.self])
  }
}

extension Color {
  static let nextStopHighlight = Color(red: 0.78, green: 1, blue: 0.18)
}
