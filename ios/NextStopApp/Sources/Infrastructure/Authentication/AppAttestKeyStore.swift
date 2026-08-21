import Foundation
import Security

enum AppAttestKeyLifecycle: String, Codable, Equatable, Sendable {
  case pendingAttestation
  case serverConfirmationUnknown
  case attested
}

struct AppAttestKeyRecord: Codable, Equatable, Sendable {
  let version: Int
  let keyID: String
  let lifecycle: AppAttestKeyLifecycle
  let pendingAttestationChallenge: AppAttestChallenge?

  init(
    keyID: String,
    lifecycle: AppAttestKeyLifecycle,
    pendingAttestationChallenge: AppAttestChallenge? = nil
  ) {
    version = 1
    self.keyID = keyID
    self.lifecycle = lifecycle
    self.pendingAttestationChallenge = pendingAttestationChallenge
  }
}

protocol AppAttestKeyStoring: Sendable {
  func load() throws -> AppAttestKeyRecord?
  func save(_ record: AppAttestKeyRecord) throws
  func remove() throws
}

enum AppAttestKeyStoreError: Error, Equatable {
  case invalidRecord
  case keychain(OSStatus)
}

struct KeychainAppAttestKeyStore: AppAttestKeyStoring {
  static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
  static let synchronizable = false

  let service: String
  let account: String

  init(bundleIdentifier: String, environment: AppAttestEnvironment, baseURL: URL) {
    let origin = Self.normalizedBackendOrigin(baseURL) ?? "invalid-origin"
    service = "\(bundleIdentifier).app-attest.\(environment.rawValue).\(origin)"
    account = "search-access-key"
  }

  static func normalizedBackendOrigin(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased(),
      !host.isEmpty
    else {
      return nil
    }
    let port: Int
    if let explicitPort = url.port {
      port = explicitPort
    } else {
      switch scheme {
      case "http":
        port = 80
      case "https":
        port = 443
      default:
        return nil
      }
    }
    let serializedHost = host.contains(":") ? "[\(host)]" : host
    return "\(scheme)://\(serializedHost):\(port)"
  }

  func load() throws -> AppAttestKeyRecord? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw AppAttestKeyStoreError.keychain(status)
    }
    guard let data = result as? Data else {
      throw AppAttestKeyStoreError.invalidRecord
    }
    return try Self.decodeRecord(data)
  }

  func save(_ record: AppAttestKeyRecord) throws {
    guard record.version == 1,
      AppAttestTransportValidation.isValidKeyID(record.keyID),
      Self.isValidLifecycle(record)
    else {
      throw AppAttestKeyStoreError.invalidRecord
    }
    let data = try JSONEncoder().encode(record)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: Self.accessibility,
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw AppAttestKeyStoreError.keychain(updateStatus)
    }

    var addition = baseQuery
    for (key, value) in attributes {
      addition[key] = value
    }
    let addStatus = SecItemAdd(addition as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      let retryStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
      guard retryStatus == errSecSuccess else {
        throw AppAttestKeyStoreError.keychain(retryStatus)
      }
      return
    }
    guard addStatus == errSecSuccess else {
      throw AppAttestKeyStoreError.keychain(addStatus)
    }
  }

  func remove() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppAttestKeyStoreError.keychain(status)
    }
  }

  var policyAttributes: [String: Any] {
    [
      kSecAttrAccessible as String: Self.accessibility,
      kSecAttrSynchronizable as String: Self.synchronizable,
    ]
  }

  static func decodeRecord(_ data: Data) throws -> AppAttestKeyRecord {
    guard let record = try? JSONDecoder().decode(AppAttestKeyRecord.self, from: data),
      record.version == 1,
      AppAttestTransportValidation.isValidKeyID(record.keyID),
      isValidLifecycle(record)
    else {
      throw AppAttestKeyStoreError.invalidRecord
    }
    return record
  }

  private static func isValidLifecycle(_ record: AppAttestKeyRecord) -> Bool {
    switch (record.lifecycle, record.pendingAttestationChallenge) {
    case (.pendingAttestation, nil):
      return true
    case (.pendingAttestation, let challenge?):
      return AppAttestTransportValidation.isCanonicalVersion4UUID(challenge.id)
        && challenge.clientData.count == 32
        && challenge.expiresAt.timeIntervalSinceReferenceDate.isFinite
    case (.serverConfirmationUnknown, nil), (.attested, nil):
      return true
    case (.serverConfirmationUnknown, _?), (.attested, _?):
      return false
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: Self.synchronizable,
    ]
  }
}
