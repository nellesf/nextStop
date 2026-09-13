import Foundation
import NextStopCore

@MainActor
struct CarPlayLocalizer {
  private let resolve: (String) -> String
  private let locale: Locale

  init(
    locale: Locale = .current,
    resolve: @escaping (String) -> String = {
      NSLocalizedString($0, comment: "CarPlay presentation")
    }
  ) {
    self.locale = locale
    self.resolve = resolve
  }

  func text(_ key: String) -> String {
    resolve(key)
  }

  func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: resolve(key), locale: locale, arguments: arguments)
  }
}

struct CarPlayProfilePresentation: Equatable, Sendable {
  let id: UUID
  let title: String
  let detail: String
}

enum CarPlayCriteriaField: String, CaseIterable, Hashable, Sendable {
  case distanceRange
  case minimumChargingPoints
  case minimumPower
  case foodChain
}

enum CarPlayCriteriaSelection: Hashable, Sendable {
  case distanceRange(DistanceRangeOption)
  case minimumChargingPoints(MinimumChargingPointsOption)
  case minimumPower(MinimumPowerOption)
  case foodChain(FoodChain?)
}

struct CarPlayCriterionPresentation: Equatable, Sendable {
  let field: CarPlayCriteriaField
  let title: String
  let value: String
}

struct CarPlayCriteriaOptionPresentation: Equatable, Sendable {
  let selection: CarPlayCriteriaSelection
  let title: String
  let selected: Bool
}

struct CarPlayRideSummaryPresentation: Equatable, Sendable {
  let title: String
  let destination: String
  let criteria: [CarPlayCriterionPresentation]
  let searchActionTitle: String
  let searchActionDetail: String
  let editActionTitle: String
  let editActionDetail: String
  let criteriaSummaryTitle: String
  let criteriaSummaryDetail: String
}

struct CarPlayOperatorPresentation: Equatable, Sendable {
  let name: String
  let detail: String
}

struct CarPlayResultPresentation: Equatable, Sendable {
  let id: UUID
  let coordinate: Coordinate
  let title: String
  let subtitle: String
  let summary: String?
  let detailTitle: String
  let detailSubtitle: String
  let detailSummary: String?
  let operatorsActionTitle: String
  let restaurantActionTitle: String?
}

struct CarPlayResultsPresentation: Equatable, Sendable {
  let title: String
  let points: [CarPlayResultPresentation]
  let coverageMessage: String?
  let attributionMessage: String?
}

@MainActor
struct CarPlayPresenter {
  private let localizer: CarPlayLocalizer

  init(localizer: CarPlayLocalizer = CarPlayLocalizer()) {
    self.localizer = localizer
  }

  func profiles(_ profiles: [UserProfile]) -> [CarPlayProfilePresentation] {
    profiles.map { profile in
      CarPlayProfilePresentation(
        id: profile.id,
        title: profile.name,
        detail: profile.destination.displayName
      )
    }
  }

  func rideSummary(_ draft: RideSearchDraft) -> CarPlayRideSummaryPresentation {
    CarPlayRideSummaryPresentation(
      title: localizer.text("carplay.ride.title"),
      destination: draft.destination.displayName,
      criteria: CarPlayCriteriaField.allCases.map { criterion($0, draft: draft) },
      searchActionTitle: localizer.text("carplay.search.action"),
      searchActionDetail: localizer.text("carplay.search.action.detail"),
      editActionTitle: localizer.text("carplay.filters.action"),
      editActionDetail: localizer.text("carplay.filters.action.detail"),
      criteriaSummaryTitle: localizer.format(
        "carplay.criteria.summary.title.format",
        localizer.text(draft.criteria.distanceRange.localizationKey),
        Int64(draft.criteria.minimumChargingPoints.rawValue)
      ),
      criteriaSummaryDetail: localizer.format(
        "carplay.criteria.summary.detail.format",
        Int64(draft.criteria.minimumPower.rawValue),
        draft.criteria.foodChain.map { localizer.text($0.localizationKey) }
          ?? localizer.text("carplay.criteria.no_restaurant")
      )
    )
  }

  func options(
    for field: CarPlayCriteriaField,
    draft: RideSearchDraft
  ) -> [CarPlayCriteriaOptionPresentation] {
    switch field {
    case .distanceRange:
      DistanceRangeOption.allCases.map { value in
        CarPlayCriteriaOptionPresentation(
          selection: .distanceRange(value),
          title: localizer.text(value.localizationKey),
          selected: value == draft.criteria.distanceRange
        )
      }
    case .minimumChargingPoints:
      MinimumChargingPointsOption.allCases.map { value in
        CarPlayCriteriaOptionPresentation(
          selection: .minimumChargingPoints(value),
          title: minimumCount(value.rawValue),
          selected: value == draft.criteria.minimumChargingPoints
        )
      }
    case .minimumPower:
      MinimumPowerOption.allCases.map { value in
        CarPlayCriteriaOptionPresentation(
          selection: .minimumPower(value),
          title: kilowatts(value.rawValue),
          selected: value == draft.criteria.minimumPower
        )
      }
    case .foodChain:
      [
        CarPlayCriteriaOptionPresentation(
          selection: .foodChain(nil),
          title: localizer.text("profile.restaurant.not_required"),
          selected: draft.criteria.foodChain == nil
        )
      ]
        + FoodChain.allCases.map { value in
          CarPlayCriteriaOptionPresentation(
            selection: .foodChain(value),
            title: localizer.text(value.localizationKey),
            selected: value == draft.criteria.foodChain
          )
        }
    }
  }

  func results(
    _ outcome: RideCandidateSearchOutcome,
    criteria: RideCriteria
  ) -> CarPlayResultsPresentation {
    precondition(outcome.results.count <= SearchConfiguration.maximumResultCount)
    return CarPlayResultsPresentation(
      title: localizer.text("ride.results.screen.title"),
      points: outcome.results.map { result($0, criteria: criteria) },
      coverageMessage: coverageMessage(outcome.coverage),
      attributionMessage: outcome.attributions.isEmpty
        ? nil
        : outcome.attributions.map(\.notice).joined(separator: " · ")
    )
  }

  func operators(for result: RouteSearchResult) -> [CarPlayOperatorPresentation] {
    result.operatorChargingPoints.map { chargingOperator in
      CarPlayOperatorPresentation(
        name: chargingOperator.name,
        detail: localizer.format(
          "carplay.operator.detail.format",
          chargingPoints(chargingOperator.chargingPointCount),
          localizer.text("ride.result.navigate")
        )
      )
    }
  }

  private func criterion(
    _ field: CarPlayCriteriaField,
    draft: RideSearchDraft
  ) -> CarPlayCriterionPresentation {
    let criteria = draft.criteria
    switch field {
    case .distanceRange:
      return CarPlayCriterionPresentation(
        field: field,
        title: localizer.text("profile.distance_range"),
        value: localizer.text(criteria.distanceRange.localizationKey)
      )
    case .minimumChargingPoints:
      return CarPlayCriterionPresentation(
        field: field,
        title: localizer.text("profile.minimum_charging_points"),
        value: minimumCount(criteria.minimumChargingPoints.rawValue)
      )
    case .minimumPower:
      return CarPlayCriterionPresentation(
        field: field,
        title: localizer.text("profile.minimum_power"),
        value: kilowatts(criteria.minimumPower.rawValue)
      )
    case .foodChain:
      return CarPlayCriterionPresentation(
        field: field,
        title: localizer.text("profile.restaurant.title"),
        value: criteria.foodChain.map { localizer.text($0.localizationKey) }
          ?? localizer.text("profile.restaurant.not_required")
      )
    }
  }

  private func result(
    _ routeResult: RouteSearchResult,
    criteria: RideCriteria
  ) -> CarPlayResultPresentation {
    let candidate = routeResult.candidate
    let park = candidate.park
    let foodPOI = routeResult.matchingFoodPOI
    let drivingDistance = localizer.format(
      "carplay.result.driving_distance.format",
      Int64(roundedKilometers(candidate.actualDrivingDistance.value))
    )
    let availability = availabilityText(routeResult.availability)
    let matchingChargingPoints = localizer.format(
      "ride.result.matching_charging_points.format",
      Int64(routeResult.chargingPointCount)
    )
    let chargingOperators = routeResult.operatorChargingPoints
    let operatorSummary = chargingOperators.map { chargingOperator in
      localizer.format(
        "carplay.result.operator.format",
        chargingOperator.name,
        chargingPoints(chargingOperator.chargingPointCount)
      )
    }
    .joined(separator: "\n")
    let detailSummary = [
      drivingDistance,
      matchingChargingPoints,
      operatorSummary.isEmpty ? nil : operatorSummary,
      minimumKilowatts(criteria.minimumPower.rawValue),
      availability,
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
    let title = foodPOI?.name ?? park.name
    let coordinate = foodPOI?.coordinate ?? park.navigationCoordinate
    return CarPlayResultPresentation(
      id: routeResult.id,
      coordinate: coordinate,
      title: chargingPoints(routeResult.chargingPointCount),
      subtitle: drivingDistance,
      summary: nil,
      detailTitle: title,
      detailSubtitle: localizer.text("carplay.result.destination_prompt"),
      detailSummary: detailSummary,
      operatorsActionTitle: localizer.text("carplay.result.operators.action"),
      restaurantActionTitle: foodPOI == nil
        ? nil : localizer.text("carplay.result.restaurant.action")
    )
  }

  private func coverageMessage(_ coverage: CandidateSearchCoverage) -> String? {
    switch coverage.status {
    case .complete:
      nil
    case .degraded:
      localizer.text("carplay.coverage.degraded")
    case .stale:
      localizer.text("carplay.coverage.stale")
    }
  }

  private func availabilityText(_ availability: ParkAvailability) -> String? {
    if availability.unknownCount == availability.totalCount {
      return nil
    }
    if availability.isComplete {
      return localizer.format(
        "ride.result.availability.complete.format",
        Int64(availability.knownAvailableCount)
      )
    }
    return localizer.format(
      "ride.result.availability.partial.format",
      Int64(availability.knownAvailableCount),
      Int64(availability.unknownCount)
    )
  }

  private func minimumCount(_ value: Int) -> String {
    localizer.format("unit.minimum_count.format", Int64(value))
  }

  private func kilowatts(_ value: Int) -> String {
    localizer.format("unit.kilowatts.format", Int64(value))
  }

  private func minimumKilowatts(_ value: Int) -> String {
    localizer.format("unit.minimum_kilowatts.format", Int64(value))
  }

  private func chargingPoints(_ value: Int) -> String {
    localizer.format(
      value == 1 ? "unit.charging_points.one" : "unit.charging_points.other",
      Int64(value)
    )
  }

  private func roundedKilometers(_ meters: Int) -> Int {
    (meters + 500) / 1_000
  }
}

@MainActor
final class CarPlayRideDraftController {
  private(set) var draft: RideSearchDraft?

  func select(profile: UserProfile) {
    draft = RideSearchDraft(profile: profile)
  }

  func select(destination: SavedDestination) {
    draft = RideSearchDraft(destination: destination)
  }

  func apply(_ selection: CarPlayCriteriaSelection) {
    guard var current = draft else {
      return
    }
    switch selection {
    case .distanceRange(let value):
      current.criteria.distanceRange = value
    case .minimumChargingPoints(let value):
      current.criteria.minimumChargingPoints = value
    case .minimumPower(let value):
      current.criteria.minimumPower = value
    case .foodChain(let value):
      current.criteria.foodChain = value
    }
    draft = current
  }
}
