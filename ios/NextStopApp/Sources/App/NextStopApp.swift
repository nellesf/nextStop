import SwiftData
import SwiftUI

@main
struct NextStopApp: App {
  var body: some Scene {
    WindowGroup {
      ProfileListView()
    }
    .modelContainer(for: [StoredProfile.self, StoredDestinationRecord.self])
  }
}
