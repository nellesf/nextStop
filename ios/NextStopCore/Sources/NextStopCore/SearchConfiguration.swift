import Foundation

public enum DistanceRangeOption: String, CaseIterable, Codable, Sendable {
  case kilometers15To50 = "15_50_km"
  case kilometers50To100 = "50_100_km"
  case kilometers100To150 = "100_150_km"

  public var range: ClosedRange<Meters> {
    switch self {
    case .kilometers15To50:
      Meters(15_000)...Meters(50_000)
    case .kilometers50To100:
      Meters(50_000)...Meters(100_000)
    case .kilometers100To150:
      Meters(100_000)...Meters(150_000)
    }
  }

  public var localizationKey: String {
    "search.distance_range.\(rawValue)"
  }
}

public enum MinimumChargingPointsOption: Int, CaseIterable, Codable, Sendable {
  case two = 2
  case four = 4
  case six = 6
  case eight = 8
  case ten = 10
  case twelve = 12
  case sixteen = 16
  case twenty = 20
}

public enum MinimumPowerOption: Int, CaseIterable, Codable, Sendable {
  case eleven = 11
  case twentyTwo = 22
  case fifty = 50
  case oneHundred = 100
  case oneHundredFifty = 150
  case twoHundred = 200
  case twoHundredFifty = 250
  case threeHundred = 300
  case threeHundredFifty = 350
  case fourHundred = 400
}

public enum FoodChain: String, CaseIterable, Codable, Sendable {
  case mcdonalds
  case burgerKing = "burger_king"
  case kfc
  case subway

  public var localizationKey: String {
    "search.food_chain.\(rawValue)"
  }
}

public struct RideCriteria: Hashable, Codable, Sendable {
  public var distanceRange: DistanceRangeOption
  public var minimumChargingPoints: MinimumChargingPointsOption
  public var minimumPower: MinimumPowerOption
  public var foodChain: FoodChain?

  public init(
    distanceRange: DistanceRangeOption,
    minimumChargingPoints: MinimumChargingPointsOption,
    minimumPower: MinimumPowerOption,
    foodChain: FoodChain?
  ) {
    self.distanceRange = distanceRange
    self.minimumChargingPoints = minimumChargingPoints
    self.minimumPower = minimumPower
    self.foodChain = foodChain
  }
}

public enum SearchConfiguration {
  public static let maximumDistanceFromRoute = Meters(5_000)
  public static let maximumChargingParkClusterDistance = Meters(200)
  public static let maximumFoodDistance = Meters(500)
  public static let maximumResultCount = 5
  public static let maximumRouteCoordinateCount = 8_000
  public static let maximumRouteSegmentLength = Meters(250_000)
  public static let maximumRouteLength = Meters(2_500_000)
  public static let supportedRouteLatitudeRange = 34.0...72.0
  public static let supportedRouteLongitudeRange = -25.0...45.0
  public static let recentDestinationLimit = 20

  public static let defaultCriteria = RideCriteria(
    distanceRange: .kilometers50To100,
    minimumChargingPoints: .four,
    minimumPower: .oneHundred,
    foodChain: nil
  )
}
