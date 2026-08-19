import CoreLocation
import MapKit
import NextStopCore

struct MapFallbackPOI: Identifiable, Hashable {
  enum Kind: Hashable {
    case charging
    case restaurant
  }

  let id: String
  let name: String
  let coordinate: Coordinate
  let kind: Kind
}

struct ApplePlaceResolution {
  let chargingItems: [MKMapItem]
  let restaurantItem: MKMapItem?
  let fallbackPOIs: [MapFallbackPOI]

  var unmatchedChargingNames: [String] {
    fallbackPOIs
      .filter { $0.kind == .charging }
      .map(\.name)
      .sorted()
  }

  var restaurantUsesFallback: Bool {
    fallbackPOIs.contains { $0.kind == .restaurant }
  }
}

@MainActor
protocol ApplePlaceResolving {
  func resolve(park: ChargingPark, foodPOI: FoodPOI?) async -> ApplePlaceResolution
}

@MainActor
final class MapKitApplePlaceResolver: ApplePlaceResolving {
  private let maximumDirectMatchDistance: CLLocationDistance = 60
  private let maximumAddressBackedMatchDistance: CLLocationDistance = 125
  private let maximumRestaurantMatchDistance: CLLocationDistance = 125

  func resolve(park: ChargingPark, foodPOI: FoodPOI?) async -> ApplePlaceResolution {
    let lookups = lookupTargets(for: park)
    let chargingItems = (try? await searchChargingItems(around: park, lookups: lookups)) ?? []
    let matchedChargingItems = chargingItems.filter { item in
      lookups.contains { lookup in
        isSecureChargingMatch(item: item, lookup: lookup)
      }
    }
    let deduplicatedChargingItems = deduplicate(matchedChargingItems)
    let matchedOperatorKeys = Set(
      lookups.compactMap { lookup in
        deduplicatedChargingItems.contains {
          isSecureChargingMatch(item: $0, lookup: lookup)
        } ? operatorKey(lookup.operatorName) : nil
      }
    )
    var fallbackPOIs = fallbackChargingPOIs(
      lookups: lookups,
      matchedOperatorKeys: matchedOperatorKeys,
      park: park
    )

    let restaurantItem: MKMapItem?
    if let foodPOI {
      restaurantItem = try? await searchRestaurantItem(for: foodPOI)
      if restaurantItem == nil {
        fallbackPOIs.append(
          MapFallbackPOI(
            id: "restaurant:\(foodPOI.id)",
            name: foodPOI.name,
            coordinate: foodPOI.coordinate,
            kind: .restaurant
          )
        )
      }
    } else {
      restaurantItem = nil
    }

    return ApplePlaceResolution(
      chargingItems: deduplicatedChargingItems,
      restaurantItem: restaurantItem,
      fallbackPOIs: fallbackPOIs
    )
  }

  private func searchChargingItems(
    around park: ChargingPark,
    lookups: [LookupTarget]
  ) async throws -> [MKMapItem] {
    let center = CLLocationCoordinate2D(
      latitude: park.navigationCoordinate.latitude,
      longitude: park.navigationCoordinate.longitude
    )
    let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
    let farthestLookup = lookups.map {
      centerLocation.distance(from: CLLocation(
        latitude: $0.coordinate.latitude,
        longitude: $0.coordinate.longitude
      ))
    }.max() ?? 0
    let radius = min(600, max(300, farthestLookup + maximumAddressBackedMatchDistance))
    let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
    return try await MKLocalSearch(request: request).start().mapItems
  }

  private func searchRestaurantItem(for foodPOI: FoodPOI) async throws -> MKMapItem? {
    let center = CLLocationCoordinate2D(
      latitude: foodPOI.coordinate.latitude,
      longitude: foodPOI.coordinate.longitude
    )
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = foodPOI.name
    request.region = MKCoordinateRegion(
      center: center,
      latitudinalMeters: 400,
      longitudinalMeters: 400
    )
    request.resultTypes = .pointOfInterest
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant])
    let expectedName = normalized(foodPOI.name)
    return try await MKLocalSearch(request: request).start().mapItems
      .compactMap { item -> (item: MKMapItem, distance: CLLocationDistance)? in
        guard let itemLocation = mapItemLocation(item) else {
          return nil
        }
        let distance = itemLocation.distance(from: CLLocation(
          latitude: foodPOI.coordinate.latitude,
          longitude: foodPOI.coordinate.longitude
        ))
        guard distance <= maximumRestaurantMatchDistance,
          normalized(item.name ?? "").contains(expectedName)
            || expectedName.contains(normalized(item.name ?? ""))
        else {
          return nil
        }
        return (item, distance)
      }
      .min { $0.distance < $1.distance }?
      .item
  }

  private func isSecureChargingMatch(item: MKMapItem, lookup: LookupTarget) -> Bool {
    guard let itemLocation = mapItemLocation(item),
      operatorMatches(item.name ?? "", lookup.operatorName)
    else {
      return false
    }
    let distance = itemLocation.distance(from: CLLocation(
      latitude: lookup.coordinate.latitude,
      longitude: lookup.coordinate.longitude
    ))
    if distance <= maximumDirectMatchDistance {
      return true
    }
    return distance <= maximumAddressBackedMatchDistance
      && addressMatches(item: item, lookup: lookup)
  }

  private func addressMatches(item: MKMapItem, lookup: LookupTarget) -> Bool {
    let appleAddress = normalized(mapItemAddress(item) ?? "")
    guard !appleAddress.isEmpty else {
      return false
    }
    let street = lookup.address.street.map(normalized)
    let houseNumber = lookup.address.houseNumber.map(normalized)
    let postalCode = lookup.address.postalCode.map(normalized)
    let city = lookup.address.city.map(normalized)
    let streetMatches = street.map(appleAddress.contains) ?? false
    let houseNumberMatches = houseNumber.map(appleAddress.contains) ?? false
    let localityMatches = (postalCode.map(appleAddress.contains) ?? false)
      || (city.map(appleAddress.contains) ?? false)
    return streetMatches && houseNumberMatches && localityMatches
  }

  private func lookupTargets(for park: ChargingPark) -> [LookupTarget] {
    if !park.locationLookups.isEmpty {
      return park.locationLookups.map {
        LookupTarget(
          id: $0.id.uuidString.lowercased(),
          operatorName: $0.operatorName,
          coordinate: $0.coordinate,
          address: $0.address
        )
      }
    }
    return park.operatorChargingPoints.map {
      LookupTarget(
        id: "operator:\($0.name)",
        operatorName: $0.name,
        coordinate: park.navigationCoordinate,
        address: ChargingLocationAddress()
      )
    }
  }

  private func fallbackChargingPOIs(
    lookups: [LookupTarget],
    matchedOperatorKeys: Set<String>,
    park: ChargingPark
  ) -> [MapFallbackPOI] {
    let parkLocation = CLLocation(
      latitude: park.navigationCoordinate.latitude,
      longitude: park.navigationCoordinate.longitude
    )
    return Dictionary(grouping: lookups, by: { operatorKey($0.operatorName) })
      .compactMap { key, candidates in
        guard !matchedOperatorKeys.contains(key),
          let lookup = candidates.min(by: {
            distance($0.coordinate, from: parkLocation)
              < distance($1.coordinate, from: parkLocation)
          })
        else {
          return nil
        }
        return MapFallbackPOI(
          id: "charging:\(lookup.id)",
          name: lookup.operatorName,
          coordinate: lookup.coordinate,
          kind: .charging
        )
      }
  }

  private func deduplicate(_ items: [MKMapItem]) -> [MKMapItem] {
    var seen = Set<String>()
    return items.filter { item in
      let location = mapItemLocation(item)
      let key = item.identifier?.rawValue
        ?? "\(normalized(item.name ?? "")):\(location?.coordinate.latitude ?? 0):\(location?.coordinate.longitude ?? 0)"
      return seen.insert(key).inserted
    }
  }

  private func operatorKey(_ value: String) -> String {
    let compact = normalized(value).replacingOccurrences(of: " ", with: "")
    let aliases: [(String, String)] = [
      ("ewego", "ewego"),
      ("enbw", "enbw"),
      ("entega", "entega"),
      ("shell", "shell"),
      ("electra", "electra"),
      ("homeofmobility", "homeofmobility"),
      ("home", "homeofmobility"),
      ("tesla", "tesla"),
      ("ionity", "ionity"),
      ("aralpulse", "aralpulse"),
      ("allego", "allego"),
      ("pfalzwerke", "pfalzwerke"),
    ]
    if let alias = aliases.first(where: { compact.contains($0.0) }) {
      return alias.1
    }
    let ignored = Set(["gmbh", "ag", "co", "kg", "deutschland", "germany", "mobil", "mobility"])
    return normalized(value)
      .split(separator: " ")
      .map(String.init)
      .filter { !ignored.contains($0) }
      .joined(separator: " ")
  }

  private func operatorMatches(_ first: String, _ second: String) -> Bool {
    if operatorKey(first) == operatorKey(second) {
      return true
    }
    let firstTokens = significantOperatorTokens(first)
    let secondTokens = significantOperatorTokens(second)
    return !firstTokens.intersection(secondTokens).isEmpty
  }

  private func significantOperatorTokens(_ value: String) -> Set<String> {
    let ignored = Set([
      "gmbh", "ag", "co", "kg", "deutschland", "germany", "mobil", "mobility",
      "elektromobilitat", "infrastruktur", "solutions", "plus", "und", "charge",
      "charging", "drive", "energie", "energy",
    ])
    return Set(
      normalized(value)
        .split(separator: " ")
        .map(String.init)
        .filter { $0.count >= 3 && !ignored.contains($0) }
    )
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
      .reduce(into: "") { result, character in
        if character == " ", result.last == " " {
          return
        }
        result.append(character)
      }
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func distance(_ coordinate: Coordinate, from origin: CLLocation) -> CLLocationDistance {
    origin.distance(from: CLLocation(
      latitude: coordinate.latitude,
      longitude: coordinate.longitude
    ))
  }

  private func mapItemLocation(_ item: MKMapItem) -> CLLocation? {
    if #available(iOS 26.0, *) {
      return item.location
    }
    return legacyLocation(item)
  }

  private func mapItemAddress(_ item: MKMapItem) -> String? {
    if #available(iOS 26.0, *) {
      return item.address?.fullAddress
    }
    return legacyAddress(item)
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private func legacyLocation(_ item: MKMapItem) -> CLLocation? {
    item.placemark.location
  }

  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  private func legacyAddress(_ item: MKMapItem) -> String? {
    item.placemark.title
  }
}

private struct LookupTarget {
  let id: String
  let operatorName: String
  let coordinate: Coordinate
  let address: ChargingLocationAddress
}
