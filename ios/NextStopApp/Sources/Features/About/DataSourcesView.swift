import Foundation
import SwiftUI

struct DataSourcesView: View {
  var body: some View {
    List {
      Section("licenses.restaurant.title") {
        Text("licenses.restaurant.description")
        Link(
          "© OpenStreetMap contributors",
          destination: URL(string: "https://www.openstreetmap.org/copyright")!)
        LabeledContent("licenses.license") {
          Text("Open Database License (ODbL) 1.0")
        }
        Link("licenses.geofabrik", destination: URL(string: "https://download.geofabrik.de/")!)
      }

      Section("licenses.charging.title") {
        Text("licenses.charging.description")
        Link(
          "Bundesnetzagentur",
          destination: URL(string: "https://www.bundesnetzagentur.de/ladesaeulenkarte")!)
        Link(
          "Bundesamt für Energie BFE", destination: URL(string: "https://www.ich-tanke-strom.ch/")!)
      }

      Section("licenses.maps.title") {
        Text("licenses.maps.description")
      }
    }
    .navigationTitle("licenses.title")
  }
}
