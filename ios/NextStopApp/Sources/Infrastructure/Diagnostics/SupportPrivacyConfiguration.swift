import Foundation

struct SupportPrivacyConfiguration: Decodable, Sendable {
  let controllerName: String
  let postalAddress: String
  let email: String

  var isComplete: Bool {
    [controllerName, postalAddress, email].allSatisfy {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.contains("$(")
    } && email.contains("@") && !email.contains(where: \.isWhitespace)
  }

  static func configured(bundle: Bundle = .main) -> Self? {
    guard let url = bundle.url(forResource: "SupportContact", withExtension: "plist"),
      let data = try? Data(contentsOf: url),
      let configuration = try? PropertyListDecoder().decode(Self.self, from: data),
      configuration.isComplete
    else { return nil }
    return configuration
  }
}
