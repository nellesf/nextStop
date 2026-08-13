import Foundation
import NextStopCore

enum ProfileFormValidationError: Error, Equatable, Identifiable {
  case nameRequired
  case destinationRequired

  var id: Self { self }

  var localizationKey: String {
    switch self {
    case .nameRequired:
      "profile.validation.name"
    case .destinationRequired:
      "profile.validation.destination"
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
  var minimumAvailablePoints: MinimumAvailablePointsOption?
  var minimumPower: MinimumPowerOption
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
    minimumAvailablePoints =
      profile?.criteria.minimumAvailablePoints
      ?? SearchConfiguration.defaultCriteria.minimumAvailablePoints
    minimumPower =
      profile?.criteria.minimumPower ?? SearchConfiguration.defaultCriteria.minimumPower
    foodChain = profile?.criteria.foodChain ?? SearchConfiguration.defaultCriteria.foodChain
  }

  func makeProfile(now: Date, newID: UUID = UUID()) throws -> UserProfile {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw ProfileFormValidationError.nameRequired
    }
    guard let destination else {
      throw ProfileFormValidationError.destinationRequired
    }

    return try UserProfile(
      id: profileID ?? newID,
      name: trimmedName,
      destination: destination,
      criteria: RideCriteria(
        distanceRange: distanceRange,
        minimumChargingPoints: minimumChargingPoints,
        minimumAvailablePoints: minimumAvailablePoints,
        minimumPower: minimumPower,
        foodChain: foodChain
      ),
      createdAt: createdAt ?? now,
      updatedAt: now
    )
  }
}
