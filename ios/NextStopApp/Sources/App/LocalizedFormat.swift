import Foundation

enum LocalizedFormat {
  static func kilowatts(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.kilowatts.format", comment: "Power in kilowatts"),
      Int64(value)
    )
  }

  static func minimumKilowatts(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "unit.minimum_kilowatts.format",
        comment: "Minimum charging power or higher"
      ),
      Int64(value)
    )
  }

  static func minimumCount(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.minimum_count.format", comment: "Minimum number of charging points"),
      Int64(value)
    )
  }

  static func chargingPoints(_ value: Int) -> String {
    let key = value == 1 ? "unit.charging_points.one" : "unit.charging_points.other"
    return String.localizedStringWithFormat(
      NSLocalizedString(key, comment: "Number of charging points"),
      Int64(value)
    )
  }

  static func kilometers(_ meters: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.kilometers.format", comment: "Distance in rounded kilometers"),
      Int64((meters + 500) / 1_000)
    )
  }

  static func powerOptionCount(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "profile.minimum_power.option_count.format",
        comment: "Number of selectable charging power levels"
      ),
      Int64(value)
    )
  }

  static func maximumRouteCorridor(_ meters: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "profile.route_corridor.info.format",
        comment: "Fixed maximum route corridor in rounded kilometers"
      ),
      Int64((meters + 500) / 1_000)
    )
  }

  static func maximumFoodDistance(_ meters: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "profile.food_distance.info.format",
        comment: "Fixed maximum distance from a restaurant to a charging park"
      ),
      Int64(meters)
    )
  }

  static func direction(to destination: String) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "ride.results.direction.format",
        comment: "Destination direction shown above iPhone search results"
      ),
      destination
    )
  }

  static func resultCount(_ value: Int) -> String {
    let key = value == 1 ? "ride.results.count.one" : "ride.results.count.other"
    return String.localizedStringWithFormat(
      NSLocalizedString(key, comment: "Number of iPhone search results"),
      Int64(value)
    )
  }

  static func drivingDistanceToStop(_ meters: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "ride.result.driving_distance_to_stop.format",
        comment: "Actual driving distance to a charging stop"
      ),
      Int64((meters + 500) / 1_000)
    )
  }

  static func matchingChargingPoints(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "ride.result.matching_charging_points.format",
        comment: "Number of charging points matching the selected minimum power"
      ),
      Int64(value)
    )
  }

  static func resultRank(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "ride.result.rank.accessibility.format",
        comment: "Accessible ordinal label for one search result"
      ),
      Int64(value)
    )
  }

  static func metersToPlace(_ meters: Int, placeName: String) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString(
        "unit.meters_to_place.format",
        comment: "Straight-line distance from a charging location to a nearby place"
      ),
      Int64(meters),
      placeName
    )
  }
}
