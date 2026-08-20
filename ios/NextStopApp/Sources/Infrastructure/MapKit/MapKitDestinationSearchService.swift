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

    let location = mapItem.location
    let address = mapItem.address?.fullAddress
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
}
