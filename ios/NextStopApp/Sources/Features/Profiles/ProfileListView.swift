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

private struct ProfileCard: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let profile: UserProfile
  let onEdit: () -> Void
  let onStartRide: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 16) {
          profileSummary
          editButton
        }
      } else {
        HStack(alignment: .center, spacing: 16) {
          profileSummary
          editButton
        }
      }

      Button(action: onStartRide) {
        Label("ride.start", systemImage: "bolt.car.fill")
          .symbolRenderingMode(.monochrome)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .allowsTightening(true)
      }
      .buttonStyle(.glassProminent)
      .buttonSizing(.flexible)
      .controlSize(.large)
      .tint(.green)
    }
    .padding(20)
    .background {
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .fill(.regularMaterial)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .strokeBorder(Color(.separator).opacity(0.18), lineWidth: 0.5)
    }
    .shadow(
      color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06),
      radius: 18,
      y: 8
    )
  }

  private var profileSummary: some View {
    Button(action: onEdit) {
      VStack(alignment: .leading, spacing: 5) {
        Text(profile.name)
          .font(.title2.weight(.semibold))
          .foregroundStyle(.primary)
        Text(profile.destination.displayName)
          .font(.body)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var editButton: some View {
    Button(action: onEdit) {
      Label("action.edit", systemImage: "pencil")
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .allowsTightening(true)
    }
    .buttonStyle(.glass)
    .controlSize(.large)
    .fixedSize(horizontal: true, vertical: false)
  }
}

private struct ProfilesBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      Color(.systemGroupedBackground)
      LinearGradient(
        colors: [
          Color.green.opacity(colorScheme == .dark ? 0.12 : 0.09),
          Color.clear,
        ],
        startPoint: .topTrailing,
        endPoint: .center
      )
    }
    .ignoresSafeArea()
  }
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
      ZStack {
        ProfilesBackground()

        if profiles.isEmpty {
          ContentUnavailableView(
            "profiles.empty.title",
            systemImage: "bolt.car",
            description: Text("profiles.empty.description")
          )
        } else {
          List {
            ForEach(profiles) { profile in
              HStack {
                Spacer(minLength: 0)
                ProfileCard(
                  profile: profile,
                  onEdit: {
                    editorSelection = ProfileEditorSelection(profile: profile)
                  },
                  onStartRide: {
                    startRide(profile)
                  }
                )
                .frame(maxWidth: 720)
                Spacer(minLength: 0)
              }
              .listRowInsets(
                EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
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
          .background(Color.clear)
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
