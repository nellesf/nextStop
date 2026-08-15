import Combine
import NextStopCore

@MainActor
final class RideIntentRouter: ObservableObject {
  @Published private(set) var pendingDestination: SavedDestination?

  func openRide(to destination: SavedDestination) {
    pendingDestination = destination
  }

  func consumePendingDestination() {
    pendingDestination = nil
  }
}
