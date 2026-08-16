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
  case minimumAvailablePoints
  case minimumPower
  case foodChain
}

enum CarPlayCriteriaSelection: Hashable, Sendable {
  case distanceRange(DistanceRangeOption)
  case minimumChargingPoints(MinimumChargingPointsOption)
  case minimumAvailablePoints(MinimumAvailablePointsOption?)
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
}

struct CarPlayResultPresentation: Equatable, Sendable {
  let id: UUID
  let coordinate: Coordinate
  let title: String
  let subtitle: String
  let summary: String
  let detailTitle: String
  let detailSubtitle: String
  let detailSummary: String?
  let navigationActionTitle: String
}

struct CarPlayResultsPresentation: Equatable, Sendable {
  let title: String
  let points: [CarPlayResultPresentation]
  let coverageMessage: String?
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
      searchActionTitle: localizer.text("ride.search.action")
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
    case .minimumAvailablePoints:
      [
        CarPlayCriteriaOptionPresentation(
          selection: .minimumAvailablePoints(nil),
          title: localizer.text("availability.any"),
          selected: draft.criteria.minimumAvailablePoints == nil
        )
      ]
        + MinimumAvailablePointsOption.allCases.map { value in
          CarPlayCriteriaOptionPresentation(
            selection: .minimumAvailablePoints(value),
            title: minimumCount(value.rawValue),
            selected: value == draft.criteria.minimumAvailablePoints
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
          title: localizer.text("food.any"),
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

  func results(_ outcome: RideCandidateSearchOutcome) -> CarPlayResultsPresentation {
    precondition(outcome.results.count <= SearchConfiguration.maximumResultCount)
    return CarPlayResultsPresentation(
      title: localizer.text("ride.results.title"),
      points: outcome.results.map(result),
      coverageMessage: coverageMessage(outcome.coverage)
    )
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
    case .minimumAvailablePoints:
      return CarPlayCriterionPresentation(
        field: field,
        title: localizer.text("profile.minimum_available"),
        value: criteria.minimumAvailablePoints.map { minimumCount($0.rawValue) }
          ?? localizer.text("availability.any")
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
        title: localizer.text("profile.fast_food"),
        value: criteria.foodChain.map { localizer.text($0.localizationKey) }
          ?? localizer.text("food.any")
      )
    }
  }

  private func result(_ routeResult: RouteSearchResult) -> CarPlayResultPresentation {
    let candidate = routeResult.candidate
    let park = candidate.park
    let drivingDistance = kilometers(candidate.actualDrivingDistance.value)
    let routeDistance = localizer.format(
      "carplay.result.route_distance.format",
      Int64(roundedKilometers(candidate.distanceFromRoute.value))
    )
    let availability = availabilityText(park.availability)
    let summary = localizer.format(
      "carplay.result.charging_summary.format",
      Int64(park.chargingPointCount),
      availability,
      Int64(park.maximumPower.value)
    )
    let foodSummary = routeResult.matchingFoodPOI.map { food in
      localizer.format(
        "carplay.result.food.format",
        food.name,
        Int64(food.distanceFromPark.value)
      )
    }
    let operatorSummary = park.operatorChargingPoints.map { chargingOperator in
      localizer.format(
        "carplay.result.operator.format",
        chargingOperator.name,
        Int64(chargingOperator.chargingPointCount)
      )
    }
    .joined(separator: "\n")
    let detailSummary = [operatorSummary, summary, foodSummary]
      .compactMap { $0 }
      .joined(separator: "\n")
    return CarPlayResultPresentation(
      id: park.id,
      coordinate: park.navigationCoordinate,
      title: park.name,
      subtitle: "\(drivingDistance) · \(routeDistance)",
      summary: summary,
      detailTitle: park.name,
      detailSubtitle: "\(drivingDistance) · \(availability)",
      detailSummary: detailSummary,
      navigationActionTitle: localizer.text("ride.result.navigate")
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

  private func availabilityText(_ availability: ParkAvailability) -> String {
    if availability.unknownCount == availability.totalCount {
      return localizer.text("ride.result.availability.unknown")
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

  private func kilometers(_ value: Int) -> String {
    localizer.format("unit.kilometers.format", Int64(roundedKilometers(value)))
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
    case .minimumAvailablePoints(let value):
      current.criteria.minimumAvailablePoints = value
    case .minimumPower(let value):
      current.criteria.minimumPower = value
    case .foodChain(let value):
      current.criteria.foodChain = value
    }
    draft = current
  }
}
