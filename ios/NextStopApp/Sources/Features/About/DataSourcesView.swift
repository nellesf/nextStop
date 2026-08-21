import Foundation
import SwiftUI

struct DataSourcesView: View {
  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        sourceCard(
          "licenses.restaurant.title",
          systemImage: "fork.knife"
        ) {
          Text("licenses.restaurant.description")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          cardDivider

          sourceLink(
            Text(verbatim: "© OpenStreetMap contributors"),
            destination: URL(string: "https://www.openstreetmap.org/copyright")!
          )

          cardDivider

          VStack(alignment: .leading, spacing: 3) {
            Text("licenses.license")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(verbatim: "Open Database License (ODbL) 1.0")
              .font(.subheadline.weight(.medium))
          }

          cardDivider

          sourceLink(
            Text("licenses.geofabrik"),
            destination: URL(string: "https://download.geofabrik.de/")!
          )
        }

        sourceCard(
          "licenses.charging.title",
          systemImage: "ev.charger"
        ) {
          Text("licenses.charging.description")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          cardDivider

          sourceLink(
            Text(verbatim: "Bundesnetzagentur"),
            destination: URL(
              string: "https://www.bundesnetzagentur.de/ladesaeulenkarte"
            )!
          )

          cardDivider

          sourceLink(
            Text(verbatim: "Bundesamt für Energie BFE"),
            destination: URL(string: "https://www.ich-tanke-strom.ch/")!
          )
        }

        sourceCard(
          "licenses.maps.title",
          systemImage: "map"
        ) {
          Text("licenses.maps.description")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("licenses.title")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func sourceCard<Content: View>(
    _ title: LocalizedStringKey,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: systemImage)
        .font(.headline.weight(.semibold))

      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
  }

  private func sourceLink(
    _ title: Text,
    destination: URL
  ) -> some View {
    Link(destination: destination) {
      HStack(spacing: 12) {
        title
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)

        Spacer(minLength: 8)

        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
  }

  private var cardDivider: some View {
    Divider()
  }
}
