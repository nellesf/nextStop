import AppIntents
import SwiftData
import SwiftUI

@main
struct NextStopApp: App {
  @StateObject private var rideIntentRouter: RideIntentRouter

  @MainActor
  init() {
    let router = RideIntentRouter()
    _rideIntentRouter = StateObject(wrappedValue: router)
    let rideIntentHandler = RideIntentHandler(
      destinationSearcher: MapKitDestinationSearchService(),
      router: router
    )
    AppDependencyManager.shared.add(dependency: rideIntentHandler)
    NextStopAppShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      ProfileListView(rideIntentRouter: rideIntentRouter)
    }
    .modelContainer(for: [StoredProfile.self, StoredDestinationRecord.self])
  }
}
