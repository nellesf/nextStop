import Foundation
import XCTest

@testable import NextStopApp

@MainActor
final class AppDiagnosticsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testEventBoundsApplyDuringConstructionAndDecoding() throws {
    let bounded = AppDiagnosticEvent(
      timestamp: Date(timeIntervalSince1970: .nan),
      operation: .candidateSearch,
      outcome: .failure,
      category: .http,
      durationMilliseconds: Int.max,
      attempt: Int.min,
      httpStatus: 600,
      errorDomain: .url,
      errorCode: Int.min
    )
    XCTAssertEqual(bounded.timestamp, Date(timeIntervalSince1970: 0))
    XCTAssertEqual(bounded.durationMilliseconds, 300_000)
    XCTAssertEqual(bounded.attempt, 1)
    XCTAssertNil(bounded.httpStatus)
    XCTAssertNil(bounded.errorCode)

    var fields = try eventFields(event())
    fields["durationMilliseconds"] = -100
    fields["attempt"] = 99
    fields["httpStatus"] = 99
    fields["errorCode"] = 10_001
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      AppDiagnosticEvent.self,
      from: JSONSerialization.data(withJSONObject: fields)
    )
    XCTAssertEqual(decoded.durationMilliseconds, 0)
    XCTAssertEqual(decoded.attempt, 3)
    XCTAssertNil(decoded.httpStatus)
    XCTAssertNil(decoded.errorCode)
  }

  func testRingKeepsOnlyNewestTwoHundredEventsWithinSevenDays() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    store.recordingEnabled = true
    store.record(event(timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60)))
    store.record(event(timestamp: now.addingTimeInterval(1)))
    for index in 0...200 {
      store.record(
        event(
          timestamp: now.addingTimeInterval(TimeInterval(index - 200)),
          duration: index
        ))
    }

    XCTAssertEqual(store.events.count, 200)
    XCTAssertEqual(store.events.first?.durationMilliseconds, 1)
    XCTAssertEqual(store.events.last?.durationMilliseconds, 200)
    let reloaded = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertEqual(reloaded.events, store.events)
    XCTAssertLessThan(try Data(contentsOf: fixture.fileURL).count, 256 * 1_024)
  }

  func testExportExpiresOldEventsAndClearPreservesRecordingPreference() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let clock = MutableClock(now)
    let store = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { clock.now })
    XCTAssertFalse(store.recordingEnabled)
    store.recordingEnabled = true
    store.record(event())
    clock.now = now.addingTimeInterval(7 * 24 * 60 * 60 + 1)
    let export = try exportFields(store)
    XCTAssertTrue(try XCTUnwrap(export["events"] as? [[String: Any]]).isEmpty)
    XCTAssertNil(export["recordingEnabled"])
    XCTAssertTrue(store.events.isEmpty)

    store.record(event(timestamp: clock.now))
    store.clear()
    XCTAssertTrue(store.events.isEmpty)
    let reloaded = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { clock.now })
    XCTAssertTrue(reloaded.recordingEnabled)
    XCTAssertTrue(reloaded.events.isEmpty)
  }

  func testRecordingRequiresOptInAndDisablingDeletesPastAndFutureEvents() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertFalse(store.recordingEnabled)
    store.record(event())
    XCTAssertTrue(store.events.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))

    store.recordingEnabled = true
    store.record(event())
    XCTAssertEqual(store.events.count, 1)
    let optedIn = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertTrue(optedIn.recordingEnabled)
    XCTAssertEqual(optedIn.events.count, 1)

    store.recordingEnabled = false
    XCTAssertTrue(store.events.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    store.record(event())
    XCTAssertTrue(store.events.isEmpty)
    let optedOut = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertFalse(optedOut.recordingEnabled)
    XCTAssertTrue(optedOut.events.isEmpty)
  }

  func testReloadAndExportStripUnknownFieldsAndKeepOnlyAllowlistedDetails() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let original = event()
    let sentinel = "PRIVATE_ROUTE_TOKEN_DESTINATION_SENTINEL"
    var fields = try eventFields(original)
    fields["url"] = sentinel
    fields["localizedDescription"] = sentinel
    fields["coordinates"] = [49.664160, 11.470720]
    let snapshot: [String: Any] = [
      "schemaVersion": 1,
      "recordingEnabled": true,
      "events": [fields, fields],
      "authorization": sentinel,
      "deviceID": sentinel,
    ]
    try JSONSerialization.data(withJSONObject: snapshot).write(to: fixture.fileURL)

    let store = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertEqual(store.events, [original])
    let exported = try store.exportData()
    let exportedText = try XCTUnwrap(String(data: exported, encoding: .utf8))
    let persistedText = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    for text in [exportedText, persistedText] {
      XCTAssertFalse(text.contains(sentinel))
      XCTAssertFalse(text.contains("coordinates"))
      XCTAssertFalse(text.contains("49.66416"))
      XCTAssertFalse(text.contains("localizedDescription"))
    }
    let exportedFields = try exportFields(store)
    XCTAssertEqual(Set(exportedFields.keys), ["schemaVersion", "events"])
    let events = try XCTUnwrap(exportedFields["events"] as? [[String: Any]])
    XCTAssertEqual(
      Set(try XCTUnwrap(events.first).keys),
      [
        "id", "timestamp", "operation", "outcome", "category", "durationMilliseconds", "attempt",
      ])
  }

  func testMalformedUnknownEnumAndOversizedFilesRecoverToEmptySanitizedStore() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var fields = try eventFields(event())
    fields["category"] = "PRIVATE_UNSUPPORTED_CATEGORY"
    let unknownEnum = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "recordingEnabled": true,
      "events": [fields],
    ])
    let inputs = [
      Data("invalid json PRIVATE_SENTINEL".utf8),
      unknownEnum,
      Data(repeating: 120, count: AppDiagnosticsStore.maximumFileSize + 1),
    ]
    for input in inputs {
      try input.write(to: fixture.fileURL)
      let store = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
      XCTAssertTrue(store.events.isEmpty)
      XCTAssertFalse(store.recordingEnabled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }
  }

  func testDeletionFailureIsVisibleStopsRecordingAndCanBeRetried() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var deletionAllowed = false
    let store = AppDiagnosticsStore(
      fileURL: fixture.fileURL,
      clock: { self.now },
      removeFile: { url in
        guard deletionAllowed else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
      }
    )
    store.recordingEnabled = true
    store.record(event())
    store.clear()
    XCTAssertFalse(store.recordingEnabled)
    XCTAssertFalse(store.persistenceAvailable)
    XCTAssertTrue(store.deletionFailed)
    XCTAssertTrue(store.events.isEmpty)
    store.record(event())
    XCTAssertTrue(store.events.isEmpty)

    deletionAllowed = true
    store.clear()
    XCTAssertFalse(store.deletionFailed)
    XCTAssertTrue(store.persistenceAvailable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    let reloaded = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertFalse(reloaded.recordingEnabled)
    XCTAssertTrue(reloaded.events.isEmpty)
  }

  func testClearRemovesOldConsentBeforeReplacementWriteCanFail() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppDiagnosticsStore(
      fileURL: fixture.fileURL,
      clock: { self.now },
      removeFile: { url in
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: fixture.directory)
        try Data().write(to: fixture.directory)
      }
    )
    store.recordingEnabled = true
    store.record(event())
    store.clear()

    XCTAssertFalse(store.persistenceAvailable)
    XCTAssertFalse(store.deletionFailed)
    XCTAssertTrue(store.events.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    let reloaded = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    XCTAssertFalse(reloaded.recordingEnabled)
    XCTAssertTrue(reloaded.events.isEmpty)
  }

  func testUnavailableStorageDoesNotLoseInMemoryReport() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let blockedDirectory = fixture.directory.appendingPathComponent("blocked")
    try Data().write(to: blockedDirectory)
    let store = AppDiagnosticsStore(
      fileURL: blockedDirectory.appendingPathComponent("events.json"),
      clock: { self.now }
    )
    store.recordingEnabled = true
    let original = event()
    store.record(original)
    XCTAssertFalse(store.persistenceAvailable)
    XCTAssertEqual(store.events, [original])
    XCTAssertNoThrow(try store.exportData())
  }

  func testStoreIsExcludedFromBackupAndProtectedOnDevice() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = AppDiagnosticsStore(fileURL: fixture.fileURL, clock: { self.now })
    store.recordingEnabled = true
    store.record(event())
    XCTAssertTrue(store.persistenceAvailable)
    #if os(iOS)
      XCTAssertEqual(
        try fixture.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
          .isExcludedFromBackup,
        true
      )
      XCTAssertEqual(
        try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
          .isExcludedFromBackup,
        true
      )
      let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
      XCTAssertEqual(
        attributes[.protectionKey] as? FileProtectionType,
        .completeUntilFirstUserAuthentication
      )
    #endif
  }

  private func event(timestamp: Date? = nil, duration: Int = 150) -> AppDiagnosticEvent {
    AppDiagnosticEvent(
      timestamp: timestamp ?? now,
      operation: .candidateSearch,
      outcome: .failure,
      category: .networkTimeout,
      durationMilliseconds: duration
    )
  }

  private func eventFields(_ event: AppDiagnosticEvent) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]
    )
  }

  private func exportFields(_ store: AppDiagnosticsStore) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
  }
}

@MainActor
private final class MutableClock {
  var now: Date

  init(_ now: Date) {
    self.now = now
  }
}

private struct Fixture {
  let directory: URL
  let fileURL: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    fileURL = directory.appendingPathComponent("events.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
