import Foundation

enum LocalizedFormat {
  static func kilowatts(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.kilowatts.format", comment: "Power in kilowatts"),
      Int64(value)
    )
  }

  static func minimumCount(_ value: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.minimum_count.format", comment: "Minimum number of charging points"),
      Int64(value)
    )
  }

  static func kilometers(_ meters: Int) -> String {
    String.localizedStringWithFormat(
      NSLocalizedString("unit.kilometers.format", comment: "Distance in rounded kilometers"),
      Int64((meters + 500) / 1_000)
    )
  }

  static func duration(_ seconds: Int) -> String {
    let totalMinutes = max(0, (seconds + 30) / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    if hours > 0 {
      return String.localizedStringWithFormat(
        NSLocalizedString(
          "unit.duration.hours_minutes.format", comment: "Duration in hours and minutes"),
        Int64(hours),
        Int64(minutes)
      )
    }

    return String.localizedStringWithFormat(
      NSLocalizedString("unit.duration.minutes.format", comment: "Duration in minutes"),
      Int64(minutes)
    )
  }
}
