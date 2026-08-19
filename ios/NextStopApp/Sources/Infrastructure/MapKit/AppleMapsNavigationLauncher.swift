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
  @discardableResult
  func openPlace(_ mapItem: MKMapItem) -> Bool {
    if #available(iOS 18.4, *),
      let placeIdentifier = mapItem.identifier?.rawValue,
      let placeURL = Self.placeURL(placeIdentifier: placeIdentifier)
    {
      guard UIApplication.shared.canOpenURL(placeURL) else {
        return false
      }
      UIApplication.shared.open(placeURL)
      return true
    }
    return mapItem.openInMaps()
  }

  @discardableResult
  func startNavigation(
    to park: ChargingPark,
    via foodPOI: FoodPOI?,
    finalDestination: SavedDestination
  ) -> Bool {
    if #available(iOS 18.4, *),
      let foodPOI,
      let directionsURL = Self.multistopDirectionsURL(
        waypoint: foodPOI,
        finalDestination: finalDestination
      )
    {
      guard UIApplication.shared.canOpenURL(directionsURL) else {
        return false
      }
      UIApplication.shared.open(directionsURL)
      return true
    }

    let coordinate = foodPOI?.coordinate ?? park.navigationCoordinate
    let name = foodPOI?.name ?? park.name
    let mapItem = makeMapItem(coordinate: coordinate, name: name)
    return mapItem.openInMaps(
      launchOptions: [
        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
      ]
    )
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
