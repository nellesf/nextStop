import Foundation
import NextStopCore
import SwiftData

enum ProfilePersistenceError: Error, Equatable {
  case invalidStoredValue(field: String, value: String)
}

@Model
final class StoredProfile {
  @Attribute(.unique) var id: UUID
  var name: String
  var destinationName: String
  var destinationLatitude: Double
  var destinationLongitude: Double
  var destinationApplePlaceIdentifier: String?
  var destinationDisplayAddress: String?
  var distanceRangeRawValue: String
  var minimumChargingPointsRawValue: Int
  var minimumAvailablePointsRawValue: Int?
  var minimumPowerRawValue: Int
  var foodChainRawValue: String?
  var createdAt: Date
  var updatedAt: Date

  init(profile: UserProfile) {
    id = profile.id
    name = profile.name
    destinationName = profile.destination.displayName
    destinationLatitude = profile.destination.coordinate.latitude
    destinationLongitude = profile.destination.coordinate.longitude
    destinationApplePlaceIdentifier = profile.destination.applePlaceIdentifier
    destinationDisplayAddress = profile.destination.displayAddress
    distanceRangeRawValue = profile.criteria.distanceRange.rawValue
    minimumChargingPointsRawValue = profile.criteria.minimumChargingPoints.rawValue
    minimumAvailablePointsRawValue = profile.criteria.minimumAvailablePoints?.rawValue
    minimumPowerRawValue = profile.criteria.minimumPower.rawValue
    foodChainRawValue = profile.criteria.foodChain?.rawValue
    createdAt = profile.createdAt
    updatedAt = profile.updatedAt
  }

  func update(from profile: UserProfile) {
    name = profile.name
    destinationName = profile.destination.displayName
    destinationLatitude = profile.destination.coordinate.latitude
    destinationLongitude = profile.destination.coordinate.longitude
    destinationApplePlaceIdentifier = profile.destination.applePlaceIdentifier
    destinationDisplayAddress = profile.destination.displayAddress
    distanceRangeRawValue = profile.criteria.distanceRange.rawValue
    minimumChargingPointsRawValue = profile.criteria.minimumChargingPoints.rawValue
    minimumAvailablePointsRawValue = profile.criteria.minimumAvailablePoints?.rawValue
    minimumPowerRawValue = profile.criteria.minimumPower.rawValue
    foodChainRawValue = profile.criteria.foodChain?.rawValue
    createdAt = profile.createdAt
    updatedAt = profile.updatedAt
  }

  func domainProfile() throws -> UserProfile {
    guard let distanceRange = DistanceRangeOption(rawValue: distanceRangeRawValue) else {
      throw ProfilePersistenceError.invalidStoredValue(
        field: "distanceRange",
        value: distanceRangeRawValue
      )
    }
    guard
      let minimumChargingPoints = MinimumChargingPointsOption(
        rawValue: minimumChargingPointsRawValue
      )
    else {
      throw ProfilePersistenceError.invalidStoredValue(
        field: "minimumChargingPoints",
        value: String(minimumChargingPointsRawValue)
      )
    }
    let minimumAvailablePoints = try optionalMinimumAvailablePoints()
    guard let minimumPower = MinimumPowerOption(rawValue: minimumPowerRawValue) else {
      throw ProfilePersistenceError.invalidStoredValue(
        field: "minimumPower",
        value: String(minimumPowerRawValue)
      )
    }
    let foodChain = try optionalFoodChain()
    let coordinate = try Coordinate(
      latitude: destinationLatitude,
      longitude: destinationLongitude
    )
    let destination = try SavedDestination(
      displayName: destinationName,
      coordinate: coordinate,
      applePlaceIdentifier: destinationApplePlaceIdentifier,
      displayAddress: destinationDisplayAddress
    )

    return try UserProfile(
      id: id,
      name: name,
      destination: destination,
      criteria: RideCriteria(
        distanceRange: distanceRange,
        minimumChargingPoints: minimumChargingPoints,
        minimumAvailablePoints: minimumAvailablePoints,
        minimumPower: minimumPower,
        foodChain: foodChain
      ),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  private func optionalMinimumAvailablePoints() throws -> MinimumAvailablePointsOption? {
    guard let minimumAvailablePointsRawValue else {
      return nil
    }
    guard let value = MinimumAvailablePointsOption(rawValue: minimumAvailablePointsRawValue) else {
      throw ProfilePersistenceError.invalidStoredValue(
        field: "minimumAvailablePoints",
        value: String(minimumAvailablePointsRawValue)
      )
    }
    return value
  }

  private func optionalFoodChain() throws -> FoodChain? {
    guard let foodChainRawValue else {
      return nil
    }
    guard let value = FoodChain(rawValue: foodChainRawValue) else {
      throw ProfilePersistenceError.invalidStoredValue(
        field: "foodChain",
        value: foodChainRawValue
      )
    }
    return value
  }
}
