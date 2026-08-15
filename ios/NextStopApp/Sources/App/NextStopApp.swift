import AppIntents
import SwiftData
import SwiftUI

@main
struct NextStopApp: App {
  @StateObject private var rideIntentRouter: RideIntentRouter

  init() {
    let router = RideIntentRouter()
    _rideIntentRouter = StateObject(wrappedValue: router)
    AppDependencyManager.shared.add(
      dependency: RideIntentHandler(
        destinationSearcher: MapKitDestinationSearchService(),
        router: router
      )
    )
    NextStopAppShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      ProfileListView(rideIntentRouter: rideIntentRouter)
    }
    .modelContainer(for: [StoredProfile.self, StoredDestinationRecord.self])
  }
}
