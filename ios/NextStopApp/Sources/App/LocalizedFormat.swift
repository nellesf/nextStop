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
}
