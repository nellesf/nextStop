import AppIntents
import Foundation
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
  @Parameter(title: "Destination")
  var destination: String

  @Dependency
  private var handler: RideIntentHandler

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
    do {
      guard try await handler.prepareRide(destinationQuery: destination) != nil else {
        throw PrepareRideIntentError.destinationNotFound
      }
      return .result(
        opensIntent: OpenPreparedRideIntent(),
        dialog: IntentDialog("Destination found. Opening ride preparation.")
      )
    } catch let error as PrepareRideIntentError {
      throw error
    } catch {
      throw PrepareRideIntentError.searchUnavailable
    }
  }
}

private struct OpenPreparedRideIntent: AppIntent {
  static let title: LocalizedStringResource = "Open ride preparation"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    .result()
  }
}

private enum PrepareRideIntentError: LocalizedError {
  case destinationNotFound
  case searchUnavailable

  var errorDescription: String? {
    switch self {
    case .destinationNotFound:
      NSLocalizedString("No matching destination was found.", comment: "Siri destination error")
    case .searchUnavailable:
      NSLocalizedString(
        "Destination search is currently unavailable.",
        comment: "Siri destination service error"
      )
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

  static let shortcutTileColor: ShortcutTileColor = .lime
}
