import CoreLocation
import MapKit
import NextStopCore

enum AppleChargingPlaceMatchPolicy {
  static let maximumDirectDistanceMeters: Double = 60
  static let maximumExactAddressDistanceMeters: Double = 300

  enum Scope: Hashable {
    case operatorOnly
    case noFoodCampus
  }

  enum Match: Equatable {
    case operatorScoped(distanceMeters: Double)
    case campus(distanceMeters: Double, stablePlaceIdentifier: String)
  }

  struct Evidence: Equatable {
    let operatorNameMatches: Bool
    let canonicalOperatorNameMatches: Bool
    let operatorScopedDistanceMeters: Double?
    let hasExactOperatorAddressMatch: Bool
    let isEVCharger: Bool
    let campusDistanceMeters: Double?
    let hasCampusLocalityMatch: Bool
    let stablePlaceIdentifier: String?
  }

  static func accepts(
    distanceMeters: Double,
    hasExactAddressMatch: Bool
  ) -> Bool {
    distanceMeters <= maximumDirectDistanceMeters
      || (hasExactAddressMatch && distanceMeters <= maximumExactAddressDistanceMeters)
  }

  static func match(
    evidence: Evidence,
    scope: Scope
  ) -> Match? {
    guard evidence.isEVCharger else {
      return nil
    }
    if evidence.operatorNameMatches,
      let distance = evidence.operatorScopedDistanceMeters,
      accepts(
        distanceMeters: distance,
        hasExactAddressMatch: evidence.hasExactOperatorAddressMatch
      )
    {
      return .operatorScoped(distanceMeters: distance)
    }
    guard scope == .noFoodCampus,
      evidence.canonicalOperatorNameMatches,
      let distance = evidence.campusDistanceMeters,
      distance <= maximumDirectDistanceMeters,
      evidence.hasCampusLocalityMatch,
      let identifier = evidence.stablePlaceIdentifier,
      !identifier.isEmpty
    else {
      return nil
    }
    return .campus(
      distanceMeters: distance,
      stablePlaceIdentifier: identifier
    )
  }

  static func unambiguousCampusPlaceIdentifier(
    in matches: [Match]
  ) -> String? {
    let identifiers = Set(
      matches.compactMap { match -> String? in
        guard case .campus(_, let identifier) = match else {
          return nil
        }
        return identifier
      })
    guard identifiers.count == 1 else {
      return nil
    }
    return identifiers.first
  }
}

enum AppleChargingPlaceSearchQuery {
  static func naturalLanguageQuery(
    for operatorName: String,
    scope: AppleChargingPlaceMatchPolicy.Scope,
    hasSecureCategoryMatch: Bool
  ) -> String? {
    guard scope == .noFoodCampus, !hasSecureCategoryMatch else {
      return nil
    }
    let query = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? nil : query
  }
}

@MainActor
protocol ApplePlaceResolving {
  func resolveChargingPlace(
    park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup],
    campusLocations: [ChargingLocationLookup],
    matchScope: AppleChargingPlaceMatchPolicy.Scope
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
    relatedLocations: [ChargingLocationLookup],
    campusLocations: [ChargingLocationLookup],
    matchScope: AppleChargingPlaceMatchPolicy.Scope
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
      parkID: park.id,
      operatorName: operatorName,
      lookups: lookups,
      matchScope: matchScope
    )
    if let cacheKey, let cachedItem = chargingPlaceCache[cacheKey] {
      return cachedItem
    }

    let campusLookups =
      matchScope == .noFoodCampus
      ? campusLocations.map(LookupTarget.init)
      : []
    let centers = chargingSearchCenters(
      around: park,
      lookups: lookups
    )
    var campusMatches: [ChargingItemMatch] = []

    for center in centers {
      guard let items = try? await searchChargingItems(around: center) else {
        continue
      }
      let matches = chargingMatches(
        items: items,
        operatorName: operatorName,
        lookups: lookups,
        campusLookups: campusLookups,
        matchScope: matchScope
      )
      if let operatorMatch = bestOperatorScopedMatch(in: matches) {
        if let cacheKey {
          chargingPlaceCache[cacheKey] = operatorMatch.item
        }
        return operatorMatch.item
      }
      campusMatches.append(contentsOf: matches.filter(\.isCampusMatch))
    }

    if let campusMatch = unambiguousCampusMatch(in: campusMatches) {
      if let cacheKey {
        chargingPlaceCache[cacheKey] = campusMatch.item
      }
      return campusMatch.item
    }

    if let query = AppleChargingPlaceSearchQuery.naturalLanguageQuery(
      for: operatorName,
      scope: matchScope,
      hasSecureCategoryMatch: false
    ) {
      for center in centers {
        guard
          let items = try? await searchChargingItems(
            around: center,
            naturalLanguageQuery: query
          )
        else {
          continue
        }
        let matches = chargingMatches(
          items: items,
          operatorName: operatorName,
          lookups: lookups,
          campusLookups: campusLookups,
          matchScope: matchScope
        )
        if let operatorMatch = bestOperatorScopedMatch(in: matches) {
          if let cacheKey {
            chargingPlaceCache[cacheKey] = operatorMatch.item
          }
          return operatorMatch.item
        }
        campusMatches.append(contentsOf: matches.filter(\.isCampusMatch))
      }
    }

    guard let campusMatch = unambiguousCampusMatch(in: campusMatches) else {
      return nil
    }
    if let cacheKey {
      chargingPlaceCache[cacheKey] = campusMatch.item
    }
    return campusMatch.item
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

  private func searchChargingItems(
    around center: CLLocationCoordinate2D,
    naturalLanguageQuery: String
  ) async throws -> [MKMapItem] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = naturalLanguageQuery
    request.region = MKCoordinateRegion(
      center: center,
      latitudinalMeters: AppleChargingPlaceMatchPolicy.maximumExactAddressDistanceMeters * 2,
      longitudinalMeters: AppleChargingPlaceMatchPolicy.maximumExactAddressDistanceMeters * 2
    )
    request.resultTypes = .pointOfInterest
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
    return try await MKLocalSearch(request: request).start().mapItems
  }

  private func chargingSearchCenters(
    around park: ChargingPark,
    lookups: [LookupTarget]
  ) -> [CLLocationCoordinate2D] {
    let candidates =
      [park.navigationCoordinate]
      + lookups.map(\.coordinate)
    var centers: [CLLocationCoordinate2D] = []
    for candidate in candidates {
      let coordinate = CLLocationCoordinate2D(
        latitude: candidate.latitude,
        longitude: candidate.longitude
      )
      let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
      let alreadyCovered = centers.contains {
        location.distance(
          from: CLLocation(
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
    parkID: UUID,
    operatorName: String,
    lookups: [LookupTarget],
    matchScope: AppleChargingPlaceMatchPolicy.Scope
  ) -> String? {
    let addressKeys = Set(
      lookups.compactMap {
        AppleChargingPlaceLookupScope.addressKey($0.address)
      })
    if matchScope == .noFoodCampus {
      return
        "campus:\(parkID.uuidString.lowercased())|\(operatorKey(operatorName))|\(addressKeys.sorted().joined(separator: ";"))"
    }
    guard !addressKeys.isEmpty else {
      return nil
    }
    return "operator:\(operatorKey(operatorName))|\(addressKeys.sorted().joined(separator: ";"))"
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
        let distance = itemLocation.distance(
          from: CLLocation(
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

  private func operatorScopedEvidence(
    item: MKMapItem,
    lookup: LookupTarget
  ) -> (distance: CLLocationDistance, hasExactAddressMatch: Bool)? {
    guard let itemLocation = mapItemLocation(item) else {
      return nil
    }
    let distance = itemLocation.distance(
      from: CLLocation(
        latitude: lookup.coordinate.latitude,
        longitude: lookup.coordinate.longitude
      ))
    return (
      distance: distance,
      hasExactAddressMatch: addressMatches(item: item, lookup: lookup)
    )
  }

  private func chargingMatches(
    items: [MKMapItem],
    operatorName: String,
    lookups: [LookupTarget],
    campusLookups: [LookupTarget],
    matchScope: AppleChargingPlaceMatchPolicy.Scope
  ) -> [ChargingItemMatch] {
    items.compactMap { item -> ChargingItemMatch? in
      let operatorEvidence = lookups.compactMap {
        operatorScopedEvidence(item: item, lookup: $0)
      }
      .filter {
        AppleChargingPlaceMatchPolicy.accepts(
          distanceMeters: $0.distance,
          hasExactAddressMatch: $0.hasExactAddressMatch
        )
      }
      .min { $0.distance < $1.distance }
      let campusDistance = campusLookups.compactMap {
        distance(from: item, to: $0)
      }.min()
      let match = AppleChargingPlaceMatchPolicy.match(
        evidence: AppleChargingPlaceMatchPolicy.Evidence(
          operatorNameMatches: operatorMatches(item.name ?? "", operatorName),
          canonicalOperatorNameMatches: operatorKey(item.name ?? "")
            == operatorKey(operatorName),
          operatorScopedDistanceMeters: operatorEvidence?.distance,
          hasExactOperatorAddressMatch: operatorEvidence?.hasExactAddressMatch ?? false,
          isEVCharger: item.pointOfInterestCategory == .evCharger,
          campusDistanceMeters: campusDistance,
          hasCampusLocalityMatch: AppleChargingPlaceLookupScope.localityMatches(
            mapItemAddress(item),
            referenceAddresses: lookups.map(\.address)
          ),
          stablePlaceIdentifier: item.identifier?.rawValue
        ),
        scope: matchScope
      )
      guard let match else {
        return nil
      }
      return ChargingItemMatch(item: item, match: match)
    }
  }

  private func bestOperatorScopedMatch(
    in matches: [ChargingItemMatch]
  ) -> ChargingItemMatch? {
    matches.filter(\.isOperatorScopedMatch).min {
      if $0.distance != $1.distance {
        return $0.distance < $1.distance
      }
      return mapItemStableKey($0.item) < mapItemStableKey($1.item)
    }
  }

  private func unambiguousCampusMatch(
    in matches: [ChargingItemMatch]
  ) -> ChargingItemMatch? {
    guard
      let identifier = AppleChargingPlaceMatchPolicy.unambiguousCampusPlaceIdentifier(
        in: matches.map(\.match)
      )
    else {
      return nil
    }
    return matches.filter { $0.stablePlaceIdentifier == identifier }.min {
      if $0.distance != $1.distance {
        return $0.distance < $1.distance
      }
      return mapItemStableKey($0.item) < mapItemStableKey($1.item)
    }
  }

  private func distance(
    from item: MKMapItem,
    to lookup: LookupTarget
  ) -> CLLocationDistance? {
    guard let itemLocation = mapItemLocation(item) else {
      return nil
    }
    return itemLocation.distance(
      from: CLLocation(
        latitude: lookup.coordinate.latitude,
        longitude: lookup.coordinate.longitude
      ))
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
    let localityMatches =
      (postalCode.map(addressTokens.contains) ?? false)
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
  static func restaurantGroupLocations(
    candidateLocations: [ChargingLocationLookup],
    operatorName: String
  ) -> [ChargingLocationLookup] {
    var seenLocationIDs = Set<UUID>()
    return candidateLocations.filter {
      $0.operatorName == operatorName && seenLocationIDs.insert($0.id).inserted
    }
  }

  static func relatedLocations(
    primaryLocations: [ChargingLocationLookup],
    candidateLocations: [ChargingLocationLookup],
    operatorName: String
  ) -> [ChargingLocationLookup] {
    let primaryOperatorLocations = primaryLocations.filter {
      $0.operatorName == operatorName
    }
    let primaryAddressKeys = Set(
      primaryOperatorLocations.compactMap {
        addressKey($0.address)
      })
    guard !primaryAddressKeys.isEmpty else {
      return primaryOperatorLocations
    }

    var seenLocationIDs = Set<UUID>()
    return
      (primaryOperatorLocations
      + candidateLocations.filter {
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

  static func localityMatches(
    _ candidateAddress: String?,
    referenceAddresses: [ChargingLocationAddress]
  ) -> Bool {
    guard let candidateAddress = normalized(candidateAddress) else {
      return false
    }
    let candidateTokens = Set(candidateAddress.split(separator: " ").map(String.init))
    let paddedCandidateAddress = " \(candidateAddress) "
    return referenceAddresses.contains { address in
      let postalCodeMatches =
        normalized(address.postalCode)
        .map(candidateTokens.contains) ?? false
      let cityMatches =
        normalized(address.city)
        .map { paddedCandidateAddress.contains(" \($0) ") } ?? false
      return postalCodeMatches || cityMatches
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let result =
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
    return result.isEmpty ? nil : result
  }
}

private struct LookupTarget {
  let operatorName: String
  let coordinate: Coordinate
  let address: ChargingLocationAddress

  init(
    operatorName: String,
    coordinate: Coordinate,
    address: ChargingLocationAddress
  ) {
    self.operatorName = operatorName
    self.coordinate = coordinate
    self.address = address
  }

  init(_ lookup: ChargingLocationLookup) {
    self.init(
      operatorName: lookup.operatorName,
      coordinate: lookup.coordinate,
      address: lookup.address
    )
  }
}

private struct ChargingItemMatch {
  let item: MKMapItem
  let match: AppleChargingPlaceMatchPolicy.Match

  var distance: CLLocationDistance {
    switch match {
    case .operatorScoped(let distance), .campus(let distance, _):
      return distance
    }
  }

  var isOperatorScopedMatch: Bool {
    if case .operatorScoped = match {
      return true
    }
    return false
  }

  var isCampusMatch: Bool {
    if case .campus = match {
      return true
    }
    return false
  }

  var stablePlaceIdentifier: String? {
    guard case .campus(_, let identifier) = match else {
      return nil
    }
    return identifier
  }
}
