import AppIntents
import SwiftData
import SwiftUI

@main
struct NextStopApp: App {
  @StateObject private var rideIntentRouter: RideIntentRouter
  private let directionsRequestGate: DirectionsRequestGate

  @MainActor
  init() {
    let router = RideIntentRouter()
    _rideIntentRouter = StateObject(wrappedValue: router)
    directionsRequestGate = DirectionsRequestGate()
    let rideIntentHandler = RideIntentHandler(
      destinationSearcher: MapKitDestinationSearchService(),
      router: router
    )
    AppDependencyManager.shared.add(dependency: rideIntentHandler)
  }

  var body: some Scene {
    WindowGroup {
      ProfileListView(
        rideIntentRouter: rideIntentRouter,
        directionsRequestGate: directionsRequestGate
      )
    }
    .modelContainer(for: [StoredProfile.self, StoredDestinationRecord.self])
  }
}

extension Color {
  static let nextStopHighlight = Color(red: 0.78, green: 1, blue: 0.18)
}
