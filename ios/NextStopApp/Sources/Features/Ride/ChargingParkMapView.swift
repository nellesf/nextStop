import Combine
import MapKit
import NextStopCore
import SwiftUI

@MainActor
final class ChargingParkMapViewModel: ObservableObject {
  @Published private(set) var resolution: ApplePlaceResolution?
  @Published private(set) var isLoading = false

  let result: RouteSearchResult
  let route: RoutePolyline

  private let resolver: any ApplePlaceResolving

  init(
    result: RouteSearchResult,
    route: RoutePolyline,
    resolver: any ApplePlaceResolving = MapKitApplePlaceResolver()
  ) {
    self.result = result
    self.route = route
    self.resolver = resolver
  }

  func load() async {
    guard resolution == nil, !isLoading else {
      return
    }
    isLoading = true
    resolution = await resolver.resolve(
      park: result.candidate.park,
      foodPOI: result.matchingFoodPOI
    )
    isLoading = false
  }
}

struct ChargingParkMapView: View {
  @StateObject private var viewModel: ChargingParkMapViewModel
  @State private var selectedMapItem: MKMapItem?
  @State private var appleMapsLaunchFailed = false

  private let finalDestination: SavedDestination
  private let navigationLauncher: any AppleMapsLaunching

  @MainActor
  init(
    result: RouteSearchResult,
    preparedRide: PreparedRideSearch,
    finalDestination: SavedDestination,
    navigationLauncher: any AppleMapsLaunching
  ) {
    _viewModel = StateObject(
      wrappedValue: ChargingParkMapViewModel(
        result: result,
        route: preparedRide.route.polyline
      )
    )
    self.finalDestination = finalDestination
    self.navigationLauncher = navigationLauncher
  }

  @MainActor
  init(
    viewModel: ChargingParkMapViewModel,
    finalDestination: SavedDestination,
    navigationLauncher: any AppleMapsLaunching
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    self.finalDestination = finalDestination
    self.navigationLauncher = navigationLauncher
  }

  var body: some View {
    map
      .safeAreaInset(edge: .bottom) {
        controls
      }
      .navigationTitle("ride.map.title")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        await viewModel.load()
      }
      .alert("ride.map.apple_maps.error.title", isPresented: $appleMapsLaunchFailed) {
        Button("action.done", role: .cancel) {}
      } message: {
        Text("ride.map.apple_maps.error.description")
      }
  }

  private var map: some View {
    Map(
      initialPosition: .rect(Self.mapRect(for: viewModel.route, result: viewModel.result)),
      selection: $selectedMapItem
    ) {
      MapPolyline(coordinates: mapCoordinates)
        .stroke(.blue, lineWidth: 5)

      if let resolution = viewModel.resolution {
        ForEach(resolution.chargingItems, id: \.self) { item in
          Marker(item: item)
            .tint(.blue)
            .tag(item)
        }

        if let restaurantItem = resolution.restaurantItem {
          Marker(item: restaurantItem)
            .tint(.orange)
            .tag(restaurantItem)
        }

        ForEach(resolution.fallbackPOIs) { poi in
          Annotation(poi.name, coordinate: mapCoordinate(poi.coordinate)) {
            fallbackMarker(poi)
          }
        }
      }
    }
    .mapStyle(.standard(pointsOfInterest: .excludingAll))
    .mapItemDetailSheet(item: $selectedMapItem)
    .mapControls {
      MapCompass()
      MapScaleView()
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      if viewModel.isLoading {
        HStack(spacing: 10) {
          ProgressView()
          Text("ride.map.apple_places.loading")
            .font(.subheadline)
        }
      }

      if let resolution = viewModel.resolution {
        if !resolution.unmatchedChargingNames.isEmpty {
          Label("ride.map.apple_places.partial.title", systemImage: "exclamationmark.circle")
            .font(.subheadline.weight(.semibold))
          Text(
            String.localizedStringWithFormat(
              NSLocalizedString(
                "ride.map.apple_places.partial.format",
                comment: "Operators without a matched Apple place"
              ),
              resolution.unmatchedChargingNames.joined(separator: ", ")
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if resolution.restaurantUsesFallback {
          Text("ride.map.apple_places.restaurant_fallback")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !resolution.appleMapsItems.isEmpty {
          Button {
            appleMapsLaunchFailed = !navigationLauncher.showPlaces(
              resolution.appleMapsItems
            )
          } label: {
            Label("ride.map.open_apple_places", systemImage: "map.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
      }

      Button {
        appleMapsLaunchFailed = !navigationLauncher.startNavigation(
          to: viewModel.result.candidate.park,
          via: viewModel.result.matchingFoodPOI,
          finalDestination: finalDestination
        )
      } label: {
        Label(
          "ride.map.start_navigation",
          systemImage: "arrow.triangle.turn.up.right.diamond.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
    }
    .padding()
    .background(.regularMaterial)
  }

  private var mapCoordinates: [CLLocationCoordinate2D] {
    viewModel.route.coordinates.map(mapCoordinate)
  }

  @ViewBuilder
  private func fallbackMarker(_ poi: MapFallbackPOI) -> some View {
    VStack(spacing: 2) {
      Image(systemName: poi.kind == .charging ? "ev.charger.fill" : "fork.knife")
        .font(.headline)
        .foregroundStyle(.white)
        .padding(8)
        .background(poi.kind == .charging ? Color.gray : Color.orange)
        .clipShape(Circle())
        .overlay {
          Circle().stroke(.white, lineWidth: 2)
        }
      Text(poi.name)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.regularMaterial)
        .clipShape(Capsule())
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("ride.map.apple_places.fallback_hint")
  }

  private func mapCoordinate(_ coordinate: Coordinate) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    )
  }

  private static func mapRect(for route: RoutePolyline, result: RouteSearchResult) -> MKMapRect {
    var rect = MKMapRect.null
    let points = route.coordinates
      + [result.candidate.park.navigationCoordinate]
      + [result.matchingFoodPOI?.coordinate].compactMap { $0 }
    for coordinate in points {
      let point = MKMapPoint(CLLocationCoordinate2D(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      ))
      let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
      rect = rect.union(pointRect)
    }
    let horizontalPadding = max(rect.size.width * 0.08, 5_000)
    let verticalPadding = max(rect.size.height * 0.08, 5_000)
    return rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
  }
}
