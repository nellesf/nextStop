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
    String.localizedStringWithFormat(
      NSLocalizedString("unit.charging_points.format", comment: "Number of charging points"),
      Int64(value)
    )
  }

  static func kilometers(_ meters: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.kilometers.format", comment: "Distance in rounded kilometers"),
      Int64((meters + 500) / 1_000)
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
