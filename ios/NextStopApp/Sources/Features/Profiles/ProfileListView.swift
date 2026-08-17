import NextStopCore
import SwiftData
import SwiftUI

private struct ProfileEditorSelection: Identifiable {
  let id: UUID
  let profile: UserProfile?

  init(profile: UserProfile? = nil) {
    id = profile?.id ?? UUID()
    self.profile = profile
  }
}

private enum RideSelectionSource: Hashable {
  case profile(UserProfile)
  case destination(SavedDestination)
}

private struct RideSelection: Identifiable, Hashable {
  let id: UUID
  let source: RideSelectionSource
}

struct ProfileListView: View {
  @Environment(\.modelContext) private var modelContext
  @ObservedObject private var rideIntentRouter: RideIntentRouter
  @State private var profiles: [UserProfile] = []
  @State private var editorSelection: ProfileEditorSelection?
  @State private var rideSelection: RideSelection?
  @State private var showsError = false

  init(rideIntentRouter: RideIntentRouter) {
    self.rideIntentRouter = rideIntentRouter
  }

  var body: some View {
    NavigationStack {
      Group {
        if profiles.isEmpty {
          ContentUnavailableView(
            "profiles.empty.title",
            systemImage: "bolt.car",
            description: Text("profiles.empty.description")
          )
        } else {
          List {
            ForEach(profiles) { profile in
              VStack(alignment: .leading, spacing: 12) {
                Button {
                  editorSelection = ProfileEditorSelection(profile: profile)
                } label: {
                  HStack {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                      Text(profile.destination.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "pencil")
                      .foregroundStyle(.secondary)
                      .accessibilityHidden(true)
                  }
                  .contentShape(Rectangle())
                }

                Button {
                  startRide(profile)
                } label: {
                  Label("ride.start", systemImage: "arrow.trianglehead.turn.up.right.circle.fill")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
              }
              .swipeActions {
                Button("action.delete", role: .destructive) {
                  delete(profile)
                }
              }
            }
          }
        }
      }
      .navigationTitle("profiles.title")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink {
            DestinationLibraryView()
          } label: {
            Label("destinations.title", systemImage: "star")
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            editorSelection = ProfileEditorSelection()
          } label: {
            Label("action.add", systemImage: "plus")
          }
        }
      }
      .sheet(item: $editorSelection) { selection in
        ProfileEditorView(profile: selection.profile) { profile in
          try repository.save(profile)
          try reload()
        }
      }
      .navigationDestination(item: $rideSelection) { selection in
        switch selection.source {
        case .profile(let profile):
          RidePreparationView(profile: profile)
        case .destination(let destination):
          RidePreparationView(destination: destination)
        }
      }
      .alert("error.generic", isPresented: $showsError) {
        Button("action.done", role: .cancel) {}
      }
      .task {
        do {
          try reload()
          openPendingIntentDestination()
        } catch {
          showsError = true
        }
      }
      .onChange(of: rideIntentRouter.pendingDestination) {
        openPendingIntentDestination()
      }
    }
  }

  private var repository: SwiftDataProfileRepository {
    SwiftDataProfileRepository(modelContext: modelContext)
  }

  private var destinationRepository: SwiftDataDestinationRepository {
    SwiftDataDestinationRepository(modelContext: modelContext)
  }

  private func reload() throws {
    profiles = try repository.fetchProfiles()
  }

  private func delete(_ profile: UserProfile) {
    do {
      try repository.delete(id: profile.id)
      try reload()
    } catch {
      showsError = true
    }
  }

  private func startRide(_ profile: UserProfile) {
    do {
      try destinationRepository.recordRecent(profile.destination, at: Date())
      rideSelection = RideSelection(id: UUID(), source: .profile(profile))
    } catch {
      showsError = true
    }
  }

  private func openPendingIntentDestination() {
    guard let destination = rideIntentRouter.pendingDestination else {
      return
    }
    do {
      try destinationRepository.recordRecent(destination, at: Date())
      rideSelection = RideSelection(id: UUID(), source: .destination(destination))
      rideIntentRouter.consumePendingDestination()
    } catch {
      showsError = true
    }
  }
}
