import Combine
import Foundation

@MainActor
final class UserErrorReportComposer: ObservableObject {
  @Published var message = "" {
    didSet { if message != oldValue { pendingRequest = nil } }
  }
  @Published var includeDiagnostics = false {
    didSet { if includeDiagnostics != oldValue { pendingRequest = nil } }
  }
  @Published private(set) var diagnostics: [AppDiagnosticEvent] = []
  @Published private(set) var isSending = false
  @Published private(set) var sentReportID: UUID?
  @Published private(set) var error: UserErrorReportError?

  private let sender: any UserErrorReportSending
  private let privacyConfigured: Bool
  private var pendingRequest: UserErrorReportRequest?

  init(sender: any UserErrorReportSending, privacyConfigured: Bool) {
    self.sender = sender
    self.privacyConfigured = privacyConfigured
  }

  var messageLength: Int { message.unicodeScalars.count }

  var canSend: Bool {
    privacyConfigured && !isSending
      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && messageLength <= UserErrorReportRequest.maximumMessageLength
      && (!includeDiagnostics || !diagnostics.isEmpty)
  }

  func refreshDiagnostics(from store: AppDiagnosticsStore) {
    guard !isSending else { return }
    store.prune()
    if diagnostics != store.events {
      diagnostics = store.events
      pendingRequest = nil
    }
    if diagnostics.isEmpty { includeDiagnostics = false }
  }

  func send() async {
    guard canSend else { return }
    isSending = true
    error = nil
    sentReportID = nil
    defer { isSending = false }
    do {
      let request: UserErrorReportRequest
      if let pendingRequest {
        request = pendingRequest
      } else {
        request = try UserErrorReportRequest(
          message: message,
          includeDiagnostics: includeDiagnostics,
          diagnostics: includeDiagnostics ? diagnostics : []
        )
        pendingRequest = request
      }
      let receipt = try await sender.send(request)
      sentReportID = receipt.reportID
      message = ""
      includeDiagnostics = false
      pendingRequest = nil
    } catch is CancellationError {
      // Delivery can be uncertain; the service preserves the deletion receipt.
    } catch let failure as UserErrorReportError {
      error = failure
      if failure == .withdrawn { pendingRequest = nil }
    } catch {
      self.error = .unavailable
    }
  }
}

extension UserErrorReportError {
  var localizationKey: String {
    switch self {
    case .invalidRequest: "report.error.invalid_request"
    case .invalidConfiguration: "report.error.configuration"
    case .authenticationUnavailable: "report.error.authentication"
    case .unavailable: "report.error.unavailable"
    case .invalidResponse: "report.error.invalid_response"
    case .storageUnavailable: "report.error.storage"
    case .capacityReached: "report.error.capacity"
    case .rateLimited: "report.error.rate_limit"
    case .withdrawn: "report.error.withdrawn"
    }
  }
}
