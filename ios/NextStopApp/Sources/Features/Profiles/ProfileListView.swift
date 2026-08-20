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
  private let directionsRequestGate: DirectionsRequestGate

  init(
    rideIntentRouter: RideIntentRouter,
    directionsRequestGate: DirectionsRequestGate
  ) {
    self.rideIntentRouter = rideIntentRouter
    self.directionsRequestGate = directionsRequestGate
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
              VStack(alignment: .leading, spacing: 16) {
                Button {
                  editorSelection = ProfileEditorSelection(profile: profile)
                } label: {
                  HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(profile.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                      Text(profile.destination.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("action.edit")
                      .font(.callout.weight(.semibold))
                      .foregroundStyle(.primary)
                      .padding(.horizontal, 16)
                      .frame(minHeight: 44)
                      .profileEditControlStyle()
                  }
                  .frame(minHeight: 64)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                  startRide(profile)
                } label: {
                  Label("ride.start", systemImage: "bolt.car.fill")
                    .symbolRenderingMode(.monochrome)
                    .frame(maxWidth: .infinity)
                }
                .profilePrimaryActionStyle()
                .controlSize(.large)
                .tint(.green)
              }
              .padding(16)
              .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
              )
              .listRowInsets(
                EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
              )
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
              .swipeActions {
                Button("action.delete", role: .destructive) {
                  delete(profile)
                }
              }
            }
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .background(Color(.systemGroupedBackground))
        }
      }
      .navigationTitle("profiles.title")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink {
            DataSourcesView()
          } label: {
            Label("licenses.title", systemImage: "info.circle")
          }
          .profileToolbarActionStyle()
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            editorSelection = ProfileEditorSelection()
          } label: {
            Label("action.add", systemImage: "plus")
          }
          .profileToolbarActionStyle()
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
          RidePreparationView(
            profile: profile,
            directionsRequestGate: directionsRequestGate
          )
        case .destination(let destination):
          RidePreparationView(
            destination: destination,
            directionsRequestGate: directionsRequestGate
          )
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

extension View {
  @ViewBuilder
  fileprivate func profileEditControlStyle() -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.clear.interactive(), in: Capsule())
    } else {
      background(Color(.tertiarySystemFill), in: Capsule())
    }
  }

  @ViewBuilder
  fileprivate func profilePrimaryActionStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass(.clear.tint(.green)))
    } else {
      buttonStyle(.borderedProminent)
    }
  }

  @ViewBuilder
  fileprivate func profileToolbarActionStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
    } else {
      self
    }
  }
}
