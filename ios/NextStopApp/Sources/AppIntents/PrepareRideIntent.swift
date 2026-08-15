import AppIntents
import NextStopCore

@MainActor
final class RideIntentHandler {
  private let destinationSearcher: any DestinationSearching
  private let router: RideIntentRouter

  init(
    destinationSearcher: any DestinationSearching,
    router: RideIntentRouter
  ) {
    self.destinationSearcher = destinationSearcher
    self.router = router
  }

  func prepareRide(destinationQuery: String) async throws -> SavedDestination? {
    guard
      let destination = try await destinationSearcher.search(query: destinationQuery)
        .first?.destination
    else {
      return nil
    }
    router.openRide(to: destination)
    return destination
  }
}

struct PrepareRideIntent: AppIntent {
  static let title: LocalizedStringResource = "Prepare a ride"
  static let description = IntentDescription(
    "Searches for a destination and opens the ride preparation."
  )
  static let supportedModes: IntentModes = [.foreground(.immediate)]

  @Parameter(title: "Destination")
  var destination: String

  @Dependency
  private var handler: RideIntentHandler

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    do {
      guard try await handler.prepareRide(destinationQuery: destination) != nil else {
        return .result(dialog: IntentDialog("No matching destination was found."))
      }
      return .result(dialog: IntentDialog("Destination found. Opening ride preparation."))
    } catch {
      return .result(dialog: IntentDialog("Destination search is currently unavailable."))
    }
  }
}

struct NextStopAppShortcuts: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PrepareRideIntent(),
      phrases: [
        "Prepare a ride with \(.applicationName)",
        "Find charging parks with \(.applicationName)",
      ],
      shortTitle: "Prepare a ride",
      systemImageName: "bolt.car"
    )
  }

  static let shortcutTileColor: ShortcutTileColor = .green
}
