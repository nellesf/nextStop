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
    .background(
      Color(.systemGroupedBackground)
        .overlay(Color.nextStopHighlight.opacity(0.025))
    )
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
      LabeledContent("profile.restaurant.title") {
        restaurantRequirementText
      }
    }
  }

  @ViewBuilder
  private var restaurantRequirementText: some View {
    if let foodChain = viewModel.draft.criteria.foodChain {
      Text(LocalizedStringKey(foodChain.localizationKey))
    } else {
      Text("profile.restaurant.not_required")
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
    return VStack(alignment: .leading, spacing: 12) {
      coverageNotice(outcome.coverage)

      resultsHeader(count: results.count)

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
      .tint(Color(.label))
    }
  }

  private func resultsHeader(count: Int) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("ride.results.screen.title")
          .font(.title3.weight(.bold))
          .foregroundStyle(.primary)

        Spacer(minLength: 8)

        resultCountBadge(count)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          resultDirectionMeta
          Spacer(minLength: 8)
          resultSortMeta
        }

        VStack(alignment: .leading, spacing: 4) {
          resultDirectionMeta
          resultSortMeta
        }
      }
    }
    .padding(.horizontal, 2)
  }

  private var resultDirectionMeta: some View {
    Label {
      Text(
        verbatim: LocalizedFormat.direction(
          to: viewModel.draft.destination.displayName
        )
      )
    } icon: {
      Image(systemName: "arrow.up.right")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var resultSortMeta: some View {
    Label("ride.results.sorted_by_driving_distance", systemImage: "arrow.up.arrow.down")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func resultCountBadge(_ count: Int) -> some View {
    Text(verbatim: LocalizedFormat.resultCount(count))
      .font(.caption.weight(.bold).monospacedDigit())
      .foregroundStyle(.black.opacity(0.86))
      .frame(minHeight: 28)
      .padding(.horizontal, 10)
      .background(Color.nextStopHighlight, in: Capsule())
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
    return ResultCard {
      HStack(alignment: .center, spacing: 10) {
        resultPositionBadge(position)

        Label {
          Text(foodPOI.name)
        } icon: {
          Image(systemName: "fork.knife")
        }
        .font(.headline.weight(.bold))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)

        ApplePlaceButton(
          target: .restaurant(foodPOI),
          resolver: placeResolver,
          launcher: navigationLauncher
        )
      }

      resultMetrics(result)
        .padding(.top, 4)
        .padding(.bottom, 9)

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

    return ResultCard {
      HStack(alignment: .center, spacing: 10) {
        resultPositionBadge(position)

        Label(result.candidate.park.name, systemImage: "bolt.car.fill")
          .font(.headline.weight(.bold))
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      resultMetrics(result)
        .padding(.top, 4)
        .padding(.bottom, 9)

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
      .font(.caption.weight(.bold).monospacedDigit())
      .foregroundStyle(Color.black.opacity(0.86))
      .frame(width: 26, height: 26)
      .background(Color.nextStopHighlight, in: Circle())
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .accessibilityLabel(Text(verbatim: LocalizedFormat.resultRank(position)))
  }

  private func resultMetrics(_ result: RouteSearchResult) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        drivingDistanceLabel(result.candidate.actualDrivingDistance.value)

        Divider()
          .frame(height: 14)

        chargingPointLabel(result.chargingPointCount)
      }

      VStack(alignment: .leading, spacing: 3) {
        drivingDistanceLabel(result.candidate.actualDrivingDistance.value)
        chargingPointLabel(result.chargingPointCount)
      }
    }
  }

  private func drivingDistanceLabel(_ meters: Int) -> some View {
    Label {
      Text(verbatim: LocalizedFormat.drivingDistanceToStop(meters))
        .monospacedDigit()
    } icon: {
      Image(systemName: "car.side.fill")
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.primary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: LocalizedFormat.drivingDistanceToStop(meters)))
  }

  private func chargingPointLabel(_ count: Int) -> some View {
    Label {
      Text(verbatim: LocalizedFormat.matchingChargingPoints(count))
        .monospacedDigit()
    } icon: {
      Image(systemName: "ev.charger.fill")
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: LocalizedFormat.matchingChargingPoints(count)))
  }

  private func operatorSection(
    _ chargingOperators: [RouteSearchOperatorSummary],
    result: RouteSearchResult,
    lookupLocations: [ChargingLocationLookup],
    usesRestaurantGroupLookupScope: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("ride.result.operators")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.top, 7)
        .padding(.bottom, 2)

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
            .padding(.leading, 32)
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

    return HStack(alignment: .center, spacing: 8) {
      Image(systemName: "bolt.fill")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.black.opacity(0.82))
        .frame(width: 24, height: 24)
        .background(Color.nextStopHighlight, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(chargingOperator.name)
          .font(.subheadline.weight(.semibold))

        Text(verbatim: LocalizedFormat.chargingPoints(chargingOperator.chargingPointCount))
          .font(.caption.monospacedDigit())
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
    .frame(minHeight: 48)
  }

  @ViewBuilder
  private func availabilityContent(_ availability: ParkAvailability) -> some View {
    if let availability = availabilityText(availability) {
      Divider()

      Label {
        Text(verbatim: availability)
      } icon: {
        Image(systemName: "wave.3.right.circle.fill")
          .foregroundStyle(.primary)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.vertical, 8)
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
            .controlSize(.small)
        } else {
          Image(systemName: "map.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
        }
      }
      .frame(width: 34, height: 34)
      .background(
        Color(.secondarySystemFill),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .frame(width: 48, height: 48)
      .contentShape(Rectangle())
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
    .background(Color(.systemBackground), in: shape)
    .overlay {
      shape.stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.04), radius: 12, y: 4)
  }
}

private struct ResultCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.systemBackground), in: shape)
    .overlay {
      shape.stroke(Color.primary.opacity(0.07), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.035), radius: 8, y: 3)
  }
}
