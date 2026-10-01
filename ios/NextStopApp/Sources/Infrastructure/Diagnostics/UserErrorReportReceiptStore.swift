import Combine
import CryptoKit
import Foundation

/// The deletion capability is the only persisted report data. Never add message
/// text, diagnostic events, device identity, or authentication access tokens.
struct UserErrorReportReceipt: Codable, Equatable, Identifiable, Sendable {
  var id: UUID { reportID }
  var isPending: Bool { receivedAt == nil }

  let reportID: UUID
  let deletionToken: UUID
  let createdAt: Date
  let receivedAt: Date?
  let expiresAt: Date
}

@MainActor
final class UserErrorReportReceiptStore: ObservableObject {
  static let receiptLimit = 50
  static let maximumFileSize = 64 * 1_024
  static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
  static let clockSkewAllowance: TimeInterval = 5 * 60

  @Published private(set) var receipts: [UserErrorReportReceipt] = []
  @Published private(set) var persistenceAvailable = true

  private let fileURL: URL?
  private let clock: () -> Date
  private let write: (Data, URL) throws -> Void
  private var loadFailed = false

  init(
    fileURL: URL? = nil,
    backendURL: URL = BackendEnvironmentConfiguration.productionURL,
    storageDirectory: URL? = nil,
    clock: @escaping () -> Date = Date.init,
    write: ((Data, URL) throws -> Void)? = nil
  ) {
    let directory = storageDirectory ?? Self.defaultDirectoryURL()
    self.fileURL = fileURL ?? directory.flatMap { Self.scopedFileURL(backendURL: backendURL, directory: $0) }
    self.clock = clock
    self.write = write ?? Self.writeProtected
    if fileURL == nil,
      KeychainAppAttestKeyStore.normalizedBackendOrigin(backendURL)
        == KeychainAppAttestKeyStore.normalizedBackendOrigin(BackendEnvironmentConfiguration.productionURL),
      let directory
    {
      migrateLegacyReceipts(from: directory.appendingPathComponent("receipts.json"))
    }
    if !loadFailed { load() }
  }

  @discardableResult
  func reserve(_ request: UserErrorReportRequest) throws -> UserErrorReportReceipt {
    try prune()
    if let existing = receipts.first(where: { $0.reportID == request.reportID }) {
      guard existing.deletionToken == request.deletionToken else {
        throw UserErrorReportError.invalidRequest
      }
      return existing
    }
    guard receipts.count < Self.receiptLimit else { throw UserErrorReportError.capacityReached }
    let createdAt = clock()
    let pending = UserErrorReportReceipt(
      reportID: request.reportID,
      deletionToken: request.deletionToken,
      createdAt: createdAt,
      receivedAt: nil,
      // A pending receipt also covers a response lost with modest server clock skew.
      expiresAt: createdAt.addingTimeInterval(Self.retentionInterval + Self.clockSkewAllowance)
    )
    try persist(receipts + [pending])
    return pending
  }

  func confirm(_ receipt: UserErrorReportReceipt) throws {
    guard let index = receipts.firstIndex(where: { $0.reportID == receipt.reportID }),
      receipts[index].deletionToken == receipt.deletionToken,
      receipts[index].createdAt == receipt.createdAt,
      !receipt.isPending,
      Self.isValid(receipt)
    else { throw UserErrorReportError.invalidRequest }
    var updated = receipts
    updated[index] = receipt
    try persist(updated)
  }

  func remove(reportID: UUID) throws {
    try persist(receipts.filter { $0.reportID != reportID })
  }

  func prune() throws {
    guard !loadFailed else { throw UserErrorReportError.storageUnavailable }
    let retained = receipts.filter { $0.expiresAt > clock() }
    if retained != receipts { try persist(retained) }
  }

  private func load() {
    guard let fileURL else {
      persistenceAvailable = false
      loadFailed = true
      return
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      receipts = try Self.readReceipts(from: fileURL)
      // Re-encode only the receipt allowlist and discard expired capabilities.
      try persist(receipts.filter { $0.expiresAt > clock() })
    } catch {
      // Preserve unreadable capabilities on disk. Silently replacing a damaged
      // file could remove the user's only way to withdraw a received report.
      persistenceAvailable = false
      loadFailed = true
    }
  }

  private func migrateLegacyReceipts(from legacyURL: URL) {
    guard let fileURL, FileManager.default.fileExists(atPath: legacyURL.path) else { return }
    do {
      let legacy = try Self.readReceipts(from: legacyURL)
      let current = FileManager.default.fileExists(atPath: fileURL.path)
        ? try Self.readReceipts(from: fileURL) : []
      var merged = Dictionary(uniqueKeysWithValues: current.map { ($0.reportID, $0) })
      for receipt in legacy where receipt.expiresAt > clock() {
        if let existing = merged[receipt.reportID] {
          guard existing.deletionToken == receipt.deletionToken,
            existing.createdAt == receipt.createdAt,
            existing == receipt || existing.isPending || receipt.isPending
          else { throw UserErrorReportError.storageUnavailable }
          if existing.isPending { merged[receipt.reportID] = receipt }
        } else { merged[receipt.reportID] = receipt }
      }
      let retained = merged.values.filter { $0.expiresAt > clock() }
        .sorted { $0.createdAt < $1.createdAt }
      guard retained.count <= Self.receiptLimit else { throw UserErrorReportError.storageUnavailable }
      try persist(retained)
      // Remove the old capabilities only after the scoped file is written safely.
      try FileManager.default.removeItem(at: legacyURL)
    } catch {
      persistenceAvailable = false
      loadFailed = true
    }
  }

  private static func readReceipts(from fileURL: URL) throws -> [UserErrorReportReceipt] {
    let file = try FileHandle(forReadingFrom: fileURL)
    defer { try? file.close() }
    let data = try file.read(upToCount: maximumFileSize + 1) ?? Data()
    guard data.count <= maximumFileSize else { throw UserErrorReportError.storageUnavailable }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(Snapshot.self, from: data)
    guard snapshot.schemaVersion == 1,
      snapshot.receipts.count <= receiptLimit,
      Set(snapshot.receipts.map(\.reportID)).count == snapshot.receipts.count,
      snapshot.receipts.allSatisfy(isValid)
    else { throw UserErrorReportError.storageUnavailable }
    return snapshot.receipts
  }

  private func persist(_ updated: [UserErrorReportReceipt]) throws {
    guard !loadFailed, let fileURL else {
      persistenceAvailable = false
      throw UserErrorReportError.storageUnavailable
    }
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(Snapshot(schemaVersion: 1, receipts: updated))
      guard data.count <= Self.maximumFileSize else {
        throw UserErrorReportError.storageUnavailable
      }
      try write(data, fileURL)
      receipts = updated
      persistenceAvailable = true
    } catch {
      persistenceAvailable = false
      throw UserErrorReportError.storageUnavailable
    }
  }

  private static func isValid(_ receipt: UserErrorReportReceipt) -> Bool {
    let duration = receipt.expiresAt.timeIntervalSince(receipt.createdAt)
    guard receipt.createdAt.timeIntervalSince1970.isFinite,
      receipt.createdAt.timeIntervalSince1970 >= 0,
      duration.isFinite, duration > 0
    else { return false }
    if let receivedAt = receipt.receivedAt {
      return receivedAt >= receipt.createdAt.addingTimeInterval(-clockSkewAllowance)
        && receivedAt.timeIntervalSince(receipt.createdAt)
          <= retentionInterval + 2 * clockSkewAllowance
        && receivedAt < receipt.expiresAt
        && receipt.expiresAt.timeIntervalSince(receivedAt) <= retentionInterval + 1
    }
    return duration <= retentionInterval + clockSkewAllowance + 1
  }

  private static func writeProtected(_ data: Data, to fileURL: URL) throws {
    var directory = fileURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    #if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directory.path
      )
      try data.write(
        to: fileURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
    #else
      try data.write(to: fileURL, options: .atomic)
    #endif
    var savedFile = fileURL
    try savedFile.setResourceValues(values)
  }

  static func scopedFileURL(backendURL: URL, directory: URL) -> URL? {
    guard let origin = KeychainAppAttestKeyStore.normalizedBackendOrigin(backendURL) else { return nil }
    let key = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(key, isDirectory: true)
      .appendingPathComponent("receipts.json", isDirectory: false)
  }

  private static func defaultDirectoryURL() -> URL? {
    try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("ErrorReportReceipts", isDirectory: true)
  }

  private struct Snapshot: Codable {
    let schemaVersion: Int
    let receipts: [UserErrorReportReceipt]
  }
}
