import Foundation
import SwiftUI

struct SupportPrivacyView: View {
  let configuration: SupportPrivacyConfiguration?

  var body: some View {
    List {
      if configuration?.usesInternalTestPlaceholders == true {
        SupportPrivacyTestNotice()
      }
      Section("report.privacy.controller") {
        if let configuration {
          Text(verbatim: configuration.displayControllerName)
          Text(verbatim: configuration.displayPostalAddress)
          Text(verbatim: configuration.email)
            .textSelection(.enabled)
        } else {
          Text("report.configuration_missing")
        }
      }
      notice("report.privacy.purpose", "report.privacy.purpose.body")
      notice("report.privacy.data", "report.privacy.data.body")
      notice("report.privacy.recipients", "report.privacy.recipients.body")
      notice("report.privacy.retention", "report.privacy.retention.body")
      notice("report.privacy.integrity", "report.privacy.integrity.body")
      notice("report.privacy.withdrawal", "report.privacy.withdrawal.body")
      notice("report.privacy.rights", "report.privacy.rights.body")
      notice("report.privacy.voluntary", "report.privacy.voluntary.body")
      Section {
        Link(
          "report.privacy.google_terms",
          destination: URL(string: "https://cloud.google.com/terms/data-processing-addendum")!
        )
        Link(
          "report.privacy.authorities",
          destination: URL(
            string: "https://www.bfdi.bund.de/DE/Service/Anschriften/anschriften_node.html")!
        )
      } footer: {
        Text("report.privacy.version")
      }
    }
    .navigationTitle("report.privacy.title")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func notice(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
    Section(title) { Text(body) }
  }
}

struct SupportPrivacyTestNotice: View {
  var body: some View {
    Section {
      Label("report.internal.title", systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text("report.internal.notice")
    }
  }
}
