import MapKit
import NextStopCore

@MainActor
final class MapKitDestinationSearchService: DestinationSearching {
  func search(query: String) async throws -> [DestinationSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      return []
    }

    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = trimmedQuery
    request.resultTypes = [.address, .pointOfInterest]

    let response = try await MKLocalSearch(request: request).start()
    return response.mapItems.compactMap(Self.makeResult)
  }

  private static func makeResult(from mapItem: MKMapItem) -> DestinationSearchResult? {
    let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !name.isEmpty else {
      return nil
    }

    let location: CLLocation
    let address: String?
    if #available(iOS 26.0, *) {
      location = mapItem.location
      address = mapItem.address?.fullAddress
    } else {
      guard let legacyLocation = legacyLocationAndAddress(for: mapItem) else {
        return nil
      }
      location = legacyLocation.location
      address = legacyLocation.address
    }
    let coordinate: Coordinate
    do {
      coordinate = try Coordinate(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude
      )
    } catch {
      return nil
    }

    let applePlaceIdentifier = mapItem.identifier?.rawValue
    let fallbackID = "\(coordinate.latitude),\(coordinate.longitude),\(name)"
    guard
      let destination = try? SavedDestination(
        displayName: name,
        coordinate: coordinate,
        applePlaceIdentifier: applePlaceIdentifier,
        displayAddress: address
      )
    else {
      return nil
    }

    return DestinationSearchResult(
      id: applePlaceIdentifier ?? fallbackID,
      destination: destination,
      subtitle: address == name ? nil : address
    )
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private static func legacyLocationAndAddress(for mapItem: MKMapItem) -> (
    location: CLLocation, address: String?
  )? {
    guard let location = mapItem.placemark.location else {
      return nil
    }
    return (location, mapItem.placemark.title)
  }
}
