import Foundation
import XCTest

@testable import NextStopApp

@MainActor
final class UserErrorReportReceiptStoreTests: XCTestCase {
  func testStorePersistsOnlyRandomCapabilityAndRetentionDates() throws {
    let fixture = try ReceiptStoreFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let request = try fixture.request()
    let receipt = try store.reserve(request)
    let data = try Data(contentsOf: fixture.fileURL)
    let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(snapshot.keys), ["schemaVersion", "receipts"])
    let receipts = try XCTUnwrap(snapshot["receipts"] as? [[String: Any]])
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(Set(receipts[0].keys), ["reportID", "deletionToken", "createdAt", "expiresAt"])
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(request.message))
    XCTAssertEqual(fixture.store().receipts, [receipt])
    XCTAssertEqual(try store.reserve(request), receipt)
    XCTAssertEqual(store.receipts.count, 1)
  }

  func testDuplicateReportIDCannotReplaceTheOriginalDeletionSecret() throws {
    let fixture = try ReceiptStoreFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let original = try fixture.request()
    let receipt = try store.reserve(original)
    let duplicate = try UserErrorReportRequest(
      message: "A different request", includeDiagnostics: false, reportID: original.reportID
    )
    XCTAssertThrowsError(try store.reserve(duplicate)) {
      XCTAssertEqual($0 as? UserErrorReportError, .invalidRequest)
    }
    XCTAssertEqual(store.receipts, [receipt])
  }

  func testCapacityNeverEvictsAnUnexpiredDeletionCapability() throws {
    let fixture = try ReceiptStoreFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    for _ in 0..<UserErrorReportReceiptStore.receiptLimit { try store.reserve(fixture.request()) }
    let original = store.receipts
    XCTAssertThrowsError(try store.reserve(fixture.request())) {
      XCTAssertEqual($0 as? UserErrorReportError, .capacityReached)
    }
    XCTAssertEqual(store.receipts, original)
    XCTAssertEqual(fixture.store().receipts, original)
  }

  func testExpiredReceiptsArePrunedOnLoadAndExplicitPrune() throws {
    let fixture = try ReceiptStoreFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    try store.reserve(fixture.request())
    fixture.now = fixture.now.addingTimeInterval(
      UserErrorReportReceiptStore.retentionInterval + UserErrorReportReceiptStore.clockSkewAllowance
        + 1
    )
    try store.prune()
    XCTAssertTrue(store.receipts.isEmpty)
    XCTAssertTrue(fixture.store().receipts.isEmpty)
  }

  func testCorruptOversizedOrUnsupportedSnapshotIsPreservedAndBlocksSending() throws {
    for data in [
      Data("invalid-json".utf8),
      Data(repeating: 1, count: UserErrorReportReceiptStore.maximumFileSize + 1),
      Data(#"{"schemaVersion":99,"receipts":[]}"#.utf8),
    ] {
      let fixture = try ReceiptStoreFixture()
      defer { fixture.remove() }
      try data.write(to: fixture.fileURL)
      let store = fixture.store()
      XCTAssertFalse(store.persistenceAvailable)
      XCTAssertThrowsError(try store.reserve(fixture.request())) {
        XCTAssertEqual($0 as? UserErrorReportError, .storageUnavailable)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.fileURL), data)
    }
  }

  func testFailedReceiptRemovalRetainsItsCapabilityAndIsVisibleToTheUI() throws {
    let fixture = try ReceiptStoreFixture()
    defer { fixture.remove() }
    var mayWrite = true
    let store = UserErrorReportReceiptStore(
      fileURL: fixture.fileURL, clock: { fixture.now },
      write: { data, url in
        guard mayWrite else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
      }
    )
    let receipt = try store.reserve(fixture.request())
    mayWrite = false
    XCTAssertThrowsError(try store.remove(reportID: receipt.reportID)) {
      XCTAssertEqual($0 as? UserErrorReportError, .storageUnavailable)
    }
    XCTAssertFalse(store.persistenceAvailable)
    XCTAssertEqual(store.receipts, [receipt])
    XCTAssertEqual(fixture.store().receipts, [receipt])
    mayWrite = true
    try store.remove(reportID: receipt.reportID)
    XCTAssertTrue(store.persistenceAvailable)
    XCTAssertTrue(store.receipts.isEmpty)
  }

  func testReceiptFileAndDirectoryAreExcludedFromBackup() throws {
    let fixture = try ReceiptStoreFixture()
    defer { fixture.remove() }
    try fixture.store().reserve(fixture.request())
    #if os(iOS)
      for url in [fixture.fileURL, fixture.directory] {
        XCTAssertEqual(
          try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true
        )
      }
    #endif
  }
}

@MainActor
private final class ReceiptStoreFixture {
  let directory: URL
  let fileURL: URL
  var now = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("UserErrorReportReceiptTests-\(UUID().uuidString)", isDirectory: true)
    fileURL = directory.appendingPathComponent("receipts.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func store() -> UserErrorReportReceiptStore {
    UserErrorReportReceiptStore(fileURL: fileURL, clock: { self.now })
  }

  func request() throws -> UserErrorReportRequest {
    try UserErrorReportRequest(message: "Private report text", includeDiagnostics: false)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
