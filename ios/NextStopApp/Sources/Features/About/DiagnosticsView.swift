import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
  @ObservedObject private var store: AppDiagnosticsStore
  @State private var exportDocument: DiagnosticsDocument?
  @State private var isExporting = false
  @State private var exportFailed = false

  init(store: AppDiagnosticsStore) {
    self.store = store
  }

  var body: some View {
    List {
      Section {
        Text("diagnostics.description")
        LabeledContent("diagnostics.saved_count") {
          Text(store.events.count, format: .number)
        }
        if store.deletionFailed {
          Text("diagnostics.deletion_failed")
            .foregroundStyle(.secondary)
        } else if !store.persistenceAvailable {
          Text("diagnostics.storage_unavailable")
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("diagnostics.retention")
      }

      Section {
        Toggle("diagnostics.recording", isOn: $store.recordingEnabled)
      } footer: {
        Text("diagnostics.recording.description")
      }

      Section {
        Button {
          do {
            exportDocument = DiagnosticsDocument(data: try store.exportData())
            isExporting = true
          } catch {
            exportFailed = true
          }
        } label: {
          Label("diagnostics.export", systemImage: "square.and.arrow.up")
        }
        .disabled(store.events.isEmpty)

        Button(role: .destructive) {
          store.clear()
          exportDocument = nil
        } label: {
          Label("diagnostics.clear", systemImage: "trash")
        }
        .disabled(store.events.isEmpty && !store.deletionFailed)
      } footer: {
        Text("diagnostics.export.description")
      }
    }
    .navigationTitle("diagnostics.title")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { store.prune() }
    .fileExporter(
      isPresented: $isExporting,
      document: exportDocument,
      contentType: .json,
      defaultFilename: "nextStop-diagnostics"
    ) { result in
      exportDocument = nil
      if case .failure = result { exportFailed = true }
    }
    .alert("diagnostics.export_failed", isPresented: $exportFailed) {
      Button("diagnostics.dismiss", role: .cancel) {}
    }
  }
}

private struct DiagnosticsDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
