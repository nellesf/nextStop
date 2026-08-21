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
  @State private var showsDataSources = false
  @State private var showsError = false
  private let directionsRequestGate: DirectionsRequestGate
  private let candidatePageSearcher: any CandidatePageSearching

  init(
    rideIntentRouter: RideIntentRouter,
    directionsRequestGate: DirectionsRequestGate,
    candidatePageSearcher: any CandidatePageSearching
  ) {
    self.rideIntentRouter = rideIntentRouter
    self.directionsRequestGate = directionsRequestGate
    self.candidatePageSearcher = candidatePageSearcher
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        fixedHeader

        List {
          screenTitle
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 10, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

          if profiles.isEmpty {
            emptyState
              .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)

            emptyProfileButton
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 24, trailing: 16))
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
          } else {
            ForEach(profiles) { profile in
              profileCard(profile)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions {
                  Button("action.delete", role: .destructive) {
                    delete(profile)
                  }
                }
            }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
      .background(Color(.systemGroupedBackground).ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .fullScreenCover(item: $editorSelection) { selection in
        ProfileEditorView(profile: selection.profile) { profile in
          try repository.save(profile)
          try reload()
        }
      }
      .sheet(isPresented: $showsDataSources) {
        NavigationStack {
          DataSourcesView()
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("action.done") {
                  showsDataSources = false
                }
              }
            }
        }
      }
      .navigationDestination(item: $rideSelection) { selection in
        switch selection.source {
        case .profile(let profile):
          RidePreparationView(
            profile: profile,
            directionsRequestGate: directionsRequestGate,
            candidatePageSearcher: candidatePageSearcher
          )
          .toolbar(.visible, for: .navigationBar)
        case .destination(let destination):
          RidePreparationView(
            destination: destination,
            directionsRequestGate: directionsRequestGate,
            candidatePageSearcher: candidatePageSearcher
          )
          .toolbar(.visible, for: .navigationBar)
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

  private var fixedHeader: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(verbatim: "nextStop")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.primary)

      Spacer(minLength: 12)

      headerButton(
        systemImage: "info",
        foregroundStyle: .primary,
        backgroundStyle: Color(.secondarySystemGroupedBackground),
        accessibilityLabel: "licenses.title"
      ) {
        showsDataSources = true
      }

      headerButton(
        systemImage: "plus",
        foregroundStyle: Color.black.opacity(0.84),
        backgroundStyle: Color.nextStopHighlight,
        accessibilityLabel: "profile.new.title"
      ) {
        editorSelection = ProfileEditorSelection()
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .background(Color(.systemGroupedBackground))
    .accessibilityElement(children: .contain)
  }

  private var screenTitle: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("profiles.title")
        .font(.largeTitle.weight(.bold))
        .foregroundStyle(.primary)

      Text("profiles.subtitle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
  }

  private func headerButton(
    systemImage: String,
    foregroundStyle: Color,
    backgroundStyle: Color,
    accessibilityLabel: LocalizedStringKey,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .bold))
        .frame(width: 44, height: 44)
        .foregroundStyle(foregroundStyle)
        .background(backgroundStyle, in: Circle())
        .overlay {
          Circle()
            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(accessibilityLabel))
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "profiles.empty.title",
      systemImage: "bolt.car",
      description: Text("profiles.empty.description")
    )
  }

  private func profileCard(_ profile: UserProfile) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        editorSelection = ProfileEditorSelection(profile: profile)
      } label: {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .center, spacing: 12) {
            Text(profile.name)
              .font(.title3.weight(.bold))
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.tertiary)
              .frame(width: 28, height: 28)
              .accessibilityHidden(true)
          }

          profileDestination(profile.destination)

          VStack(alignment: .leading, spacing: 0) {
            profileCriterion("profile.distance_to_stop", systemImage: "road.lanes") {
              Text(
                LocalizedStringKey(profile.criteria.distanceRange.localizationKey)
              )
            }
            criterionDivider

            profileCriterion("profile.minimum_power", systemImage: "bolt.fill") {
              Text(
                verbatim: LocalizedFormat.minimumKilowatts(
                  profile.criteria.minimumPower.rawValue
                )
              )
            }
            criterionDivider

            profileCriterion("profile.charging_points", systemImage: "ev.charger") {
              Text(
                verbatim: LocalizedFormat.minimumCount(
                  profile.criteria.minimumChargingPoints.rawValue
                )
              )
            }
            criterionDivider

            profileCriterion("profile.restaurant.title", systemImage: "fork.knife") {
              if let foodChain = profile.criteria.foodChain {
                VStack(alignment: .trailing, spacing: 1) {
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
                Text("profile.restaurant.not_required")
              }
            }
          }
          .symbolRenderingMode(.hierarchical)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("profiles.edit.accessibility_hint")
      .accessibilityAction(named: Text("action.delete")) {
        delete(profile)
      }

      Button {
        startRide(profile)
      } label: {
        HStack(spacing: 10) {
          Text("profile.search.start")
            .font(.headline.weight(.semibold))
          Spacer()
          Image(systemName: "arrow.right")
            .font(.headline)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .foregroundStyle(Color.black.opacity(0.84))
        .background(Color.nextStopHighlight, in: Capsule())
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .padding(.top, 12)
    }
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
  }

  private func profileDestination(_ destination: SavedDestination) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "mappin.and.ellipse")
        .foregroundStyle(.primary)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(destination.displayName)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)

        if let address = destination.displayAddress {
          Text(address)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.bottom, 3)
    .accessibilityElement(children: .combine)
  }

  private func profileCriterion<Value: View>(
    _ title: LocalizedStringKey,
    systemImage: String,
    @ViewBuilder value: () -> Value
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.primary)
          .frame(width: 20)
          .accessibilityHidden(true)

        Text(title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 8)

        value()
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: true, vertical: false)
      }

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.primary)
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
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }

  private var criterionDivider: some View {
    Divider()
      .padding(.leading, 30)
  }

  private var emptyProfileButton: some View {
    Button {
      editorSelection = ProfileEditorSelection()
    } label: {
      HStack(spacing: 10) {
        Text("profiles.empty.create")
          .font(.headline.weight(.semibold))
        Spacer()
        Image(systemName: "plus")
          .font(.headline.weight(.semibold))
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 18)
      .padding(.vertical, 15)
      .foregroundStyle(Color(.systemBackground))
      .background(
        Color(.label),
        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
    .buttonStyle(.plain)
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
