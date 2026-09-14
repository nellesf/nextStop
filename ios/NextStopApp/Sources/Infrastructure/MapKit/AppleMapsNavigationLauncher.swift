import CoreLocation
import MapKit
import NextStopCore
import UIKit

@MainActor
protocol AppleMapsLaunching: AnyObject {
  @discardableResult
  func openPlace(_ mapItem: MKMapItem) -> Bool

  @discardableResult
  func startNavigation(
    to park: ChargingPark,
    via foodPOI: FoodPOI?,
    finalDestination: SavedDestination
  ) -> Bool
}

@MainActor
final class AppleMapsLauncher: AppleMapsLaunching {
  typealias OpenURL = @MainActor (URL, @escaping @MainActor @Sendable (Bool) -> Void) -> Void
  typealias OpenMapItem = @MainActor (MKMapItem, [String: Any]?) -> Bool

  private let measurement: AppDiagnosticMeasurement
  private let canOpenURL: @MainActor (URL) -> Bool
  private let openURL: OpenURL
  private let openMapItem: OpenMapItem
  private let nativePlaceURL: @MainActor (MKMapItem) -> URL?

  init(
    diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics(),
    now: @escaping AppDiagnosticMeasurement.Now = Date.init,
    canOpenURL: @escaping @MainActor (URL) -> Bool = { UIApplication.shared.canOpenURL($0) },
    openURL: @escaping OpenURL = { url, completion in
      UIApplication.shared.open(url, options: [:]) { success in
        Task { @MainActor in completion(success) }
      }
    },
    openMapItem: @escaping OpenMapItem = { $0.openInMaps(launchOptions: $1) },
    nativePlaceURL: @escaping @MainActor (MKMapItem) -> URL? = { mapItem in
      guard #available(iOS 18.4, *), let identifier = mapItem.identifier?.rawValue else {
        return nil
      }
      return AppleMapsLauncher.placeURL(placeIdentifier: identifier)
    }
  ) {
    measurement = AppDiagnosticMeasurement(recorder: diagnostics, now: now)
    self.canOpenURL = canOpenURL
    self.openURL = openURL
    self.openMapItem = openMapItem
    self.nativePlaceURL = nativePlaceURL
  }

  @discardableResult
  func openPlace(_ mapItem: MKMapItem) -> Bool {
    guard !Task.isCancelled else { return false }
    let startedAt = measurement.now()
    if let placeURL = nativePlaceURL(mapItem) {
      return open(url: placeURL, startedAt: startedAt)
    }
    return recordResult(openMapItem(mapItem, nil), startedAt: startedAt)
  }

  @discardableResult
  func startNavigation(
    to park: ChargingPark,
    via foodPOI: FoodPOI?,
    finalDestination: SavedDestination
  ) -> Bool {
    guard !Task.isCancelled else { return false }
    let startedAt = measurement.now()
    if #available(iOS 18.4, *),
      let foodPOI,
      let directionsURL = Self.multistopDirectionsURL(
        waypoint: foodPOI,
        finalDestination: finalDestination
      )
    {
      return open(url: directionsURL, startedAt: startedAt)
    }

    let coordinate = foodPOI?.coordinate ?? park.navigationCoordinate
    let name = foodPOI?.name ?? park.name
    let mapItem = makeMapItem(coordinate: coordinate, name: name)
    return recordResult(
      openMapItem(
        mapItem, [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
      ),
      startedAt: startedAt
    )
  }

  private func open(url: URL, startedAt: Date) -> Bool {
    guard canOpenURL(url) else { return recordResult(false, startedAt: startedAt) }
    let measurement = measurement
    openURL(url) { success in
      if !success {
        measurement.recordFailure(.mapsLaunch, startedAt: startedAt)
      }
    }
    // Keep the existing synchronous acceptance contract. An eventual platform
    // rejection is diagnosed by the completion callback above.
    return true
  }

  private func recordResult(_ succeeded: Bool, startedAt: Date) -> Bool {
    if !succeeded {
      measurement.recordFailure(.mapsLaunch, startedAt: startedAt)
    }
    return succeeded
  }

  static func multistopDirectionsURL(
    waypoint: FoodPOI,
    finalDestination: SavedDestination
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "maps.apple.com"
    components.path = "/directions"
    var queryItems = [
      URLQueryItem(
        name: "destination",
        value: coordinateValue(finalDestination.coordinate)
      ),
      URLQueryItem(name: "waypoint", value: coordinateValue(waypoint.coordinate)),
      URLQueryItem(name: "mode", value: "driving"),
    ]
    if let placeIdentifier = finalDestination.applePlaceIdentifier {
      queryItems.append(
        URLQueryItem(name: "destination-place-id", value: placeIdentifier)
      )
    }
    if let placeIdentifier = waypoint.applePlaceIdentifier {
      queryItems.append(
        URLQueryItem(name: "waypoint-place-id", value: placeIdentifier)
      )
    }
    components.queryItems = queryItems
    return components.url
  }

  static func placeURL(placeIdentifier: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "maps.apple.com"
    components.path = "/place"
    components.queryItems = [
      URLQueryItem(name: "place-id", value: placeIdentifier)
    ]
    return components.url
  }

  private static func coordinateValue(_ coordinate: Coordinate) -> String {
    "\(coordinate.latitude),\(coordinate.longitude)"
  }

  private func makeMapItem(coordinate: Coordinate, name: String) -> MKMapItem {
    let location = CLLocation(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    )
    let mapItem: MKMapItem
    if #available(iOS 26.0, *) {
      mapItem = MKMapItem(location: location, address: nil)
    } else {
      mapItem = makeLegacyMapItem(for: location)
    }
    mapItem.name = name
    return mapItem
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private func makeLegacyMapItem(for location: CLLocation) -> MKMapItem {
    MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
  }
}
