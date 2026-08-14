import MapKit
import NextStopCore
import SwiftUI
import UIKit

struct RidePreparationView: View {
  @Environment(\.openURL) private var openURL
  @StateObject private var viewModel: RidePreparationViewModel
  private let navigationLauncher: any NavigationLaunching

  @MainActor
  init(profile: UserProfile) {
    let draft = RideSearchDraft(profile: profile)
    let candidateSearcher = RideCandidateSearchCoordinator(
      pageSearcher: HTTPCandidateSearchService(),
      enricher: MapKitCandidateEnricher()
    )
    _viewModel = StateObject(
      wrappedValue: RidePreparationViewModel(
        draft: draft,
        locationProvider: CoreLocationProvider(),
        routePlanner: MapKitRoutePlanner(),
        candidateSearcher: candidateSearcher
      )
    )
    navigationLauncher = AppleMapsNavigationLauncher()
  }

  @MainActor
  init(viewModel: RidePreparationViewModel) {
    self.init(
      viewModel: viewModel,
      navigationLauncher: AppleMapsNavigationLauncher()
    )
  }

  @MainActor
  init(viewModel: RidePreparationViewModel, navigationLauncher: any NavigationLaunching) {
    _viewModel = StateObject(wrappedValue: viewModel)
    self.navigationLauncher = navigationLauncher
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        destinationCard
        criteriaCard
        preparationContent
      }
      .padding()
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("ride.title")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await viewModel.prepareRoute()
    }
  }

  private var destinationCard: some View {
    Card {
      Label("ride.destination", systemImage: "mappin.and.ellipse")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Text(viewModel.draft.destination.displayName)
        .font(.title2.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)

      if let address = viewModel.draft.destination.displayAddress {
        Text(address)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var criteriaCard: some View {
    Card {
      Label("ride.criteria", systemImage: "slider.horizontal.3")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      LabeledContent("profile.distance_range") {
        Text(LocalizedStringKey(viewModel.draft.criteria.distanceRange.localizationKey))
      }
      LabeledContent("profile.minimum_charging_points") {
        Text(LocalizedFormat.minimumCount(viewModel.draft.criteria.minimumChargingPoints.rawValue))
      }
      LabeledContent("profile.minimum_available") {
        minimumAvailabilityText
      }
      LabeledContent("profile.minimum_power") {
        Text(LocalizedFormat.kilowatts(viewModel.draft.criteria.minimumPower.rawValue))
      }
      LabeledContent("profile.fast_food") {
        foodChainText
      }
    }
  }

  @ViewBuilder
  private var minimumAvailabilityText: some View {
    if let minimum = viewModel.draft.criteria.minimumAvailablePoints {
      Text(LocalizedFormat.minimumCount(minimum.rawValue))
    } else {
      Text("availability.any")
    }
  }

  @ViewBuilder
  private var foodChainText: some View {
    if let foodChain = viewModel.draft.criteria.foodChain {
      Text(LocalizedStringKey(foodChain.localizationKey))
    } else {
      Text("food.any")
    }
  }

  @ViewBuilder
  private var preparationContent: some View {
    switch viewModel.state {
    case .idle, .requestingLocation:
      progressCard(title: "ride.progress.location")
    case .calculatingRoute:
      progressCard(title: "ride.progress.route")
    case .ready(let preparedSearch):
      readyContent(preparedSearch)
    case .failed(let failure):
      failureCard(failure)
    }
  }

  private func progressCard(title: LocalizedStringKey) -> some View {
    Card {
      ProgressView()
        .controlSize(.large)
        .frame(maxWidth: .infinity)
      Text(title)
        .font(.headline)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
      Text("ride.progress.description")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
  }

  private func readyContent(_ preparedSearch: PreparedRideSearch) -> some View {
    VStack(spacing: 20) {
      routeMap(preparedSearch)

      Card {
        Label("ride.ready.title", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(.green)

        LabeledContent("ride.route.distance") {
          Text(LocalizedFormat.kilometers(preparedSearch.route.actualDrivingDistance.value))
        }
        LabeledContent("ride.route.duration") {
          Text(LocalizedFormat.duration(preparedSearch.route.expectedTravelTimeSeconds))
        }

        Divider()

        Text("ride.ready.description")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)

        Label("ride.privacy", systemImage: "lock.shield")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      candidateSearchContent
    }
  }

  @ViewBuilder
  private var candidateSearchContent: some View {
    switch viewModel.candidateSearchState {
    case .idle:
      searchButton
    case .searching:
      Card {
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity)
        Text("ride.search.progress.title")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)
        Text("ride.search.progress.description")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)
      }
    case .results(let results):
      resultsContent(results)
    case .noResults:
      Card {
        Label("ride.search.empty.title", systemImage: "bolt.slash")
          .font(.headline)
        Text("ride.search.empty.description")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        searchButton
      }
    case .failed(let failure):
      Card {
        Label("ride.search.error.title", systemImage: "exclamationmark.triangle.fill")
          .font(.headline)
          .foregroundStyle(.orange)
        Text(LocalizedStringKey(failure.localizationKey))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        searchButton
      }
    }
  }

  private var searchButton: some View {
    Button {
      Task {
        await viewModel.searchCandidates()
      }
    } label: {
      Label("ride.search.action", systemImage: "bolt.car.fill")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
  }

  private func resultsContent(_ results: [RouteSearchResult]) -> some View {
    VStack(spacing: 12) {
      HStack {
        Label("ride.results.title", systemImage: "bolt.car.fill")
          .font(.title3.weight(.semibold))
        Spacer()
        Text("\(results.count)")
          .font(.headline.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      ForEach(results) { result in
        resultCard(result)
      }

      Text("ride.results.attribution")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func resultCard(_ result: RouteSearchResult) -> some View {
    let candidate = result.candidate
    let park = candidate.park
    return Card {
      HStack(alignment: .firstTextBaseline) {
        Text(park.name)
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(LocalizedFormat.kilometers(candidate.actualDrivingDistance.value))
          .font(.title3.weight(.bold).monospacedDigit())
          .foregroundStyle(.tint)
      }

      HStack(spacing: 14) {
        Label("\(park.chargingPointCount)", systemImage: "ev.charger")
        Label(LocalizedFormat.kilowatts(park.maximumPower.value), systemImage: "bolt.fill")
      }
      .font(.subheadline)

      Text(verbatim: availabilityText(park.availability))
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if let foodPOI = result.matchingFoodPOI {
        Label(foodPOI.name, systemImage: "fork.knife")
          .font(.subheadline)
      }

      Button {
        navigationLauncher.startNavigation(to: park)
      } label: {
        Label("ride.result.navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private func availabilityText(_ availability: ParkAvailability) -> String {
    if availability.unknownCount == availability.totalCount {
      return NSLocalizedString(
        "ride.result.availability.unknown",
        comment: "No live availability is known"
      )
    }
    if availability.isComplete {
      return String.localizedStringWithFormat(
        NSLocalizedString(
          "ride.result.availability.complete.format",
          comment: "Known available charging points"
        ),
        Int64(availability.knownAvailableCount)
      )
    }
    return String.localizedStringWithFormat(
      NSLocalizedString(
        "ride.result.availability.partial.format",
        comment: "Known available and unknown charging points"
      ),
      Int64(availability.knownAvailableCount),
      Int64(availability.unknownCount)
    )
  }

  private func routeMap(_ preparedSearch: PreparedRideSearch) -> some View {
    let routeCoordinates = preparedSearch.route.polyline.coordinates.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    let origin = CLLocationCoordinate2D(
      latitude: preparedSearch.origin.latitude,
      longitude: preparedSearch.origin.longitude
    )
    let destination = CLLocationCoordinate2D(
      latitude: viewModel.draft.destination.coordinate.latitude,
      longitude: viewModel.draft.destination.coordinate.longitude
    )

    return Map {
      MapPolyline(coordinates: routeCoordinates)
        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
      Marker("ride.map.origin", systemImage: "location.fill", coordinate: origin)
      Marker(
        viewModel.draft.destination.displayName,
        systemImage: "flag.checkered",
        coordinate: destination
      )
    }
    .mapStyle(.standard(elevation: .flat))
    .frame(height: 260)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityLabel("ride.map.accessibility")
  }

  private func failureCard(_ failure: RidePreparationFailure) -> some View {
    Card {
      Label("ride.error.title", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundStyle(.orange)

      Text(LocalizedStringKey(failure.localizationKey))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      if failure.canOpenSettings,
        let settingsURL = URL(string: UIApplication.openSettingsURLString)
      {
        Button("action.open_settings") {
          openURL(settingsURL)
        }
        .buttonStyle(.bordered)
      }

      Button("action.retry") {
        Task {
          await viewModel.prepareRoute()
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

private struct Card<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
