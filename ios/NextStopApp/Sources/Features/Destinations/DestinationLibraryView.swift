import NextStopCore
import SwiftData
import SwiftUI

private struct DestinationRideSelection: Identifiable, Hashable {
  let id: UUID
  let destination: SavedDestination
}

private enum DestinationClearSelection: Equatable {
  case favorites
  case recents
}

struct DestinationLibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var favorites: [LocalDestinationRecord] = []
  @State private var recents: [LocalDestinationRecord] = []
  @State private var rideSelection: DestinationRideSelection?
  @State private var showsSearch = false
  @State private var showsError = false
  @State private var clearSelection: DestinationClearSelection?

  var body: some View {
    Group {
      if favorites.isEmpty, recents.isEmpty {
        ContentUnavailableView(
          "destinations.empty.title",
          systemImage: "mappin.slash",
          description: Text("destinations.empty.description")
        )
      } else {
        List {
          if !favorites.isEmpty {
            Section("destinations.favorites") {
              ForEach(favorites) { record in
                destinationRow(record)
              }
            }
          }

          if !recents.isEmpty {
            Section("destinations.recents") {
              ForEach(recents) { record in
                destinationRow(record)
              }
            }
          }
        }
      }
    }
    .navigationTitle("destinations.title")
    .toolbar {
      ToolbarItem(placement: .secondaryAction) {
        Menu {
          Button("destinations.clear.recents", role: .destructive) {
            clearSelection = .recents
          }
          .disabled(recents.isEmpty)
          Button("destinations.clear.favorites", role: .destructive) {
            clearSelection = .favorites
          }
          .disabled(favorites.isEmpty)
        } label: {
          Label("destinations.manage", systemImage: "ellipsis.circle")
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          showsSearch = true
        } label: {
          Label("destination.search.title", systemImage: "magnifyingglass")
        }
      }
    }
    .sheet(isPresented: $showsSearch) {
      DestinationSearchView { result in
        startRide(to: result.destination)
      }
    }
    .navigationDestination(item: $rideSelection) { selection in
      RidePreparationView(destination: selection.destination)
    }
    .alert("error.generic", isPresented: $showsError) {
      Button("action.done", role: .cancel) {}
    }
    .confirmationDialog(
      "destinations.clear.confirm.title",
      isPresented: Binding(
        get: { clearSelection != nil },
        set: { isPresented in
          if !isPresented {
            clearSelection = nil
          }
        }
      )
    ) {
      if clearSelection == .recents {
        Button("destinations.clear.recents", role: .destructive) {
          clear(.recents)
        }
      }
      if clearSelection == .favorites {
        Button("destinations.clear.favorites", role: .destructive) {
          clear(.favorites)
        }
      }
      Button("action.cancel", role: .cancel) {
        clearSelection = nil
      }
    }
    .task {
      reloadOrShowError()
    }
  }

  private var repository: SwiftDataDestinationRepository {
    SwiftDataDestinationRepository(modelContext: modelContext)
  }

  private func destinationRow(_ record: LocalDestinationRecord) -> some View {
    Button {
      startRide(to: record.destination)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(record.destination.displayName)
            .foregroundStyle(.primary)
          if let address = record.destination.displayAddress {
            Text(address)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .swipeActions(edge: .leading) {
      Button {
        setFavorite(record, isFavorite: !record.isFavorite)
      } label: {
        Label {
          Text(
            LocalizedStringKey(
              record.isFavorite
                ? "destinations.favorite.remove"
                : "destinations.favorite.add"
            )
          )
        } icon: {
          Image(systemName: record.isFavorite ? "star.slash" : "star.fill")
        }
      }
      .tint(record.isFavorite ? .gray : .yellow)
    }
    .swipeActions(edge: .trailing) {
      if record.lastUsedAt != nil {
        Button("destinations.recent.remove", role: .destructive) {
          removeRecent(record)
        }
      }
    }
  }

  private func startRide(to destination: SavedDestination) {
    do {
      try repository.recordRecent(destination, at: Date())
      try reload()
      rideSelection = DestinationRideSelection(id: UUID(), destination: destination)
    } catch {
      showsError = true
    }
  }

  private func setFavorite(_ record: LocalDestinationRecord, isFavorite: Bool) {
    do {
      try repository.setFavorite(record.destination, isFavorite: isFavorite, at: Date())
      try reload()
    } catch {
      showsError = true
    }
  }

  private func reloadOrShowError() {
    do {
      try reload()
    } catch {
      showsError = true
    }
  }

  private func removeRecent(_ record: LocalDestinationRecord) {
    do {
      try repository.removeRecent(record.destination)
      try reload()
    } catch {
      showsError = true
    }
  }

  private func clear(_ selection: DestinationClearSelection) {
    do {
      switch selection {
      case .favorites:
        try repository.clearFavorites()
      case .recents:
        try repository.clearRecents()
      }
      clearSelection = nil
      try reload()
    } catch {
      showsError = true
    }
  }

  private func reload() throws {
    favorites = try repository.fetchFavorites()
    recents = try repository.fetchRecents()
  }
}
