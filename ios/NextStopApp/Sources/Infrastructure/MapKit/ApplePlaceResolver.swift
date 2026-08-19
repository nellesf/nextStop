import CoreLocation
import MapKit
import NextStopCore

enum AppleChargingPlaceMatchPolicy {
  static let maximumDirectDistanceMeters: Double = 60
  static let maximumExactAddressDistanceMeters: Double = 300

  static func accepts(
    distanceMeters: Double,
    hasExactAddressMatch: Bool
  ) -> Bool {
    distanceMeters <= maximumDirectDistanceMeters
      || (hasExactAddressMatch && distanceMeters <= maximumExactAddressDistanceMeters)
  }
}

@MainActor
protocol ApplePlaceResolving {
  func resolveChargingPlace(
    park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup]
  ) async -> MKMapItem?

  func resolveRestaurantPlace(_ foodPOI: FoodPOI) async -> MKMapItem?
}

@MainActor
final class MapKitApplePlaceResolver: ApplePlaceResolving {
  private let maximumRestaurantMatchDistance: CLLocationDistance = 125
  private let minimumChargingSearchCenterSeparation: CLLocationDistance = 75
  private var chargingPlaceCache: [String: MKMapItem] = [:]

  func resolveChargingPlace(
    park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup]
  ) async -> MKMapItem? {
    let lookups = lookupTargets(
      for: park,
      operatorName: operatorName,
      relatedLocations: relatedLocations
    )
    guard !lookups.isEmpty else {
      return nil
    }
    let cacheKey = chargingPlaceCacheKey(
      operatorName: operatorName,
      lookups: lookups
    )
    if let cacheKey, let cachedItem = chargingPlaceCache[cacheKey] {
      return cachedItem
    }

    for center in chargingSearchCenters(around: park, lookups: lookups) {
      guard let items = try? await searchChargingItems(around: center),
        let match = bestChargingMatch(items: items, lookups: lookups)
      else {
        continue
      }
      if let cacheKey {
        chargingPlaceCache[cacheKey] = match.item
      }
      return match.item
    }
    return nil
  }

  func resolveRestaurantPlace(_ foodPOI: FoodPOI) async -> MKMapItem? {
    try? await searchRestaurantItem(for: foodPOI)
  }

  private func searchChargingItems(
    around center: CLLocationCoordinate2D
  ) async throws -> [MKMapItem] {
    let request = MKLocalPointsOfInterestRequest(
      center: center,
      radius: AppleChargingPlaceMatchPolicy.maximumExactAddressDistanceMeters
    )
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
    return try await MKLocalSearch(request: request).start().mapItems
  }

  private func chargingSearchCenters(
    around park: ChargingPark,
    lookups: [LookupTarget]
  ) -> [CLLocationCoordinate2D] {
    let candidates = [park.navigationCoordinate] + lookups.map(\.coordinate)
    var centers: [CLLocationCoordinate2D] = []
    for candidate in candidates {
      let coordinate = CLLocationCoordinate2D(
        latitude: candidate.latitude,
        longitude: candidate.longitude
      )
      let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
      let alreadyCovered = centers.contains {
        location.distance(from: CLLocation(
          latitude: $0.latitude,
          longitude: $0.longitude
        )) < minimumChargingSearchCenterSeparation
      }
      if !alreadyCovered {
        centers.append(coordinate)
      }
    }
    return centers
  }

  private func chargingPlaceCacheKey(
    operatorName: String,
    lookups: [LookupTarget]
  ) -> String? {
    let addressKeys = Set(lookups.compactMap {
      AppleChargingPlaceLookupScope.addressKey($0.address)
    })
    guard !addressKeys.isEmpty else {
      return nil
    }
    return "\(operatorKey(operatorName))|\(addressKeys.sorted().joined(separator: ";"))"
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
        let itemName = normalized(item.name ?? "")
        guard !itemName.isEmpty,
          distance <= maximumRestaurantMatchDistance,
          itemName.contains(expectedName) || expectedName.contains(itemName)
        else {
          return nil
        }
        return (item, distance)
      }
      .min { $0.distance < $1.distance }?
      .item
  }

  private func secureMatchDistance(
    item: MKMapItem,
    lookup: LookupTarget
  ) -> CLLocationDistance? {
    guard let itemLocation = mapItemLocation(item),
      operatorMatches(item.name ?? "", lookup.operatorName)
    else {
      return nil
    }
    let distance = itemLocation.distance(from: CLLocation(
      latitude: lookup.coordinate.latitude,
      longitude: lookup.coordinate.longitude
    ))
    guard AppleChargingPlaceMatchPolicy.accepts(
      distanceMeters: distance,
      hasExactAddressMatch: addressMatches(item: item, lookup: lookup)
    ) else {
      return nil
    }
    return distance
  }

  private func bestChargingMatch(
    items: [MKMapItem],
    lookups: [LookupTarget]
  ) -> ChargingItemMatch? {
    items.compactMap { item -> ChargingItemMatch? in
      guard let distance = lookups.compactMap({
        secureMatchDistance(item: item, lookup: $0)
      }).min() else {
        return nil
      }
      return ChargingItemMatch(item: item, distance: distance)
    }
    .min {
      if $0.distance != $1.distance {
        return $0.distance < $1.distance
      }
      return mapItemStableKey($0.item) < mapItemStableKey($1.item)
    }
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
    let addressTokens = Set(appleAddress.split(separator: " ").map(String.init))
    let streetMatches = street.map(appleAddress.contains) ?? false
    let houseNumberMatches = houseNumber.map(addressTokens.contains) ?? false
    let localityMatches = (postalCode.map(addressTokens.contains) ?? false)
      || (city.map(appleAddress.contains) ?? false)
    return streetMatches && houseNumberMatches && localityMatches
  }

  private func lookupTargets(
    for park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup]
  ) -> [LookupTarget] {
    let requestedOperatorKey = operatorKey(operatorName)
    let matchingLookups = relatedLocations.filter {
      operatorKey($0.operatorName) == requestedOperatorKey
    }
    if !matchingLookups.isEmpty {
      return matchingLookups.map {
        LookupTarget(
          operatorName: $0.operatorName,
          coordinate: $0.coordinate,
          address: $0.address
        )
      }
    }
    return [
      LookupTarget(
        operatorName: operatorName,
        coordinate: park.navigationCoordinate,
        address: ChargingLocationAddress()
      )
    ]
  }

  private func mapItemStableKey(_ item: MKMapItem) -> String {
    let location = mapItemLocation(item)
    return item.identifier?.rawValue
      ?? "\(normalized(item.name ?? "")):\(location?.coordinate.latitude ?? 0):\(location?.coordinate.longitude ?? 0)"
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

enum AppleChargingPlaceLookupScope {
  static func relatedLocations(
    primaryLocations: [ChargingLocationLookup],
    candidateLocations: [ChargingLocationLookup],
    operatorName: String
  ) -> [ChargingLocationLookup] {
    let primaryOperatorLocations = primaryLocations.filter {
      $0.operatorName == operatorName
    }
    let primaryAddressKeys = Set(primaryOperatorLocations.compactMap {
      addressKey($0.address)
    })
    guard !primaryAddressKeys.isEmpty else {
      return primaryOperatorLocations
    }

    var seenLocationIDs = Set<UUID>()
    return (primaryOperatorLocations + candidateLocations.filter {
      $0.operatorName == operatorName
        && addressKey($0.address).map(primaryAddressKeys.contains) == true
    }).filter {
      seenLocationIDs.insert($0.id).inserted
    }
  }

  static func addressKey(_ address: ChargingLocationAddress) -> String? {
    guard let street = normalized(address.street),
      let houseNumber = normalized(address.houseNumber),
      let postalCode = normalized(address.postalCode),
      let city = normalized(address.city)
    else {
      return nil
    }
    return "\(street)|\(houseNumber)|\(postalCode)|\(city)"
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let result = value
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
    return result.isEmpty ? nil : result
  }
}

private struct LookupTarget {
  let operatorName: String
  let coordinate: Coordinate
  let address: ChargingLocationAddress
}

private struct ChargingItemMatch {
  let item: MKMapItem
  let distance: CLLocationDistance
}
