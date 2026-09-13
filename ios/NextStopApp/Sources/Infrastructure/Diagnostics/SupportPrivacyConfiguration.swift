import Foundation
import StoreKit

struct SupportPrivacyConfiguration: Decodable, Sendable {
  let controllerName: String
  let postalAddress: String
  let email: String
  let usesInternalTestPlaceholders: Bool

  init(
    controllerName: String, postalAddress: String, email: String,
    usesInternalTestPlaceholders: Bool = false
  ) {
    self.controllerName = controllerName
    self.postalAddress = postalAddress
    self.email = email
    self.usesInternalTestPlaceholders = usesInternalTestPlaceholders
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    controllerName = try values.decode(String.self, forKey: .controllerName)
    postalAddress = try values.decode(String.self, forKey: .postalAddress)
    email = try values.decode(String.self, forKey: .email)
    usesInternalTestPlaceholders = try values.decodeIfPresent(
      Bool.self, forKey: .usesInternalTestPlaceholders) ?? false
  }

  var isComplete: Bool {
    hasContactValues && !usesInternalTestPlaceholders
      && ![controllerName, postalAddress, email].contains {
        $0.localizedCaseInsensitiveContains("placeholder")
          || $0.localizedCaseInsensitiveContains("platzhalter")
      }
      && !email.lowercased().hasSuffix(".invalid")
  }

  func allowsSubmission(in distribution: SupportReportDistribution) -> Bool {
    if isComplete { return true }
    guard usesInternalTestPlaceholders, hasContactValues else { return false }
    return distribution == .debug || distribution == .verifiedSandbox
  }

  var displayControllerName: String {
    usesInternalTestPlaceholders
      ? String(localized: "report.internal.placeholder.controller") : controllerName
  }

  var displayPostalAddress: String {
    usesInternalTestPlaceholders
      ? String(localized: "report.internal.placeholder.address") : postalAddress
  }

  private var hasContactValues: Bool {
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
        || (configuration.usesInternalTestPlaceholders && configuration.hasContactValues)
    else { return nil }
    return configuration
  }

  private enum CodingKeys: String, CodingKey {
    case controllerName, postalAddress, email, usesInternalTestPlaceholders
  }
}

enum SupportReportDistribution: Equatable, Sendable {
  case debug, verifiedSandbox, production, unknown

  static var initial: Self {
    #if DEBUG
      .debug
    #else
      .unknown
    #endif
  }

  static func current() async -> Self {
    #if DEBUG
      return .debug
    #else
      // TestFlight uses sandbox app transactions. Internal-only distribution is
      // enforced at upload, because StoreKit does not identify the tester group.
      do {
        guard case .verified(let transaction) = try await AppTransaction.shared else {
          return .unknown
        }
        if transaction.environment == .sandbox { return .verifiedSandbox }
        if transaction.environment == .production { return .production }
      } catch {
        // Never infer a test environment from a missing or unverified receipt.
      }
      return .unknown
    #endif
  }
}
