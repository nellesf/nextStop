import Foundation

enum UserErrorReportError: Error, Equatable {
  case invalidRequest
  case invalidConfiguration
  case authenticationUnavailable
  case unavailable
  case invalidResponse
  case storageUnavailable
  case capacityReached
  case rateLimited
  case withdrawn
}

/// Only an explicit submission constructs this value. It is never persisted.
struct UserErrorReportRequest: Encodable, Equatable, Sendable {
  static let maximumMessageLength = 5_000
  static let consentVersion = "2026-09-13"
  static let maximumDiagnostics = 200

  let reportID: UUID
  let deletionToken: UUID
  let message: String
  let includeDiagnostics: Bool
  let diagnostics: [AppDiagnosticEvent]?

  init(
    message: String,
    includeDiagnostics: Bool,
    diagnostics: [AppDiagnosticEvent] = [],
    reportID: UUID = UUID(),
    deletionToken: UUID = UUID()
  ) throws {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...Self.maximumMessageLength).contains(trimmed.unicodeScalars.count),
      !trimmed.contains("\u{0}"),
      !includeDiagnostics
        || ((1...Self.maximumDiagnostics).contains(diagnostics.count)
          && Set(diagnostics.map(\.id)).count == diagnostics.count)
    else { throw UserErrorReportError.invalidRequest }
    self.reportID = reportID
    self.deletionToken = deletionToken
    self.message = trimmed
    self.includeDiagnostics = includeDiagnostics
    // The checkbox is authoritative even if the caller supplies events.
    self.diagnostics = includeDiagnostics ? diagnostics : nil
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(1, forKey: .schemaVersion)
    try values.encode(reportID.uuidString.lowercased(), forKey: .reportId)
    try values.encode(deletionToken.uuidString.lowercased(), forKey: .deletionToken)
    try values.encode(Self.consentVersion, forKey: .consentVersion)
    try values.encode(message, forKey: .message)
    try values.encode(includeDiagnostics, forKey: .includeDiagnostics)
    try values.encodeIfPresent(diagnostics, forKey: .diagnostics)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, reportId, deletionToken, consentVersion, message
    case includeDiagnostics, diagnostics
  }
}

@MainActor
protocol UserErrorReportSending: AnyObject {
  func send(_ request: UserErrorReportRequest) async throws -> UserErrorReportReceipt
  func delete(_ receipt: UserErrorReportReceipt) async throws
}

@MainActor
final class HTTPUserErrorReportService: UserErrorReportSending {
  typealias Load = @MainActor (URLRequest) async throws -> (Data, URLResponse)
  typealias Now = @MainActor () -> Date

  private static let maximumResponseBytes = 16 * 1_024
  private let baseURL: URL?
  private let accessTokenProvider: (any SearchAccessTokenProviding)?
  private let receiptStore: UserErrorReportReceiptStore
  private let load: Load
  private let now: Now

  init(
    baseURL: URL?,
    accessTokenProvider: (any SearchAccessTokenProviding)?,
    receiptStore: UserErrorReportReceiptStore,
    load: Load? = nil,
    now: @escaping Now = Date.init
  ) {
    self.baseURL = baseURL
    self.accessTokenProvider = accessTokenProvider
    self.receiptStore = receiptStore
    self.now = now
    if let load {
      self.load = load
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 20
      configuration.timeoutIntervalForResource = 30
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      let session = URLSession(
        configuration: configuration, delegate: UserErrorReportRedirectBlocker(), delegateQueue: nil
      )
      self.load = { request in try await session.data(for: request) }
    }
  }

  func send(_ request: UserErrorReportRequest) async throws -> UserErrorReportReceipt {
    try Task.checkCancellation()
    var urlRequest = try makeRequest(method: "POST", body: request)
    let token = try await accessToken(forceRefresh: false)
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    try Task.checkCancellation()
    // Commit the deletion capability before any request can reach the server.
    // A timeout, cancellation, or invalid response then remains withdrawable.
    let pending = try receiptStore.reserve(request)
    var mayRefreshToken = true
    while true {
      let (data, response) = try await perform(urlRequest)
      if response.statusCode == 401 {
        guard mayRefreshToken else { throw UserErrorReportError.authenticationUnavailable }
        mayRefreshToken = false
        let token = try await accessToken(forceRefresh: true)
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        continue
      }
      guard [200, 201].contains(response.statusCode) else {
        throw Self.responseError(status: response.statusCode)
      }
      let receipt = try validatedReceipt(data: data, pending: pending)
      try receiptStore.confirm(receipt)
      return receipt
    }
  }

  func delete(_ receipt: UserErrorReportReceipt) async throws {
    try Task.checkCancellation()
    // The random deletion token proves possession; no device identity or renewed
    // App Attest access is needed to withdraw an already submitted report.
    let request = try makeRequest(
      method: "DELETE",
      body: DeleteRequest(
        reportId: receipt.reportID.uuidString.lowercased(),
        deletionToken: receipt.deletionToken.uuidString.lowercased()
      )
    )
    let (_, response) = try await perform(request)
    guard response.statusCode == 204 else {
      throw Self.responseError(status: response.statusCode)
    }
    try receiptStore.remove(reportID: receipt.reportID)
  }

  private func makeRequest<Body: Encodable>(method: String, body: Body) throws -> URLRequest {
    guard let baseURL,
      baseURL.scheme?.lowercased() == "https",
      let host = baseURL.host, !host.isEmpty,
      baseURL.user == nil, baseURL.password == nil,
      baseURL.query == nil, baseURL.fragment == nil
    else { throw UserErrorReportError.invalidConfiguration }
    var request = URLRequest(url: baseURL.appending(path: "v1/error-reports"))
    request.httpMethod = method
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // An explicit later retry re-encodes the same approved request. Stable key
    // ordering keeps its bytes identical across separate encoder instances.
    encoder.outputFormatting = [.sortedKeys]
    do {
      request.httpBody = try encoder.encode(body)
    } catch {
      throw UserErrorReportError.invalidRequest
    }
    return request
  }

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await load(request)
      try Task.checkCancellation()
    } catch {
      if Self.isCancellation(error) { throw CancellationError() }
      throw UserErrorReportError.unavailable
    }
    guard let http = response as? HTTPURLResponse,
      http.url == request.url,
      data.count <= Self.maximumResponseBytes
    else { throw UserErrorReportError.invalidResponse }
    return (data, http)
  }

  private func accessToken(forceRefresh: Bool) async throws -> String {
    try Task.checkCancellation()
    guard let accessTokenProvider else { throw UserErrorReportError.invalidConfiguration }
    do {
      let token = try await accessTokenProvider.accessToken(forceRefresh: forceRefresh)
      try Task.checkCancellation()
      guard (32...2_048).contains(token.utf8.count),
        token.utf8.allSatisfy({ (33...126).contains($0) })
      else { throw UserErrorReportError.authenticationUnavailable }
      return token
    } catch {
      if Self.isCancellation(error) { throw CancellationError() }
      throw UserErrorReportError.authenticationUnavailable
    }
  }

  private func validatedReceipt(
    data: Data, pending: UserErrorReportReceipt
  ) throws -> UserErrorReportReceipt {
    let dto: ReceiptResponse
    do {
      dto = try JSONDecoder().decode(ReceiptResponse.self, from: data)
    } catch {
      throw UserErrorReportError.invalidResponse
    }
    let currentTime = now()
    let skew = UserErrorReportReceiptStore.clockSkewAllowance
    guard UUID(uuidString: dto.reportId) == pending.reportID,
      let receivedAt = Self.parseDate(dto.receivedAt),
      let expiresAt = Self.parseDate(dto.expiresAt),
      receivedAt >= pending.createdAt.addingTimeInterval(-skew),
      receivedAt <= currentTime.addingTimeInterval(skew),
      expiresAt > receivedAt,
      expiresAt > currentTime.addingTimeInterval(-skew),
      expiresAt.timeIntervalSince(receivedAt) <= UserErrorReportReceiptStore.retentionInterval + 1
    else { throw UserErrorReportError.invalidResponse }
    return UserErrorReportReceipt(
      reportID: pending.reportID,
      deletionToken: pending.deletionToken,
      createdAt: pending.createdAt,
      receivedAt: receivedAt,
      expiresAt: expiresAt
    )
  }

  private static func parseDate(_ value: String) -> Date? {
    guard value.utf8.count <= 40 else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func responseError(status: Int) -> UserErrorReportError {
    switch status {
    case 400, 413, 422: .invalidRequest
    case 401, 403: .authenticationUnavailable
    case 410: .withdrawn
    case 429: .rateLimited
    case 500...599: .unavailable
    default: .invalidResponse
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
  }

  private struct DeleteRequest: Encodable {
    let reportId: String
    let deletionToken: String
  }

  private struct ReceiptResponse: Decodable {
    let reportId: String
    let receivedAt: String
    let expiresAt: String
  }
}

/// Refuse redirects so a report, authorization header, or deletion capability
/// cannot be forwarded to another origin by a server response.
private final class UserErrorReportRedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
