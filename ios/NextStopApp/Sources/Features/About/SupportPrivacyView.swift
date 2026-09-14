import Foundation
import SwiftUI
import UIKit

struct SupportPrivacyView: View {
  let configuration: SupportPrivacyConfiguration?

  var body: some View {
    // Keep the complete notice navigable as a document at every text size.
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if configuration?.usesInternalTestPlaceholders == true {
          card {
            Label("report.internal.title", systemImage: "exclamationmark.triangle")
              .font(.headline)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
            paragraph(String(localized: "report.internal.notice"))
          }
        }
        documentSection("report.privacy.controller") {
          if let configuration {
            paragraph(configuration.displayControllerName, identifier: "report-privacy-content")
            Divider()
            paragraph(configuration.displayPostalAddress)
            Divider()
            // Retain native text selection for copying the contact address.
            wrappedText(Text(verbatim: configuration.email))
              .textSelection(.enabled)
          } else {
            paragraph(String(localized: "report.configuration_missing"))
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
            wrappedText(Text("report.privacy.google_terms"))
          }
          Divider()
          Link(
            destination: URL(
              string: "https://www.bfdi.bund.de/DE/Service/Anschriften/anschriften_node.html")!
          ) {
            wrappedText(Text("report.privacy.authorities"))
          }
        }
        wrappedText(Text("report.privacy.version"))
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

  private func notice(_ title: LocalizedStringKey, _ body: String.LocalizationValue) -> some View {
    documentSection(title) {
      paragraph(String(localized: body))
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

  private func paragraph(_ text: String, identifier: String? = nil) -> some View {
    SupportPrivacyParagraph(text: text, identifier: identifier)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func wrappedText(_ text: Text) -> some View {
    text
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// SwiftUI Text can under-measure German paragraphs even with unlimited lines
/// and fixedSize (FB22577211, https://developer.apple.com/forums/thread/823675).
/// Measure and draw using the same UIKit label at the actual proposed width.
private struct SupportPrivacyParagraph: UIViewRepresentable {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let text: String
  var identifier: String? = nil

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.adjustsFontSizeToFitWidth = false
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .label
    label.backgroundColor = .clear
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.isAccessibilityElement = true
    label.accessibilityTraits = .staticText
    configure(label)
    return label
  }

  func updateUIView(_ uiView: UILabel, context: Context) {
    configure(uiView)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView: UILabel, context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: ceil(size.height))
  }

  private func configure(_ label: UILabel) {
    label.text = text
    label.accessibilityIdentifier = identifier
    label.font = UIFont.preferredFont(
      forTextStyle: .body,
      compatibleWith: UITraitCollection(
        preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
      )
    )
  }
}

struct SupportPrivacyTestNotice: View {
  var body: some View {
    Section {
      Label("report.internal.title", systemImage: "exclamationmark.triangle")
        .font(.headline)
      SupportPrivacyParagraph(text: String(localized: "report.internal.notice"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
