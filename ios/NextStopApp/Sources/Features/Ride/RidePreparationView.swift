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
        if viewModel.draft.sourceProfileID == nil {
          destinationCard
          criteriaCard
        }
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
    .foregroundStyle(.black)
  }

  private func resultsContent(_ outcome: RideCandidateSearchOutcome) -> some View {
    let results = outcome.results
    let allCandidateLocations = results.flatMap(\.locationLookups)
    return VStack(alignment: .leading, spacing: 16) {
      coverageNotice(outcome.coverage)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) {
          resultsHeading
          Spacer()
          resultCountBadge(results.count)
        }

        VStack(alignment: .leading, spacing: 10) {
          resultsHeading
          resultCountBadge(results.count)
        }
      }
      .padding(.horizontal, 4)

      Label("ride.results.sorted_by_driving_distance", systemImage: "arrow.up.arrow.down")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)

      ForEach(Array(results.enumerated()), id: \.element.resultCardID) { index, result in
        resultCard(
          result,
          position: index + 1,
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

  private var resultsHeading: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("ride.results.screen.title")
        .font(.title2.weight(.bold))

      Label {
        Text(
          verbatim: LocalizedFormat.direction(
            to: viewModel.draft.destination.displayName
          )
        )
      } icon: {
        Image(systemName: "arrow.up.right")
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  private func resultCountBadge(_ count: Int) -> some View {
    Text(verbatim: LocalizedFormat.resultCount(count))
      .font(.headline.weight(.bold).monospacedDigit())
      .foregroundStyle(.primary)
      .frame(minHeight: 36)
      .padding(.horizontal, 12)
      .background(Color.accentColor.opacity(0.12), in: Capsule())
      .fixedSize(horizontal: true, vertical: false)
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

  @ViewBuilder
  private func resultCard(
    _ result: RouteSearchResult,
    position: Int,
    lookupLocations: [ChargingLocationLookup]
  ) -> some View {
    if let foodPOI = result.matchingFoodPOI {
      restaurantResultCard(
        result,
        foodPOI: foodPOI,
        position: position,
        lookupLocations: lookupLocations
      )
    } else {
      parkResultCard(
        result,
        position: position,
        lookupLocations: lookupLocations
      )
    }
  }

  private func restaurantResultCard(
    _ result: RouteSearchResult,
    foodPOI: FoodPOI,
    position: Int,
    lookupLocations: [ChargingLocationLookup]
  ) -> some View {
    return Card {
      HStack(alignment: .top, spacing: 12) {
        resultPositionBadge(position)

        VStack(alignment: .leading, spacing: 8) {
          Label(foodPOI.name, systemImage: "fork.knife")
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)

          resultMetrics(result)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        ApplePlaceButton(
          target: .restaurant(foodPOI),
          resolver: placeResolver,
          launcher: navigationLauncher
        )
      }

      Divider()

      operatorSection(
        result.operatorChargingPoints,
        result: result,
        lookupLocations: lookupLocations,
        usesRestaurantGroupLookupScope: true
      )

      availabilityContent(result.availability)
    }
  }

  private func parkResultCard(
    _ result: RouteSearchResult,
    position: Int,
    lookupLocations: [ChargingLocationLookup]
  ) -> some View {
    let chargingOperators = result.operatorChargingPoints

    return Card {
      HStack(alignment: .top, spacing: 12) {
        resultPositionBadge(position)

        VStack(alignment: .leading, spacing: 8) {
          Label(result.candidate.park.name, systemImage: "bolt.car.fill")
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)

          resultMetrics(result)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      operatorSection(
        chargingOperators,
        result: result,
        lookupLocations: lookupLocations,
        usesRestaurantGroupLookupScope: false
      )

      availabilityContent(result.availability)
    }
  }

  private func resultPositionBadge(_ position: Int) -> some View {
    Text(verbatim: "\(position)")
      .font(.subheadline.weight(.bold).monospacedDigit())
      .foregroundStyle(.black.opacity(0.82))
      .frame(width: 32, height: 32)
      .background(Color.accentColor, in: Circle())
      .accessibilityLabel(Text(verbatim: LocalizedFormat.resultRank(position)))
  }

  private func resultMetrics(_ result: RouteSearchResult) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      drivingDistanceLabel(result.candidate.actualDrivingDistance.value)
      chargingPointLabel(result.chargingPointCount)
    }
  }

  private func drivingDistanceLabel(_ meters: Int) -> some View {
    Label {
      Text(verbatim: LocalizedFormat.drivingDistanceToStop(meters))
        .font(.title3.weight(.bold).monospacedDigit())
    } icon: {
      Image(systemName: "car.side.fill")
    }
    .foregroundStyle(.primary)
  }

  private func chargingPointLabel(_ count: Int) -> some View {
    Label {
      Text(verbatim: LocalizedFormat.matchingChargingPoints(count))
        .monospacedDigit()
    } icon: {
      Image(systemName: "ev.charger.fill")
    }
    .font(.subheadline.weight(.medium))
    .foregroundStyle(.secondary)
  }

  private func operatorSection(
    _ chargingOperators: [RouteSearchOperatorSummary],
    result: RouteSearchResult,
    lookupLocations: [ChargingLocationLookup],
    usesRestaurantGroupLookupScope: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("ride.result.operators")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.bottom, 4)

      ForEach(Array(chargingOperators.enumerated()), id: \.element.id) {
        index, chargingOperator in
        chargingOperatorRow(
          chargingOperator,
          result: result,
          lookupLocations: lookupLocations,
          usesRestaurantGroupLookupScope: usesRestaurantGroupLookupScope
        )

        if index < chargingOperators.count - 1 {
          Divider()
            .padding(.leading, 42)
        }
      }
    }
  }

  private func chargingOperatorRow(
    _ chargingOperator: RouteSearchOperatorSummary,
    result: RouteSearchResult,
    lookupLocations: [ChargingLocationLookup],
    usesRestaurantGroupLookupScope: Bool
  ) -> some View {
    let relatedLocations =
      usesRestaurantGroupLookupScope
      ? AppleChargingPlaceLookupScope.restaurantGroupLocations(
        candidateLocations: lookupLocations,
        operatorName: chargingOperator.name
      )
      : AppleChargingPlaceLookupScope.relatedLocations(
        primaryLocations: result.representativePark(
          for: chargingOperator.name
        )?.locationLookups ?? [],
        candidateLocations: lookupLocations,
        operatorName: chargingOperator.name
      )

    return HStack(alignment: .center, spacing: 10) {
      Image(systemName: "bolt.fill")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .frame(width: 32, height: 32)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(chargingOperator.name)
          .font(.headline)

        Text(verbatim: LocalizedFormat.chargingPoints(chargingOperator.chargingPointCount))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)

      if let representativePark = result.representativePark(
        for: chargingOperator.name
      ) {
        ApplePlaceButton(
          target: .charging(
            park: representativePark,
            operatorName: chargingOperator.name,
            relatedLocations: relatedLocations
          ),
          resolver: placeResolver,
          launcher: navigationLauncher
        )
      }
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func availabilityContent(_ availability: ParkAvailability) -> some View {
    if let availability = availabilityText(availability) {
      Divider()

      Label {
        Text(verbatim: availability)
      } icon: {
        Image(systemName: "wave.3.right.circle.fill")
          .foregroundStyle(.tint)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
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
      .foregroundStyle(.black)
    }
  }
}

extension RouteSearchResult {
  fileprivate var resultCardID: String {
    if let matchingFoodPOI {
      return "restaurant:\(matchingFoodPOI.id)"
    }
    return "park:\(id.uuidString)"
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
            .foregroundStyle(.primary)
        }
      }
      .frame(width: 48, height: 48)
      .background(
        Color.accentColor.opacity(0.12),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isLoading)
    .onChange(of: target) {
      cachedMapItem = nil
      isLoading = false
      failure = nil
    }
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
    let requestedTarget = target
    if let cachedMapItem {
      failure = launcher.openPlace(cachedMapItem) ? nil : .launchFailed
      return
    }

    isLoading = true
    let mapItem = await requestedTarget.resolve(using: resolver)
    guard requestedTarget == target else { return }
    isLoading = false

    guard let mapItem else {
      failure = .noMatch
      return
    }
    cachedMapItem = mapItem
    failure = launcher.openPlace(mapItem) ? nil : .launchFailed
  }
}

private enum ApplePlaceTarget: Hashable {
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
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: shape)
    .overlay {
      shape.stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.04), radius: 12, y: 4)
  }
}
