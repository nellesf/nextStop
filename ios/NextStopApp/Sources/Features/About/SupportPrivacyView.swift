import Foundation
import SwiftUI

struct SupportPrivacyView: View {
  let configuration: SupportPrivacyConfiguration?

  var body: some View {
    // Privacy is a complete document, not a collection of cell-sized summaries.
    // Eager layout lets every paragraph grow at accessibility text sizes without
    // relying on List's estimated row heights or multiline cell truncation.
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if configuration?.usesInternalTestPlaceholders == true {
          card {
            Label("report.internal.title", systemImage: "exclamationmark.triangle")
              .font(.headline)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
            paragraph(Text("report.internal.notice"))
          }
        }
        documentSection("report.privacy.controller") {
          if let configuration {
            paragraph(Text(verbatim: configuration.displayControllerName))
              .accessibilityIdentifier("report-privacy-content")
            Divider()
            paragraph(Text(verbatim: configuration.displayPostalAddress))
            Divider()
            paragraph(Text(verbatim: configuration.email))
              .textSelection(.enabled)
          } else {
            paragraph(Text("report.configuration_missing"))
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
        card {
          Link(
            destination: URL(string: "https://cloud.google.com/terms/data-processing-addendum")!
          ) {
            paragraph(Text("report.privacy.google_terms"))
          }
          Divider()
          Link(
            destination: URL(
              string: "https://www.bfdi.bund.de/DE/Service/Anschriften/anschriften_node.html")!
          ) {
            paragraph(Text("report.privacy.authorities"))
          }
        }
        paragraph(Text("report.privacy.version"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("report.privacy.title")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func notice(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
    documentSection(title) {
      paragraph(Text(body))
    }
  }

  private func documentSection<Content: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 16)
      card(content: content)
    }
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 16, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(
        Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
  }

  private func paragraph(_ text: Text) -> some View {
    text
      .lineLimit(nil)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SupportPrivacyTestNotice: View {
  var body: some View {
    Section {
      Label("report.internal.title", systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text("report.internal.notice")
        .lineLimit(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
