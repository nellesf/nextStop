import Foundation
import XCTest

@testable import NextStopApp

@MainActor
final class UserErrorReportServiceTests: XCTestCase {
  func testOptOutOmitsAllDiagnosticsAndOnlySendsTheContractFields() async throws {
    let fixture = try ReportTransportFixture()
    defer { fixture.remove() }
    let request = try UserErrorReportRequest(
      message: " \nDie Suche ist fehlgeschlagen.\n ", includeDiagnostics: false,
      diagnostics: [fixture.event()]
    )
    let receipt = try await fixture.service().send(request)
    let sent = try XCTUnwrap(fixture.requests.first)
    let body = try fixture.fields(sent)

    XCTAssertEqual(
      Set(body.keys),
      [
        "schemaVersion", "reportId", "deletionToken", "consentVersion", "message",
        "includeDiagnostics",
      ])
    XCTAssertEqual(body["message"] as? String, "Die Suche ist fehlgeschlagen.")
    XCTAssertEqual(body["includeDiagnostics"] as? Bool, false)
    XCTAssertEqual(body["consentVersion"] as? String, "2026-09-13")
    XCTAssertNil(body["diagnostics"])
    XCTAssertEqual(sent.url?.absoluteString, "https://api.nextstop.test/v1/error-reports")
    XCTAssertEqual(sent.httpMethod, "POST")
    XCTAssertEqual(sent.timeoutInterval, 20)
    XCTAssertFalse(sent.httpShouldHandleCookies)
    XCTAssertEqual(receipt.reportID, request.reportID)
    XCTAssertFalse(receipt.isPending)
    XCTAssertEqual(fixture.store.receipts, [receipt])
  }

  func testSelectedLogsUseTheExistingAllowlistAndISODateFormat() async throws {
    let fixture = try ReportTransportFixture()
    defer { fixture.remove() }
    let event = fixture.event()
    _ = try await fixture.service().send(
      UserErrorReportRequest(message: "Fehler", includeDiagnostics: true, diagnostics: [event])
    )
    let request = try XCTUnwrap(fixture.requests.first)
    let body = try fixture.fields(request)
    let diagnostics = try XCTUnwrap(body["diagnostics"] as? [[String: Any]])
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(
      Set(diagnostics[0].keys),
      [
        "id", "timestamp", "operation", "outcome", "category", "durationMilliseconds", "attempt",
      ])
    XCTAssertEqual(diagnostics[0]["timestamp"] as? String, "2027-01-15T08:00:00Z")
    let stored = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    XCTAssertFalse(stored.contains("Fehler"))
    XCTAssertFalse(stored.contains(event.id.uuidString))
    XCTAssertFalse(stored.contains("networkTimeout"))
    XCTAssertFalse(stored.contains("Authorization"))
  }

  func testRequestValidatesScalarCountAndRequiresLogsWhenSelected() throws {
    XCTAssertThrowsError(try UserErrorReportRequest(message: " \n\t", includeDiagnostics: false))
    XCTAssertThrowsError(
      try UserErrorReportRequest(message: "Fehler\u{0}", includeDiagnostics: false))
    XCTAssertThrowsError(
      try UserErrorReportRequest(
        message: String(repeating: "a", count: 5_001), includeDiagnostics: false
      ))
    // A composed character can contain multiple Unicode scalars.
    XCTAssertThrowsError(
      try UserErrorReportRequest(
        message: String(repeating: "e\u{301}", count: 2_501), includeDiagnostics: false
      ))
    XCTAssertNoThrow(
      try UserErrorReportRequest(
        message: String(repeating: "🚙", count: 5_000), includeDiagnostics: false
      ))
    XCTAssertThrowsError(try UserErrorReportRequest(message: "Fehler", includeDiagnostics: true))
    let fixture = try ReportTransportFixture()
    defer { fixture.remove() }
    let repeatedEvent = fixture.event()
    XCTAssertThrowsError(
      try UserErrorReportRequest(
        message: "Fehler", includeDiagnostics: true, diagnostics: [repeatedEvent, repeatedEvent]
      ))
    XCTAssertThrowsError(
      try UserErrorReportRequest(
        message: "Fehler", includeDiagnostics: true,
        diagnostics: Array(repeating: fixture.event(), count: 201)
      ))
  }

  func test401RefreshesOnceWithoutChangingTheExplicitlyApprovedBody() async throws {
    let fixture = try ReportTransportFixture(replies: [.http(401), .accepted])
    defer { fixture.remove() }
    _ = try await fixture.service().send(fixture.request())
    XCTAssertEqual(fixture.requests.count, 2)
    XCTAssertEqual(fixture.requests[0].httpBody, fixture.requests[1].httpBody)
    XCTAssertNotEqual(
      fixture.requests[0].value(forHTTPHeaderField: "Authorization"),
      fixture.requests[1].value(forHTTPHeaderField: "Authorization")
    )
    let refreshes = await fixture.tokens.refreshes
    XCTAssertEqual(refreshes, [false, true])

    let rejected = try ReportTransportFixture(replies: [.http(401), .http(401), .accepted])
    defer { rejected.remove() }
    await assertError(.authenticationUnavailable) {
      _ = try await rejected.service().send(rejected.request())
    }
    XCTAssertEqual(rejected.requests.count, 2)
    XCTAssertTrue(try XCTUnwrap(rejected.store.receipts.first).isPending)
  }

  func testTransientAndSemanticFailuresNeverAutomaticallyResubmit() async throws {
    let cases: [(ReportTransportReply, UserErrorReportError)] = [
      (.failure(URLError(.timedOut)), .unavailable),
      (.failure(URLError(.networkConnectionLost)), .unavailable),
      (.http(503), .unavailable), (.http(429), .rateLimited),
      (.http(410), .withdrawn), (.http(400), .invalidRequest),
    ]
    for (reply, expected) in cases {
      let fixture = try ReportTransportFixture(replies: [reply, .accepted])
      defer { fixture.remove() }
      await assertError(expected) { _ = try await fixture.service().send(fixture.request()) }
      XCTAssertEqual(fixture.requests.count, 1)
      XCTAssertTrue(try XCTUnwrap(fixture.store.receipts.first).isPending)
    }
  }

  func testCancelledUploadPreservesDurableDeletionCapability() async throws {
    for error: any Error in [CancellationError(), URLError(.cancelled)] {
      let fixture = try ReportTransportFixture(replies: [.failure(error)])
      defer { fixture.remove() }
      let request = try fixture.request()
      do {
        _ = try await fixture.service().send(request)
        XCTFail("Cancellation must propagate without retry")
      } catch is CancellationError {
        XCTAssertEqual(fixture.requests.count, 1)
      }
      let reloaded = UserErrorReportReceiptStore(fileURL: fixture.fileURL, clock: { fixture.now })
      let receipt = try XCTUnwrap(reloaded.receipts.first)
      XCTAssertEqual(receipt.reportID, request.reportID)
      XCTAssertEqual(receipt.deletionToken, request.deletionToken)
      XCTAssertTrue(receipt.isPending)
    }
  }

  func testTokenCancellationPreventsSubmissionAndReceiptCreation() async throws {
    let fixture = try ReportTransportFixture()
    defer { fixture.remove() }
    let service = HTTPUserErrorReportService(
      baseURL: URL(string: "https://api.nextstop.test"),
      accessTokenProvider: CancelledReportTokenProvider(), receiptStore: fixture.store,
      load: { request in
        XCTFail("No upload is authorized after cancellation")
        throw URLError(.badServerResponse)
      }
    )
    do {
      _ = try await service.send(fixture.request())
      XCTFail("Authentication cancellation must propagate")
    } catch is CancellationError {
      XCTAssertTrue(fixture.store.receipts.isEmpty)
    }
  }

  func testStorageFailurePreventsAnUploadWhoseReceiptCouldBeLost() async throws {
    let fixture = try ReportTransportFixture()
    defer { fixture.remove() }
    let store = UserErrorReportReceiptStore(
      fileURL: fixture.fileURL, clock: { fixture.now },
      write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
    )
    await assertError(.storageUnavailable) {
      _ = try await fixture.service(store: store).send(fixture.request())
    }
    XCTAssertTrue(fixture.requests.isEmpty)
    XCTAssertTrue(store.receipts.isEmpty)
    XCTAssertFalse(store.persistenceAvailable)
  }

  func testConfirmationPersistenceFailureLeavesThePendingCapabilityIntact() async throws {
    let fixture = try ReportTransportFixture()
    defer { fixture.remove() }
    var writes = 0
    let store = UserErrorReportReceiptStore(
      fileURL: fixture.fileURL, clock: { fixture.now },
      write: { data, url in
        writes += 1
        if writes > 1 { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
      }
    )
    await assertError(.storageUnavailable) {
      _ = try await fixture.service(store: store).send(fixture.request())
    }
    XCTAssertEqual(fixture.requests.count, 1)
    XCTAssertTrue(try XCTUnwrap(store.receipts.first).isPending)
    let reloaded = UserErrorReportReceiptStore(fileURL: fixture.fileURL, clock: { fixture.now })
    XCTAssertEqual(reloaded.receipts, store.receipts)
  }

  func testDelayedExplicitRetryCanConfirmAndReloadTheOriginalDeletionCapability() async throws {
    let fixture = try ReportTransportFixture(replies: [.failure(URLError(.timedOut)), .accepted])
    defer { fixture.remove() }
    let request = try fixture.request()
    await assertError(.unavailable) { _ = try await fixture.service().send(request) }
    let original = try XCTUnwrap(fixture.store.receipts.first)
    fixture.now = fixture.now.addingTimeInterval(86_400)
    let confirmed = try await fixture.service().send(request)

    XCTAssertEqual(confirmed.createdAt, original.createdAt)
    XCTAssertEqual(confirmed.receivedAt, fixture.now)
    XCTAssertEqual(fixture.requests[0].httpBody, fixture.requests[1].httpBody)
    let reloaded = UserErrorReportReceiptStore(fileURL: fixture.fileURL, clock: { fixture.now })
    XCTAssertTrue(reloaded.persistenceAvailable)
    XCTAssertEqual(reloaded.receipts, [confirmed])
  }

  func testInvalidReceiptResponseCannotConfirmOrDiscardTheDeletionCapability() async throws {
    let invalidBodies = [
      "{}", "invalid-json", String(repeating: "x", count: 16 * 1_024 + 1),
      #"{"reportId":"WRONG","receivedAt":"2027-01-15T08:00:00Z","expiresAt":"2027-02-14T08:00:00Z"}"#,
    ]
    for body in invalidBodies {
      let fixture = try ReportTransportFixture(replies: [.http(201, body: body)])
      defer { fixture.remove() }
      await assertError(.invalidResponse) {
        _ = try await fixture.service().send(fixture.request())
      }
      XCTAssertTrue(try XCTUnwrap(fixture.store.receipts.first).isPending)
    }
    for (receivedOffset, expirationOffset) in [
      (301.0, 30.0 * 86_400), (-301.0, 30.0 * 86_400),
      (0.0, 31.0 * 86_400), (0.0, 0.0),
    ] {
      let fixture = try ReportTransportFixture(
        replies: [.receipt(receivedOffset: receivedOffset, expirationOffset: expirationOffset)]
      )
      defer { fixture.remove() }
      await assertError(.invalidResponse) {
        _ = try await fixture.service().send(fixture.request())
      }
      XCTAssertTrue(try XCTUnwrap(fixture.store.receipts.first).isPending)
    }
  }

  func testPlainHTTPAndURLCredentialsCannotTransmitReports() async throws {
    for url in [
      "http://api.nextstop.test", "https://user:password@api.nextstop.test",
      "https://api.nextstop.test?secret=value", "https://api.nextstop.test#fragment",
    ] {
      let fixture = try ReportTransportFixture()
      defer { fixture.remove() }
      await assertError(.invalidConfiguration) {
        _ = try await fixture.service(baseURL: URL(string: url)).send(fixture.request())
      }
      XCTAssertTrue(fixture.requests.isEmpty)
      XCTAssertTrue(fixture.store.receipts.isEmpty)
    }
  }

  func testDeleteUsesOnlyRandomCapabilityWithoutAuthenticationAndRemovesReceiptAfter204()
    async throws
  {
    let fixture = try ReportTransportFixture(replies: [.http(204)])
    defer { fixture.remove() }
    let pending = try fixture.store.reserve(fixture.request())
    let service = fixture.service(authenticated: false)
    try await service.delete(pending)
    let request = try XCTUnwrap(fixture.requests.first)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(Set(try fixture.fields(request).keys), ["reportId", "deletionToken"])
    XCTAssertTrue(fixture.store.receipts.isEmpty)
    let refreshes = await fixture.tokens.refreshes
    XCTAssertEqual(refreshes, [])
    XCTAssertTrue(
      UserErrorReportReceiptStore(fileURL: fixture.fileURL, clock: { fixture.now }).receipts.isEmpty
    )
  }

  func testFailedDeletionRetainsTheCapabilityForAnExplicitRetry() async throws {
    let fixture = try ReportTransportFixture(replies: [.failure(URLError(.timedOut)), .http(204)])
    defer { fixture.remove() }
    let pending = try fixture.store.reserve(fixture.request())
    await assertError(.unavailable) { try await fixture.service().delete(pending) }
    XCTAssertEqual(fixture.requests.count, 1)
    XCTAssertEqual(fixture.store.receipts, [pending])
    try await fixture.service().delete(pending)
    XCTAssertEqual(fixture.requests.count, 2)
    XCTAssertTrue(fixture.store.receipts.isEmpty)
  }

  private func assertError(
    _ expected: UserErrorReportError,
    operation: () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? UserErrorReportError, expected, file: file, line: line)
    }
  }
}

@MainActor
private final class ReportTransportFixture {
  let directory: URL
  let fileURL: URL
  let tokens = ReportAccessTokenProvider()
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  let store: UserErrorReportReceiptStore
  var requests: [URLRequest] = []
  var replies: [ReportTransportReply]

  init(replies: [ReportTransportReply] = [.accepted]) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "UserErrorReportTransportTests-\(UUID().uuidString)", isDirectory: true)
    fileURL = directory.appendingPathComponent("receipts.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixedNow = now
    store = UserErrorReportReceiptStore(fileURL: fileURL, clock: { fixedNow })
    self.replies = replies
  }

  func service(
    baseURL: URL? = URL(string: "https://api.nextstop.test"),
    store: UserErrorReportReceiptStore? = nil,
    authenticated: Bool = true
  ) -> HTTPUserErrorReportService {
    HTTPUserErrorReportService(
      baseURL: baseURL, accessTokenProvider: authenticated ? self.tokens : nil,
      receiptStore: store ?? self.store,
      load: { request in
        self.requests.append(request)
        guard !self.replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = self.replies.removeFirst()
        let status: Int
        let data: Data
        switch reply {
        case .failure(let error): throw error
        case .http(let value, let body):
          status = value
          data = Data(body.utf8)
        case .accepted:
          status = 201
          data = try self.receiptBody(request, receivedOffset: 0, expirationOffset: 30 * 86_400)
        case .receipt(let receivedOffset, let expirationOffset):
          status = 200
          data = try self.receiptBody(
            request, receivedOffset: receivedOffset, expirationOffset: expirationOffset
          )
        }
        return (
          data,
          HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
      },
      now: { self.now }
    )
  }

  func request() throws -> UserErrorReportRequest {
    try UserErrorReportRequest(message: "Die Suche ist fehlgeschlagen.", includeDiagnostics: false)
  }

  func event() -> AppDiagnosticEvent {
    AppDiagnosticEvent(
      timestamp: now, operation: .candidateSearch, outcome: .failure, category: .networkTimeout,
      durationMilliseconds: 200
    )
  }

  func fields(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
  }

  func receiptBody(
    _ request: URLRequest, receivedOffset: TimeInterval, expirationOffset: TimeInterval
  ) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try JSONSerialization.data(withJSONObject: [
      "reportId": try XCTUnwrap(fields(request)["reportId"] as? String),
      "receivedAt": formatter.string(from: now.addingTimeInterval(receivedOffset)),
      "expiresAt": formatter.string(from: now.addingTimeInterval(expirationOffset)),
    ])
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private enum ReportTransportReply {
  case accepted
  case http(Int, body: String = "{}")
  case receipt(receivedOffset: TimeInterval, expirationOffset: TimeInterval)
  case failure(any Error)
}

private actor ReportAccessTokenProvider: SearchAccessTokenProviding {
  private(set) var refreshes: [Bool] = []
  func accessToken(forceRefresh: Bool) async throws -> String {
    refreshes.append(forceRefresh)
    return String(repeating: forceRefresh ? "b" : "a", count: 32)
  }
}

private struct CancelledReportTokenProvider: SearchAccessTokenProviding {
  func accessToken(forceRefresh: Bool) async throws -> String { throw CancellationError() }
}
