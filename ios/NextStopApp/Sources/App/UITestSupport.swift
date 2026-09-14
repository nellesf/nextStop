#if DEBUG && targetEnvironment(simulator)
  import Foundation
  import NextStopCore
  import SwiftData
  import SwiftUI

  /// Opt-in test composition for the real app screens. Compiled out of device
  /// and Release builds; no user data, networking, or authentication is reused.
  @MainActor
  final class UITestSupport {
    enum Scenario: String {
      case empty
      case logsSuccess = "logs-success"
      case logsRetry = "logs-retry"
    }

    enum Appearance: String {
      case light, dark

      var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
      }
    }

    let modelContainer: ModelContainer
    let preferredColorScheme: ColorScheme?
    let diagnostics: AppDiagnosticsStore
    let receipts: UserErrorReportReceiptStore
    let reportSender: any UserErrorReportSending
    let candidateSearcher: any CandidatePageSearching

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
      arguments.contains("--ui-testing")
    }

    static func requested(
      arguments: [String] = ProcessInfo.processInfo.arguments,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> UITestSupport? {
      guard isRequested(arguments: arguments) else { return nil }
      guard let name = environment["NEXTSTOP_UI_TEST_SCENARIO"],
        let scenario = Scenario(rawValue: name)
      else { throw ConfigurationError.unknownScenario }
      let appearance: Appearance?
      if let value = environment["NEXTSTOP_UI_TEST_APPEARANCE"] {
        guard let parsed = Appearance(rawValue: value) else {
          throw ConfigurationError.unknownAppearance
        }
        appearance = parsed
      } else {
        appearance = nil
      }
      return try UITestSupport(scenario: scenario, appearance: appearance)
    }

    init(scenario: Scenario, appearance: Appearance? = nil) throws {
      preferredColorScheme = appearance?.colorScheme
      let schema = Schema([StoredProfile.self, StoredDestinationRecord.self])
      modelContainer = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
      )
      // A new directory per launch also isolates repeated and parallel UI tests.
      // Never delete or open the app's normal Application Support directories.
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NextStopUITests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      let diagnostics = AppDiagnosticsStore(
        fileURL: directory.appendingPathComponent("events.json"), clock: { now }
      )
      if scenario != .empty {
        // Seed through the real store's default recording behavior. A default-off
        // regression must not be hidden by overriding the setting in test fixtures.
        diagnostics.record(
          AppDiagnosticEvent(
            timestamp: now.addingTimeInterval(-60), operation: .candidateSearch,
            outcome: .failure, category: .offline, durationMilliseconds: 250,
            errorDomain: .url, errorCode: -1009
          )
        )
      }
      self.diagnostics = diagnostics
      let receipts = UserErrorReportReceiptStore(
        fileURL: directory.appendingPathComponent("receipts.json"), clock: { now }
      )
      self.receipts = receipts
      reportSender = UITestReportSender(
        receipts: receipts, failsFirstSend: scenario == .logsRetry,
        expectedDiagnostics: diagnostics.events, now: now
      )
      candidateSearcher = UITestCandidateSearcher()
    }

    enum ConfigurationError: Error {
      case unknownScenario
      case unknownAppearance
    }
  }

  @MainActor
  private final class UITestCandidateSearcher: CandidatePageSearching {
    func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
      // Support tests must never fall back to a live charging search.
      throw CandidateSearchServiceError.unavailable
    }
  }

  @MainActor
  private final class UITestReportSender: UserErrorReportSending {
    private let receipts: UserErrorReportReceiptStore
    private let failsFirstSend: Bool
    private let expectedDiagnostics: [AppDiagnosticEvent]
    private let now: Date
    private var failedRequest: UserErrorReportRequest?

    init(
      receipts: UserErrorReportReceiptStore, failsFirstSend: Bool,
      expectedDiagnostics: [AppDiagnosticEvent], now: Date
    ) {
      self.receipts = receipts
      self.failsFirstSend = failsFirstSend
      self.expectedDiagnostics = expectedDiagnostics
      self.now = now
    }

    func send(_ request: UserErrorReportRequest) async throws -> UserErrorReportReceipt {
      try Task.checkCancellation()
      guard request.diagnostics == (request.includeDiagnostics ? expectedDiagnostics : nil),
        !failsFirstSend || request.includeDiagnostics
      else { throw UserErrorReportError.invalidRequest }
      let pending = try receipts.reserve(request)
      if failsFirstSend, failedRequest == nil {
        failedRequest = request
        throw UserErrorReportError.unavailable
      }
      if let failedRequest {
        // A successful retry in this scenario also proves that the composer
        // reused the unchanged draft, including its deletion capability.
        guard request == failedRequest else { throw UserErrorReportError.invalidRequest }
      }
      let receipt = UserErrorReportReceipt(
        reportID: pending.reportID, deletionToken: pending.deletionToken,
        createdAt: pending.createdAt, receivedAt: now,
        expiresAt: now.addingTimeInterval(UserErrorReportReceiptStore.retentionInterval)
      )
      try receipts.confirm(receipt)
      return receipt
    }

    func delete(_ receipt: UserErrorReportReceipt) async throws {
      try Task.checkCancellation()
      try receipts.remove(reportID: receipt.reportID)
    }
  }
#endif
