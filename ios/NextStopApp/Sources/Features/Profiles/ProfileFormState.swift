import Foundation
import NextStopCore

enum ProfileFormValidationError: Error, Equatable, Identifiable {
  case nameRequired
  case destinationRequired
  case restaurantChainRequired

  var id: Self { self }

  var localizationKey: String {
    switch self {
    case .nameRequired:
      "profile.validation.name"
    case .destinationRequired:
      "profile.validation.destination"
    case .restaurantChainRequired:
      "profile.validation.restaurant_chain"
    }
  }
}

struct ProfileFormState: Equatable {
  let profileID: UUID?
  let createdAt: Date?
  var name: String
  var destination: SavedDestination?
  var distanceRange: DistanceRangeOption
  var minimumChargingPoints: MinimumChargingPointsOption
  var minimumPower: MinimumPowerOption
  var requiresNearbyRestaurant: Bool
  var foodChain: FoodChain?

  init(profile: UserProfile? = nil) {
    profileID = profile?.id
    createdAt = profile?.createdAt
    name = profile?.name ?? ""
    destination = profile?.destination
    distanceRange =
      profile?.criteria.distanceRange ?? SearchConfiguration.defaultCriteria.distanceRange
    minimumChargingPoints =
      profile?.criteria.minimumChargingPoints
      ?? SearchConfiguration.defaultCriteria.minimumChargingPoints
    minimumPower =
      profile?.criteria.minimumPower ?? SearchConfiguration.defaultCriteria.minimumPower
    let initialFoodChain =
      profile?.criteria.foodChain ?? SearchConfiguration.defaultCriteria.foodChain
    requiresNearbyRestaurant = initialFoodChain != nil
    foodChain = initialFoodChain
  }

  mutating func selectPreviousMinimumChargingPoints() {
    moveMinimumChargingPoints(by: -1)
  }

  mutating func selectNextMinimumChargingPoints() {
    moveMinimumChargingPoints(by: 1)
  }

  func makeProfile(now: Date, newID: UUID = UUID()) throws -> UserProfile {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw ProfileFormValidationError.nameRequired
    }
    guard let destination else {
      throw ProfileFormValidationError.destinationRequired
    }
    guard !requiresNearbyRestaurant || foodChain != nil else {
      throw ProfileFormValidationError.restaurantChainRequired
    }

    return try UserProfile(
      id: profileID ?? newID,
      name: trimmedName,
      destination: destination,
      criteria: RideCriteria(
        distanceRange: distanceRange,
        minimumChargingPoints: minimumChargingPoints,
        minimumPower: minimumPower,
        foodChain: requiresNearbyRestaurant ? foodChain : nil
      ),
      createdAt: createdAt ?? now,
      updatedAt: now
    )
  }

  private mutating func moveMinimumChargingPoints(by offset: Int) {
    let options = MinimumChargingPointsOption.allCases
    guard let currentIndex = options.firstIndex(of: minimumChargingPoints) else {
      return
    }
    let nextIndex = currentIndex + offset
    guard options.indices.contains(nextIndex) else { return }
    minimumChargingPoints = options[nextIndex]
  }
}
