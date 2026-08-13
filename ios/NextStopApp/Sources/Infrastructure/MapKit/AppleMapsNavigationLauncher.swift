import CoreLocation
import MapKit
import NextStopCore

@MainActor
protocol NavigationLaunching: AnyObject {
  @discardableResult
  func startNavigation(to park: ChargingPark) -> Bool
}

@MainActor
final class AppleMapsNavigationLauncher: NavigationLaunching {
  @discardableResult
  func startNavigation(to park: ChargingPark) -> Bool {
    let coordinate = park.navigationCoordinate
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
    mapItem.name = park.name
    return mapItem.openInMaps(
      launchOptions: [
        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
      ]
    )
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private func makeLegacyMapItem(for location: CLLocation) -> MKMapItem {
    MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
  }
}
