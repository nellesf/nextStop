import MapKit
import NextStopCore
import SwiftUI
import UIKit

struct RidePreparationView: View {
  @Environment(\.openURL) private var openURL
  @StateObject private var viewModel: RidePreparationViewModel
  private let navigationLauncher: any AppleMapsLaunching
  private let placeResolver: any ApplePlaceResolving

  @MainActor
  init(profile: UserProfile, directionsRequestGate: DirectionsRequestGate) {
    self.init(
      draft: RideSearchDraft(profile: profile),
      directionsRequestGate: directionsRequestGate
    )
  }

  @MainActor
  init(destination: SavedDestination, directionsRequestGate: DirectionsRequestGate) {
    self.init(
      draft: RideSearchDraft(destination: destination),
      directionsRequestGate: directionsRequestGate
    )
  }

  @MainActor
  private init(
    draft: RideSearchDraft,
    directionsRequestGate: DirectionsRequestGate
  ) {
    let routePlanner = RetryingRoutePlanner(
      base: RateLimitedRoutePlanner(
        base: MapKitRoutePlanner(),
        gate: directionsRequestGate
      )
    )
    let candidateSearcher = RideCandidateSearchCoordinator(
      pageSearcher: HTTPCandidateSearchService(),
      enricher: MapKitCandidateEnricher(routePlanner: routePlanner)
    )
    _viewModel = StateObject(
      wrappedValue: RidePreparationViewModel(
        draft: draft,
        locationProvider: CoreLocationProvider(),
        routePlanner: routePlanner,
        candidateSearcher: candidateSearcher
      )
    )
    navigationLauncher = AppleMapsLauncher()
    placeResolver = MapKitApplePlaceResolver()
  }

  @MainActor
  init(viewModel: RidePreparationViewModel) {
    self.init(
      viewModel: viewModel,
      navigationLauncher: AppleMapsLauncher(),
      placeResolver: MapKitApplePlaceResolver()
    )
  }

  @MainActor
  init(
    viewModel: RidePreparationViewModel,
    navigationLauncher: any AppleMapsLaunching,
    placeResolver: any ApplePlaceResolving = MapKitApplePlaceResolver()
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    self.navigationLauncher = navigationLauncher
    self.placeResolver = placeResolver
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
      await viewModel.prepareRouteAndSearch()
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
      LabeledContent("profile.minimum_power") {
        Text(LocalizedFormat.kilowatts(viewModel.draft.criteria.minimumPower.rawValue))
      }
      LabeledContent("profile.fast_food") {
        foodChainText
      }
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
    case .idle, .requestingLocation, .calculatingRoute:
      searchProgress
    case .ready:
      candidateSearchContent
    case .failed(let failure):
      failureCard(failure)
    }
  }

  private var searchProgress: some View {
    HStack(spacing: 12) {
      ProgressView()
      Text("ride.search.progress.combined")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var candidateSearchContent: some View {
    switch viewModel.candidateSearchState {
    case .idle, .searching:
      searchProgress
    case .results(let outcome):
      resultsContent(outcome)
    case .noResults(let outcome):
      VStack(spacing: 12) {
        coverageNotice(outcome.coverage)
        Card {
          Label("ride.search.empty.title", systemImage: "bolt.slash")
            .font(.headline)
          Text("ride.search.empty.description")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          searchButton
        }
        attributionContent(outcome.attributions)
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

  private func resultsContent(_ outcome: RideCandidateSearchOutcome) -> some View {
    let results = outcome.results
    let allCandidateLocations = results.flatMap(\.locationLookups)
    return VStack(spacing: 12) {
      coverageNotice(outcome.coverage)

      HStack {
        Label("ride.results.title", systemImage: "bolt.car.fill")
          .font(.title3.weight(.semibold))
        Spacer()
        Text("\(results.count)")
          .font(.headline.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      ForEach(results) { result in
        resultCard(
          result,
          lookupLocations: result.matchingFoodPOI == nil
            ? allCandidateLocations : result.locationLookups
        )
      }

      attributionContent(outcome.attributions)

      Button {
        Task {
          await viewModel.searchCandidates()
        }
      } label: {
        Label("ride.search.refresh", systemImage: "arrow.clockwise")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
    }
  }

  @ViewBuilder
  private func attributionContent(_ attributions: [DataAttribution]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("ride.results.attribution")
      ForEach(attributions) { attribution in
        Link(attribution.notice, destination: attribution.licenseURL)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func coverageNotice(_ coverage: CandidateSearchCoverage) -> some View {
    switch coverage.status {
    case .complete:
      EmptyView()
    case .degraded:
      Card {
        Label("ride.coverage.degraded.title", systemImage: "exclamationmark.circle")
          .font(.headline)
          .foregroundStyle(.orange)
        Text("ride.coverage.degraded.description")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    case .stale:
      Card {
        Label("ride.coverage.stale.title", systemImage: "clock.badge.exclamationmark")
          .font(.headline)
          .foregroundStyle(.orange)
        Text("ride.coverage.stale.description")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func resultCard(
    _ result: RouteSearchResult,
    lookupLocations: [ChargingLocationLookup]
  ) -> some View {
    let candidate = result.candidate
    let foodPOI = result.matchingFoodPOI
    return Card {
      HStack(alignment: .firstTextBaseline) {
        Text("ride.result.operators")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(LocalizedFormat.kilometers(candidate.actualDrivingDistance.value))
          .font(.title3.weight(.bold).monospacedDigit())
          .foregroundStyle(.tint)
      }

      ForEach(result.operatorChargingPoints) { chargingOperator in
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(chargingOperator.name)
              .font(.headline)

            if let foodPOI,
              let distance = ChargingOperatorFoodDistance.nearestMeters(
                operatorName: chargingOperator.name,
                locations: result.locationLookups,
                foodCoordinate: foodPOI.coordinate
              )
            {
              Text(
                verbatim: LocalizedFormat.metersToPlace(
                  distance,
                  placeName: foodPOI.name
                )
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
          Label {
            Text(verbatim: "\(chargingOperator.chargingPointCount)")
          } icon: {
            Image(systemName: "ev.charger")
          }
          .font(.subheadline.monospacedDigit())
          .fixedSize(horizontal: true, vertical: false)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(
            Text(
              verbatim: LocalizedFormat.chargingPoints(
                chargingOperator.chargingPointCount
              ))
          )

          if let representativePark = result.representativePark(
            for: chargingOperator.name
          ) {
            ApplePlaceButton(
              target: .charging(
                park: representativePark,
                operatorName: chargingOperator.name,
                relatedLocations: AppleChargingPlaceLookupScope.relatedLocations(
                  primaryLocations: representativePark.locationLookups,
                  candidateLocations: lookupLocations,
                  operatorName: chargingOperator.name
                )
              ),
              resolver: placeResolver,
              launcher: navigationLauncher
            )
          }
        }
      }

      if let availability = availabilityText(result.availability) {
        Text(verbatim: availability)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if let foodPOI {
        HStack(alignment: .center, spacing: 10) {
          Label(foodPOI.name, systemImage: "fork.knife")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)

          ApplePlaceButton(
            target: .restaurant(foodPOI),
            resolver: placeResolver,
            launcher: navigationLauncher
          )
        }
      }
    }
  }

  private func availabilityText(_ availability: ParkAvailability) -> String? {
    if availability.unknownCount == availability.totalCount {
      return nil
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
          await viewModel.prepareRouteAndSearch()
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

enum ChargingOperatorFoodDistance {
  static func nearestMeters(
    operatorName: String,
    locations: [ChargingLocationLookup],
    foodCoordinate: Coordinate
  ) -> Int? {
    let foodLocation = CLLocation(
      latitude: foodCoordinate.latitude,
      longitude: foodCoordinate.longitude
    )
    return locations
      .lazy
      .filter { $0.operatorName == operatorName }
      .map {
        foodLocation.distance(
          from: CLLocation(
            latitude: $0.coordinate.latitude,
            longitude: $0.coordinate.longitude
          ))
      }
      .min()
      .map { Int($0.rounded()) }
  }
}

@MainActor
private struct ApplePlaceButton: View {
  private enum Failure: Identifiable {
    case noMatch
    case launchFailed

    var id: Int {
      switch self {
      case .noMatch: 0
      case .launchFailed: 1
      }
    }
  }

  let target: ApplePlaceTarget
  let resolver: any ApplePlaceResolving
  let launcher: any AppleMapsLaunching

  @State private var cachedMapItem: MKMapItem?
  @State private var isLoading = false
  @State private var failure: Failure?

  var body: some View {
    Button {
      Task {
        await openApplePlace()
      }
    } label: {
      Group {
        if isLoading {
          ProgressView()
        } else {
          Image(systemName: "map.fill")
            .font(.body.weight(.semibold))
        }
      }
      .frame(width: 48, height: 48)
      .background(Color.accentColor.opacity(0.12), in: Circle())
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isLoading)
    .accessibilityLabel(
      Text(
        String.localizedStringWithFormat(
          NSLocalizedString(
            "ride.result.apple_place.accessibility_label.format",
            comment: "Open one result place in Apple Maps"
          ),
          target.displayName
        )
      )
    )
    .accessibilityHint("ride.result.apple_place.accessibility_hint")
    .alert(item: $failure) { failure in
      switch failure {
      case .noMatch:
        Alert(
          title: Text("ride.result.apple_place.no_match.title"),
          message: Text(
            String.localizedStringWithFormat(
              NSLocalizedString(
                "ride.result.apple_place.no_match.format",
                comment: "No unambiguous Apple place for a result"
              ),
              target.displayName
            )
          ),
          dismissButton: .cancel(Text("action.done"))
        )
      case .launchFailed:
        Alert(
          title: Text("ride.apple_maps.error.title"),
          message: Text("ride.apple_maps.error.description"),
          dismissButton: .cancel(Text("action.done"))
        )
      }
    }
  }

  private func openApplePlace() async {
    if let cachedMapItem {
      failure = launcher.openPlace(cachedMapItem) ? nil : .launchFailed
      return
    }

    isLoading = true
    let mapItem = await target.resolve(using: resolver)
    isLoading = false

    guard let mapItem else {
      failure = .noMatch
      return
    }
    cachedMapItem = mapItem
    failure = launcher.openPlace(mapItem) ? nil : .launchFailed
  }
}

private enum ApplePlaceTarget {
  case charging(
    park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup]
  )
  case restaurant(FoodPOI)

  var displayName: String {
    switch self {
    case .charging(_, let operatorName, _):
      return operatorName
    case .restaurant(let foodPOI):
      return foodPOI.name
    }
  }

  @MainActor
  func resolve(using resolver: any ApplePlaceResolving) async -> MKMapItem? {
    switch self {
    case .charging(let park, let operatorName, let relatedLocations):
      return await resolver.resolveChargingPlace(
        park: park,
        operatorName: operatorName,
        relatedLocations: relatedLocations
      )
    case .restaurant(let foodPOI):
      return await resolver.resolveRestaurantPlace(foodPOI)
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
