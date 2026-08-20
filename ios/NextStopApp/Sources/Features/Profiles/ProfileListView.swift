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
          emptyState
        } else {
          List {
            Text("profiles.subtitle")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)

            ForEach(profiles) { profile in
              profileCard(profile)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions {
                  Button("action.delete", role: .destructive) {
                    delete(profile)
                  }
                }
            }

            Button {
              editorSelection = ProfileEditorSelection()
            } label: {
              Label("profile.new.title", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(.label))
            .foregroundStyle(Color(.systemBackground))
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
        }
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("profiles.title")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink {
            DestinationLibraryView(directionsRequestGate: directionsRequestGate)
          } label: {
            Label("destinations.title", systemImage: "star")
          }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          NavigationLink {
            DataSourcesView()
          } label: {
            Label("licenses.title", systemImage: "info.circle")
          }
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

  private var emptyState: some View {
    VStack(spacing: 24) {
      ContentUnavailableView(
        "profiles.empty.title",
        systemImage: "bolt.car",
        description: Text("profiles.empty.description")
      )

      Button {
        editorSelection = ProfileEditorSelection()
      } label: {
        Label("profile.new.title", systemImage: "plus")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(.label))
      .foregroundStyle(Color(.systemBackground))
      .padding(.horizontal)
    }
  }

  private func profileCard(_ profile: UserProfile) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        editorSelection = ProfileEditorSelection(profile: profile)
      } label: {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(profile.name)
              .font(.title3.weight(.bold))
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }

          profileDestination(profile.destination)

          Divider()

          VStack(alignment: .leading, spacing: 11) {
            profileCriterion("profile.distance_to_stop", systemImage: "road.lanes") {
              Text(
                LocalizedStringKey(profile.criteria.distanceRange.localizationKey)
              )
            }

            profileCriterion("profile.minimum_power", systemImage: "bolt.fill") {
              Text(
                verbatim: LocalizedFormat.minimumKilowatts(
                  profile.criteria.minimumPower.rawValue
                )
              )
            }

            profileCriterion("profile.charging_points", systemImage: "ev.charger") {
              Text(
                verbatim: LocalizedFormat.minimumCount(
                  profile.criteria.minimumChargingPoints.rawValue
                )
              )
            }

            profileCriterion("profile.preferred_food_chain", systemImage: "fork.knife") {
              if let foodChain = profile.criteria.foodChain {
                VStack(alignment: .leading, spacing: 2) {
                  Text(LocalizedStringKey(foodChain.localizationKey))
                  Text(
                    verbatim: LocalizedFormat.maximumFoodDistance(
                      SearchConfiguration.maximumFoodDistance.value
                    )
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
              } else {
                Text("food.any")
              }
            }
          }
          .symbolRenderingMode(.hierarchical)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("profiles.edit.accessibility_hint")

      Button {
        startRide(profile)
      } label: {
        HStack(spacing: 12) {
          Text("profile.search.start")
            .font(.headline)
          Spacer()
          Image(systemName: "arrow.right")
            .font(.headline)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .foregroundStyle(.black)
      .padding(.top, 16)
    }
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
  }

  private func profileDestination(_ destination: SavedDestination) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "mappin.and.ellipse")
        .foregroundStyle(.tint)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(destination.displayName)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)

        if let address = destination.displayAddress {
          Text(address)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func profileCriterion<Value: View>(
    _ title: LocalizedStringKey,
    systemImage: String,
    @ViewBuilder value: () -> Value
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)

        value()
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
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
