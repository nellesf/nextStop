import Combine
import Foundation

enum AppDiagnosticOperation: String, Codable, Sendable {
  case candidateSearch
  case route
  case candidateDistance
  case authentication
  case placeLookup
  case mapsLaunch
}

enum AppDiagnosticOutcome: String, Codable, Sendable {
  case failure
  case retryScheduled
  case recovered
}

enum AppDiagnosticCategory: String, Codable, Sendable {
  case networkTimeout
  case networkLost
  case offline
  case connection
  case http
  case invalidResponse
  case authentication
  case noRoute
  case invalidRoute
  case throttled
  case unknown
}

enum AppDiagnosticErrorDomain: String, Codable, Sendable {
  case url
  case mapKit
  case routePlanning
  case unknown
}

/// The complete allowlist for diagnostics. Never add raw errors, URLs, user input,
/// provider records, credentials, coordinates, or device/installation identifiers.
struct AppDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let timestamp: Date
  let operation: AppDiagnosticOperation
  let outcome: AppDiagnosticOutcome
  let category: AppDiagnosticCategory
  let durationMilliseconds: Int
  let attempt: Int
  let httpStatus: Int?
  let errorDomain: AppDiagnosticErrorDomain?
  let errorCode: Int?
  let serverRequestID: UUID?
  let edgeRequestID: UUID?

  init(
    timestamp: Date = Date(),
    operation: AppDiagnosticOperation,
    outcome: AppDiagnosticOutcome,
    category: AppDiagnosticCategory,
    durationMilliseconds: Int,
    attempt: Int = 1,
    httpStatus: Int? = nil,
    errorDomain: AppDiagnosticErrorDomain? = nil,
    errorCode: Int? = nil,
    serverRequestID: UUID? = nil,
    edgeRequestID: UUID? = nil
  ) {
    self.init(
      id: UUID(),
      timestamp: timestamp,
      operation: operation,
      outcome: outcome,
      category: category,
      durationMilliseconds: durationMilliseconds,
      attempt: attempt,
      httpStatus: httpStatus,
      errorDomain: errorDomain,
      errorCode: errorCode,
      serverRequestID: serverRequestID,
      edgeRequestID: edgeRequestID
    )
  }

  private init(
    id: UUID,
    timestamp: Date,
    operation: AppDiagnosticOperation,
    outcome: AppDiagnosticOutcome,
    category: AppDiagnosticCategory,
    durationMilliseconds: Int,
    attempt: Int,
    httpStatus: Int?,
    errorDomain: AppDiagnosticErrorDomain?,
    errorCode: Int?,
    serverRequestID: UUID?,
    edgeRequestID: UUID?
  ) {
    self.id = id
    let seconds = timestamp.timeIntervalSince1970
    self.timestamp = Date(
      timeIntervalSince1970: seconds.isFinite ? min(max(seconds, 0), 4_102_444_800) : 0
    )
    self.operation = operation
    self.outcome = outcome
    self.category = category
    self.durationMilliseconds = min(max(durationMilliseconds, 0), 300_000)
    self.attempt = min(max(attempt, 1), 3)
    self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    self.errorDomain = errorDomain
    self.errorCode = errorCode.flatMap { (-10_000...10_000).contains($0) ? $0 : nil }
    self.serverRequestID = serverRequestID
    self.edgeRequestID = edgeRequestID
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(UUID.self, forKey: .id),
      timestamp: try values.decode(Date.self, forKey: .timestamp),
      operation: try values.decode(AppDiagnosticOperation.self, forKey: .operation),
      outcome: try values.decode(AppDiagnosticOutcome.self, forKey: .outcome),
      category: try values.decode(AppDiagnosticCategory.self, forKey: .category),
      durationMilliseconds: try values.decode(Int.self, forKey: .durationMilliseconds),
      attempt: try values.decode(Int.self, forKey: .attempt),
      httpStatus: try values.decodeIfPresent(Int.self, forKey: .httpStatus),
      errorDomain: try values.decodeIfPresent(AppDiagnosticErrorDomain.self, forKey: .errorDomain),
      errorCode: try values.decodeIfPresent(Int.self, forKey: .errorCode),
      serverRequestID: try values.decodeIfPresent(UUID.self, forKey: .serverRequestID),
      edgeRequestID: try values.decodeIfPresent(UUID.self, forKey: .edgeRequestID)
    )
  }
}

@MainActor
protocol AppDiagnosticRecording: AnyObject {
  func record(_ event: AppDiagnosticEvent)
}

@MainActor
final class NoopAppDiagnostics: AppDiagnosticRecording {
  func record(_ event: AppDiagnosticEvent) {}
}

@MainActor
final class AppDiagnosticsStore: ObservableObject, AppDiagnosticRecording {
  static let eventLimit = 200
  static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
  static let maximumFileSize = 256 * 1_024

  @Published private(set) var events: [AppDiagnosticEvent] = []
  @Published private(set) var persistenceAvailable = true
  @Published private(set) var deletionFailed = false
  @Published var recordingEnabled = false {
    didSet {
      if oldValue != recordingEnabled {
        if recordingEnabled {
          persist()
        } else {
          events = []
          // Unlink first: an atomic write can fail on a full disk, leaving old consent.
          _ = removeStoredSnapshot()
        }
      }
    }
  }

  private let fileURL: URL?
  private let clock: () -> Date
  private let removeFile: (URL) throws -> Void

  init(
    fileURL: URL? = nil,
    clock: @escaping () -> Date = Date.init,
    removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
  ) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.clock = clock
    self.removeFile = removeFile
    load()
  }

  func record(_ event: AppDiagnosticEvent) {
    guard recordingEnabled else { return }
    events = retainedEvents(events + [event])
    persist()
  }

  func prune() {
    let retained = retainedEvents(events)
    if retained != events {
      events = retained
      persist()
    }
  }

  func clear() {
    events = []
    guard removeStoredSnapshot() else {
      recordingEnabled = false
      return
    }
    if recordingEnabled { persist() }
  }

  /// Exports only the event allowlist; consent state and storage details stay local.
  func exportData() throws -> Data {
    prune()
    return try Self.encoder().encode(Export(schemaVersion: 1, events: events))
  }

  private func retainedEvents(_ input: [AppDiagnosticEvent]) -> [AppDiagnosticEvent] {
    let now = clock()
    let earliest = now.addingTimeInterval(-Self.retentionInterval)
    var seen = Set<UUID>()
    return Array(
      input.filter { event in
        event.timestamp >= earliest
          && event.timestamp <= now
          && seen.insert(event.id).inserted
      }.sorted { $0.timestamp < $1.timestamp }.suffix(Self.eventLimit))
  }

  private func load() {
    guard let fileURL else {
      persistenceAvailable = false
      return
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let file = try FileHandle(forReadingFrom: fileURL)
      defer { try? file.close() }
      let data = try file.read(upToCount: Self.maximumFileSize + 1) ?? Data()
      guard data.count <= Self.maximumFileSize else { throw StorageError.invalidFile }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let snapshot = try decoder.decode(Snapshot.self, from: data)
      guard snapshot.schemaVersion == 1 else { throw StorageError.invalidFile }
      events = snapshot.recordingEnabled ? retainedEvents(snapshot.events) : []
      recordingEnabled = snapshot.recordingEnabled
      // Re-encode the allowlist so unknown fields and expired records cannot linger.
      persist()
    } catch {
      // A corrupt diagnostics file must never prevent a search or expose its contents.
      events = []
      recordingEnabled = false
      _ = removeStoredSnapshot()
    }
  }

  private func persist() {
    guard let fileURL else {
      persistenceAvailable = false
      return
    }
    do {
      var directory = fileURL.deletingLastPathComponent()
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try directory.setResourceValues(resourceValues)
      let snapshot = Snapshot(
        schemaVersion: 1,
        recordingEnabled: recordingEnabled,
        events: events
      )
      let data = try Self.encoder().encode(snapshot)
      guard data.count <= Self.maximumFileSize else { throw StorageError.invalidFile }
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
      try savedFile.setResourceValues(resourceValues)
      persistenceAvailable = true
      deletionFailed = false
    } catch {
      // The in-memory report stays usable if storage is locked, full, or unavailable.
      persistenceAvailable = false
    }
  }

  @discardableResult
  private func removeStoredSnapshot() -> Bool {
    guard let fileURL else {
      persistenceAvailable = false
      deletionFailed = true
      return false
    }
    do {
      try removeFile(fileURL)
      persistenceAvailable = true
      deletionFailed = false
      return true
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      persistenceAvailable = true
      deletionFailed = false
      return true
    } catch {
      persistenceAvailable = false
      deletionFailed = true
      return false
    }
  }

  private static func defaultFileURL() -> URL? {
    try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent("events.json", isDirectory: false)
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private struct Snapshot: Codable {
    let schemaVersion: Int
    let recordingEnabled: Bool
    let events: [AppDiagnosticEvent]
  }

  private struct Export: Encodable {
    let schemaVersion: Int
    let events: [AppDiagnosticEvent]
  }

  private enum StorageError: Error {
    case invalidFile
  }
}
