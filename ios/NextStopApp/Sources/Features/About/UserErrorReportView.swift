import SwiftUI

struct UserErrorReportView: View {
  @ObservedObject private var diagnosticsStore: AppDiagnosticsStore
  @StateObject private var composer: UserErrorReportComposer
  @State private var sendTask: Task<Void, Never>?
  @State private var distributionChecked = false
  private let sender: any UserErrorReportSending
  private let receiptStore: UserErrorReportReceiptStore
  private let privacy: SupportPrivacyConfiguration?

  init(
    diagnosticsStore: AppDiagnosticsStore,
    sender: any UserErrorReportSending,
    receiptStore: UserErrorReportReceiptStore,
    privacy: SupportPrivacyConfiguration?
  ) {
    self.diagnosticsStore = diagnosticsStore
    self.sender = sender
    self.receiptStore = receiptStore
    self.privacy = privacy
    _composer = StateObject(
      wrappedValue: UserErrorReportComposer(
        sender: sender,
        privacyConfigured: privacy?.allowsSubmission(in: .initial) == true
      ))
  }

  var body: some View {
    Form {
      if privacy?.usesInternalTestPlaceholders == true {
        SupportPrivacyTestNotice()
      }
      Section {
        TextField("report.message.prompt", text: $composer.message, axis: .vertical)
          .lineLimit(6...14)
          .accessibilityIdentifier("error-report-message")
        Text(verbatim: "\(composer.messageLength) / \(UserErrorReportRequest.maximumMessageLength)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(
            composer.messageLength > UserErrorReportRequest.maximumMessageLength
              ? Color.red : Color.secondary
          )
      } header: {
        Text("report.message.title")
      } footer: {
        Text("report.message.hint")
      }
      .disabled(composer.isSending)

      Section {
        if composer.diagnostics.isEmpty {
          Label {
            Text("report.logs.empty.title")
              .accessibilityIdentifier("error-report-no-logs")
          } icon: {
            Image(systemName: "doc.text.magnifyingglass")
              .accessibilityHidden(true)
          }
          Text("report.logs.empty")
            .foregroundStyle(.secondary)
          Text(
            diagnosticsStore.recordingEnabled
              ? "report.logs.awaiting_events" : "report.logs.recording_off"
          )
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(
            diagnosticsStore.recordingEnabled
              ? "error-report-recording-active" : "error-report-recording-off"
          )
          NavigationLink {
            DiagnosticsView(store: diagnosticsStore)
          } label: {
            Label("report.logs.settings", systemImage: "stethoscope")
          }
          .disabled(composer.isSending)
          .accessibilityIdentifier("error-report-recording-settings")
        } else {
          Toggle("report.logs.include", isOn: $composer.includeDiagnostics)
            .toggleStyle(ReportCheckboxToggleStyle())
            .disabled(composer.isSending)
            .accessibilityIdentifier("error-report-include-logs")
          NavigationLink {
            ReportLogPreview(
              events: composer.diagnostics, diagnosticContext: composer.diagnosticContext)
          } label: {
            LabeledContent("report.logs.preview") {
              Text(composer.diagnostics.count, format: .number)
            }
          }
          .disabled(composer.isSending)
          .accessibilityIdentifier("report-log-preview")
        }
      } footer: {
        Text(
          composer.diagnostics.isEmpty ? "report.logs.not_retroactive" : "report.logs.description")
      }

      Section {
        if let privacy {
          Text(
            verbatim: String(
              format: String(localized: "report.consent"), privacy.displayControllerName
            ))
        } else {
          Text("report.configuration_missing")
            .foregroundStyle(.secondary)
        }
        NavigationLink {
          SupportPrivacyView(configuration: privacy)
        } label: {
          Label("report.privacy.title", systemImage: "hand.raised")
        }
        .disabled(composer.isSending)
        .accessibilityIdentifier("report-privacy")

        if privacy?.usesInternalTestPlaceholders == true && !composer.privacyConfigured {
          Text(distributionChecked ? "report.internal.unavailable" : "report.internal.verifying")
            .foregroundStyle(.secondary)
        }

        Button {
          sendTask = Task { await composer.send() }
        } label: {
          HStack {
            Label("report.send", systemImage: "paperplane")
            if composer.isSending {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(!composer.canSend)
        .accessibilityIdentifier("error-report-send")

        if let error = composer.error {
          Text(LocalizedStringKey(error.localizationKey))
            .foregroundStyle(.red)
            .accessibilityIdentifier("report-send-error")
        }
        if composer.sentReportID != nil {
          Label {
            Text("report.sent")
              .accessibilityIdentifier("report-send-success")
          } icon: {
            Image(systemName: "checkmark.circle")
              .accessibilityHidden(true)
          }
          .foregroundStyle(.green)
        }
      }

      Section {
        NavigationLink {
          SentErrorReportsView(store: receiptStore, sender: sender)
        } label: {
          Label("report.receipts.title", systemImage: "tray")
        }
        .accessibilityIdentifier("report-receipts")
        NavigationLink {
          DiagnosticsView(store: diagnosticsStore)
        } label: {
          Label("report.local_diagnostics", systemImage: "stethoscope")
        }
        .accessibilityIdentifier("report-local-diagnostics")
      }
      .disabled(composer.isSending)
    }
    .navigationTitle("report.title")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
    .onAppear { composer.refreshDiagnostics(from: diagnosticsStore) }
    .onChange(of: diagnosticsStore.events) { composer.refreshDiagnostics(from: diagnosticsStore) }
    .task {
      guard privacy?.usesInternalTestPlaceholders == true else { return }
      let distribution = await SupportReportDistribution.current()
      guard !Task.isCancelled else { return }
      composer.configurePrivacy(privacy, in: distribution)
      distributionChecked = true
    }
    .onDisappear { sendTask?.cancel() }
    .interactiveDismissDisabled(composer.isSending)
  }
}

private struct ReportCheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
          .font(.title2)
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        configuration.label
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(
      Text(configuration.isOn ? "report.logs.selected" : "report.logs.unselected"))
  }
}

private struct ReportLogPreview: View {
  let events: [AppDiagnosticEvent]
  let diagnosticContext: UserErrorReportDiagnosticContext?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("report.logs.preview_description")
          .font(.subheadline)
        Text(verbatim: encodedEvents)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .accessibilityIdentifier("log-preview-content")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
    .navigationTitle("report.logs.preview")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var encodedEvents: String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let attachment = Attachment(diagnosticContext: diagnosticContext, diagnostics: events)
    guard let data = try? encoder.encode(attachment) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private struct Attachment: Encodable {
    let diagnosticContext: UserErrorReportDiagnosticContext?
    let diagnostics: [AppDiagnosticEvent]
  }
}

struct SentErrorReportsView: View {
  @ObservedObject var store: UserErrorReportReceiptStore
  let sender: any UserErrorReportSending
  @State private var deletingID: UUID?
  @State private var error: UserErrorReportError?
  @State private var deleteTask: Task<Void, Never>?

  var body: some View {
    List {
      Section {
        Text("report.receipts.description")
        if !store.persistenceAvailable {
          Text("report.error.storage")
            .foregroundStyle(.red)
        }
        if error != nil {
          Text("report.receipts.delete_failed")
            .foregroundStyle(.red)
        }
      }
      if store.receipts.isEmpty {
        Text("report.receipts.empty")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("receipts-empty")
      }
      ForEach(store.receipts) { receipt in
        Section {
          Text(receipt.isPending ? "report.receipts.pending" : "report.receipts.delivered")
            .font(.headline)
          Text(
            receipt.receivedAt ?? receipt.createdAt,
            format: .dateTime.day().month().year().hour().minute())
          LabeledContent("report.receipts.expires") {
            Text(receipt.expiresAt, format: .dateTime.day().month().year())
          }
          LabeledContent("report.receipts.reference") {
            Text(verbatim: receipt.reportID.uuidString)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
          Button(role: .destructive) {
            deletingID = receipt.reportID
            error = nil
            deleteTask = Task {
              defer { deletingID = nil }
              do {
                try await sender.delete(receipt)
              } catch is CancellationError {
                // Keep the receipt until the server confirms deletion.
              } catch let failure as UserErrorReportError {
                error = failure
              } catch {
                self.error = .unavailable
              }
            }
          } label: {
            HStack {
              Label("report.receipts.delete", systemImage: "trash")
              if deletingID == receipt.reportID {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(deletingID != nil)
          .accessibilityIdentifier("error-report-delete")
        }
      }
    }
    .navigationTitle("report.receipts.title")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      do { try store.prune() } catch { self.error = .storageUnavailable }
    }
    .onDisappear { deleteTask?.cancel() }
  }
}
