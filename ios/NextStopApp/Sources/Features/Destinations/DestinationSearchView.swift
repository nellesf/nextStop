import SwiftUI

struct DestinationSearchView: View {
  let onSelect: (DestinationSearchResult) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var results: [DestinationSearchResult] = []
  @State private var isSearching = false
  @State private var showsEmptyResult = false
  @State private var showsError = false

  private let searchService: any DestinationSearching

  init(
    searchService: any DestinationSearching = MapKitDestinationSearchService(),
    onSelect: @escaping (DestinationSearchResult) -> Void
  ) {
    self.searchService = searchService
    self.onSelect = onSelect
  }

  var body: some View {
    NavigationStack {
      Group {
        if isSearching {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showsEmptyResult {
          ContentUnavailableView.search(text: query)
        } else {
          List(results) { result in
            Button {
              onSelect(result)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(result.destination.displayName)
                  .foregroundStyle(.primary)
                if let subtitle = result.subtitle {
                  Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("destination.search.title")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "destination.search.placeholder")
      .onSubmit(of: .search) {
        Task { await search() }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("action.cancel") { dismiss() }
        }
      }
      .alert("destination.search.error", isPresented: $showsError) {
        Button("action.done", role: .cancel) {}
      }
    }
  }

  private func search() async {
    isSearching = true
    showsEmptyResult = false
    defer { isSearching = false }

    do {
      results = try await searchService.search(query: query)
      showsEmptyResult = results.isEmpty
    } catch {
      results = []
      showsError = true
    }
  }
}
