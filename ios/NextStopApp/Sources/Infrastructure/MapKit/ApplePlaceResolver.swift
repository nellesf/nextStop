import CoreLocation
import MapKit
import NextStopCore

struct AppleChargingPlaceResultGroup: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case noFoodCampus
    case restaurant
  }

  let id: String
  let kind: Kind
  let evidenceLocations: [ChargingLocationLookup]
  let searchCoordinates: [Coordinate]
  let restaurantCoordinate: Coordinate?
}

enum AppleChargingPlaceSearchCenterPolicy {
  static let minimumSeparationMeters: CLLocationDistance = 75

  static func centers(
    parkNavigationCoordinate: Coordinate,
    operatorCoordinates: [Coordinate],
    resultGroupCoordinates: [Coordinate]
  ) -> [Coordinate] {
    let candidates =
      [parkNavigationCoordinate]
      + operatorCoordinates
      + resultGroupCoordinates
    var centers: [Coordinate] = []
    for candidate in candidates {
      let location = CLLocation(
        latitude: candidate.latitude,
        longitude: candidate.longitude
      )
      let alreadyCovered = centers.contains {
        location.distance(
          from: CLLocation(
            latitude: $0.latitude,
            longitude: $0.longitude
          )) < minimumSeparationMeters
      }
      if !alreadyCovered {
        centers.append(candidate)
      }
    }
    return centers
  }
}

enum AppleChargingPlaceSearchCompletionPolicy {
  static func allowsResultGroupFallback(
    categoryPassComplete: Bool,
    naturalLanguagePassComplete: Bool? = nil
  ) -> Bool {
    guard categoryPassComplete else {
      return false
    }
    return naturalLanguagePassComplete ?? true
  }
}

enum AppleChargingPlaceMatchPolicy {
  static let maximumDirectDistanceMeters: Double = 60
  static let maximumExactAddressDistanceMeters: Double = 300
  static let maximumRestaurantDistanceMeters = Double(
    SearchConfiguration.maximumFoodDistance.value
  )

  enum Match: Equatable {
    case operatorScoped(distanceMeters: Double)
    case resultGroup(distanceMeters: Double, stablePlaceIdentifier: String)
  }

  struct Evidence: Equatable {
    let operatorNameMatches: Bool
    let canonicalOperatorNameMatches: Bool
    let operatorScopedDistanceMeters: Double?
    let hasExactOperatorAddressMatch: Bool
    let isEVCharger: Bool
    let resultGroupDistanceMeters: Double?
    let hasOperatorLocalityMatch: Bool
    let restaurantDistanceMeters: Double?
    let stablePlaceIdentifier: String?
  }

  static func accepts(
    distanceMeters: Double,
    hasExactAddressMatch: Bool
  ) -> Bool {
    distanceMeters <= maximumDirectDistanceMeters
      || (hasExactAddressMatch && distanceMeters <= maximumExactAddressDistanceMeters)
  }

  static func canonicalOperatorKeysMatch(_ first: String, _ second: String) -> Bool {
    !first.isEmpty && !second.isEmpty && first == second
  }

  static func match(
    evidence: Evidence,
    resultGroupKind: AppleChargingPlaceResultGroup.Kind
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
    guard evidence.canonicalOperatorNameMatches,
      let distance = evidence.resultGroupDistanceMeters,
      distance <= maximumDirectDistanceMeters,
      evidence.hasOperatorLocalityMatch,
      let identifier = evidence.stablePlaceIdentifier,
      !identifier.isEmpty
    else {
      return nil
    }
    if resultGroupKind == .restaurant {
      guard let restaurantDistance = evidence.restaurantDistanceMeters,
        restaurantDistance <= maximumRestaurantDistanceMeters
      else {
        return nil
      }
    }
    return .resultGroup(
      distanceMeters: distance,
      stablePlaceIdentifier: identifier
    )
  }

  static func unambiguousResultGroupPlaceIdentifier(
    in matches: [Match]
  ) -> String? {
    let identifiers = resultGroupPlaceIdentifiers(in: matches)
    guard identifiers.count == 1 else {
      return nil
    }
    return identifiers.first
  }

  static func naturalLanguageFallbackPlaceIdentifier(
    categoryMatches: [Match],
    naturalLanguageMatches: [Match],
    categoryPassComplete: Bool,
    naturalLanguagePassComplete: Bool
  ) -> String? {
    guard
      AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
        categoryPassComplete: categoryPassComplete,
        naturalLanguagePassComplete: naturalLanguagePassComplete
      )
    else {
      return nil
    }

    let categoryIdentifiers = resultGroupPlaceIdentifiers(in: categoryMatches)
    let naturalLanguageIdentifiers = resultGroupPlaceIdentifiers(
      in: naturalLanguageMatches
    )
    let eligibleIdentifiers =
      categoryIdentifiers.isEmpty
      ? naturalLanguageIdentifiers
      : categoryIdentifiers.intersection(naturalLanguageIdentifiers)
    guard eligibleIdentifiers.count == 1 else {
      return nil
    }
    return eligibleIdentifiers.first
  }

  private static func resultGroupPlaceIdentifiers(
    in matches: [Match]
  ) -> Set<String> {
    Set(
      matches.compactMap { match -> String? in
        guard case .resultGroup(_, let identifier) = match else {
          return nil
        }
        return identifier
      })
  }
}

enum AppleChargingPlaceSearchQuery {
  static func naturalLanguageQuery(
    for operatorName: String,
    hasSecureCategoryMatch: Bool
  ) -> String? {
    guard !hasSecureCategoryMatch else {
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
    resultGroup: AppleChargingPlaceResultGroup
  ) async -> MKMapItem?

  func resolveRestaurantPlace(_ foodPOI: FoodPOI) async -> MKMapItem?
}

@MainActor
final class MapKitApplePlaceResolver: ApplePlaceResolving {
  private let maximumRestaurantMatchDistance: CLLocationDistance = 125
  private var chargingPlaceCache: [String: MKMapItem] = [:]

  func resolveChargingPlace(
    park: ChargingPark,
    operatorName: String,
    relatedLocations: [ChargingLocationLookup],
    resultGroup: AppleChargingPlaceResultGroup
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
      resultGroup: resultGroup,
      operatorName: operatorName,
      lookups: lookups
    )
    if let cacheKey, let cachedItem = chargingPlaceCache[cacheKey] {
      return cachedItem
    }

    let resultGroupLookups = resultGroup.evidenceLocations.map(LookupTarget.init)
    let centers = chargingSearchCenters(
      around: park,
      lookups: lookups,
      resultGroupCoordinates: resultGroup.searchCoordinates
    )
    var categoryResultGroupMatches: [ChargingItemMatch] = []
    var categoryPassComplete = true

    for center in centers {
      let items: [MKMapItem]
      do {
        items = try await searchChargingItems(around: center)
      } catch {
        categoryPassComplete = false
        continue
      }
      let matches = chargingMatches(
        items: items,
        operatorName: operatorName,
        lookups: lookups,
        resultGroupLookups: resultGroupLookups,
        resultGroup: resultGroup
      )
      if let operatorMatch = bestOperatorScopedMatch(in: matches) {
        if let cacheKey {
          chargingPlaceCache[cacheKey] = operatorMatch.item
        }
        return operatorMatch.item
      }
      categoryResultGroupMatches.append(
        contentsOf: matches.filter(\.isResultGroupMatch)
      )
    }

    if AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
      categoryPassComplete: categoryPassComplete
    ),
      let resultGroupMatch = unambiguousResultGroupMatch(
        in: categoryResultGroupMatches
      )
    {
      if let cacheKey {
        chargingPlaceCache[cacheKey] = resultGroupMatch.item
      }
      return resultGroupMatch.item
    }

    var naturalLanguageResultGroupMatches: [ChargingItemMatch] = []
    var naturalLanguagePassComplete = false
    if let query = AppleChargingPlaceSearchQuery.naturalLanguageQuery(
      for: operatorName,
      hasSecureCategoryMatch: false
    ) {
      naturalLanguagePassComplete = true
      for center in centers {
        let items: [MKMapItem]
        do {
          items = try await searchChargingItems(
            around: center,
            naturalLanguageQuery: query
          )
        } catch {
          naturalLanguagePassComplete = false
          continue
        }
        let matches = chargingMatches(
          items: items,
          operatorName: operatorName,
          lookups: lookups,
          resultGroupLookups: resultGroupLookups,
          resultGroup: resultGroup
        )
        if let operatorMatch = bestOperatorScopedMatch(in: matches) {
          if let cacheKey {
            chargingPlaceCache[cacheKey] = operatorMatch.item
          }
          return operatorMatch.item
        }
        naturalLanguageResultGroupMatches.append(
          contentsOf: matches.filter(\.isResultGroupMatch)
        )
      }
    }

    guard
      let identifier =
        AppleChargingPlaceMatchPolicy
        .naturalLanguageFallbackPlaceIdentifier(
          categoryMatches: categoryResultGroupMatches.map(\.match),
          naturalLanguageMatches: naturalLanguageResultGroupMatches.map(\.match),
          categoryPassComplete: categoryPassComplete,
          naturalLanguagePassComplete: naturalLanguagePassComplete
        ),
      let resultGroupMatch = bestResultGroupMatch(
        withStablePlaceIdentifier: identifier,
        in: categoryResultGroupMatches + naturalLanguageResultGroupMatches
      )
    else {
      return nil
    }
    if let cacheKey {
      chargingPlaceCache[cacheKey] = resultGroupMatch.item
    }
    return resultGroupMatch.item
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
    lookups: [LookupTarget],
    resultGroupCoordinates: [Coordinate]
  ) -> [CLLocationCoordinate2D] {
    AppleChargingPlaceSearchCenterPolicy.centers(
      parkNavigationCoordinate: park.navigationCoordinate,
      operatorCoordinates: lookups.map(\.coordinate),
      resultGroupCoordinates: resultGroupCoordinates
    ).map {
      CLLocationCoordinate2D(
        latitude: $0.latitude,
        longitude: $0.longitude
      )
    }
  }

  private func chargingPlaceCacheKey(
    resultGroup: AppleChargingPlaceResultGroup,
    operatorName: String,
    lookups: [LookupTarget]
  ) -> String? {
    let addressEvidenceSignatures = Set(
      lookups.map {
        AppleChargingPlaceLookupScope.addressEvidenceSignature($0.address)
      })
    let lookupLocationIDs = Set(
      lookups.compactMap { $0.id?.uuidString.lowercased() }
    )
    let lookupCoordinateSignatures = Set(
      lookups.map { coordinateSignature($0.coordinate) }
    )
    let evidenceLocationIDs = Set(
      resultGroup.evidenceLocations.map { $0.id.uuidString.lowercased() }
    )
    let evidenceCoordinateSignatures = Set(
      resultGroup.evidenceLocations.map {
        coordinateSignature($0.coordinate)
      }
    )
    let searchCoordinateSignatures = Set(
      resultGroup.searchCoordinates.map(coordinateSignature)
    )
    let restaurantCoordinateSignature =
      resultGroup.restaurantCoordinate
      .map(coordinateSignature) ?? "none"
    return [
      "group:\(resultGroup.id)",
      "kind:\(resultGroup.kind)",
      "operator:\(normalized(operatorName))",
      "lookup-ids:\(lookupLocationIDs.sorted().joined(separator: ";"))",
      "lookup-coordinates:\(lookupCoordinateSignatures.sorted().joined(separator: ";"))",
      "evidence-ids:\(evidenceLocationIDs.sorted().joined(separator: ";"))",
      "evidence-coordinates:\(evidenceCoordinateSignatures.sorted().joined(separator: ";"))",
      "search-coordinates:\(searchCoordinateSignatures.sorted().joined(separator: ";"))",
      "restaurant:\(restaurantCoordinateSignature)",
      "addresses:\(addressEvidenceSignatures.sorted().joined(separator: ";"))",
    ].joined(separator: "|")
  }

  private func coordinateSignature(_ coordinate: Coordinate) -> String {
    "\(coordinate.latitude),\(coordinate.longitude)"
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
    resultGroupLookups: [LookupTarget],
    resultGroup: AppleChargingPlaceResultGroup
  ) -> [ChargingItemMatch] {
    let requestedOperatorKey = operatorKey(operatorName)
    return items.compactMap { item -> ChargingItemMatch? in
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
      let resultGroupDistance = resultGroupLookups.compactMap {
        distance(from: item, to: $0)
      }.min()
      let restaurantDistance = resultGroup.restaurantCoordinate.flatMap {
        distance(from: item, to: $0)
      }
      let match = AppleChargingPlaceMatchPolicy.match(
        evidence: AppleChargingPlaceMatchPolicy.Evidence(
          operatorNameMatches: operatorMatches(item.name ?? "", operatorName),
          canonicalOperatorNameMatches:
            AppleChargingPlaceMatchPolicy
            .canonicalOperatorKeysMatch(
              operatorKey(item.name ?? ""),
              requestedOperatorKey
            ),
          operatorScopedDistanceMeters: operatorEvidence?.distance,
          hasExactOperatorAddressMatch: operatorEvidence?.hasExactAddressMatch ?? false,
          isEVCharger: item.pointOfInterestCategory == .evCharger,
          resultGroupDistanceMeters: resultGroupDistance,
          hasOperatorLocalityMatch: AppleChargingPlaceLookupScope.localityMatches(
            mapItemAddress(item),
            referenceAddresses: lookups.map(\.address)
          ),
          restaurantDistanceMeters: restaurantDistance,
          stablePlaceIdentifier: item.identifier?.rawValue
        ),
        resultGroupKind: resultGroup.kind
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

  private func unambiguousResultGroupMatch(
    in matches: [ChargingItemMatch]
  ) -> ChargingItemMatch? {
    guard
      let identifier = AppleChargingPlaceMatchPolicy.unambiguousResultGroupPlaceIdentifier(
        in: matches.map(\.match)
      )
    else {
      return nil
    }
    return bestResultGroupMatch(
      withStablePlaceIdentifier: identifier,
      in: matches
    )
  }

  private func bestResultGroupMatch(
    withStablePlaceIdentifier identifier: String,
    in matches: [ChargingItemMatch]
  ) -> ChargingItemMatch? {
    matches.filter { $0.stablePlaceIdentifier == identifier }.min {
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
    let addressTokens = Set(appleAddress.split(separator: " ").map(String.init))
    let streetMatches = street.map(appleAddress.contains) ?? false
    let houseNumberMatches = houseNumber.map(addressTokens.contains) ?? false
    let localityMatches = AppleChargingPlaceLookupScope.localityMatches(
      mapItemAddress(item),
      referenceAddresses: [lookup.address]
    )
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
          id: $0.id,
          operatorName: $0.operatorName,
          coordinate: $0.coordinate,
          address: $0.address
        )
      }
    }
    return [
      LookupTarget(
        id: nil,
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

  private func distance(
    from item: MKMapItem,
    to coordinate: Coordinate
  ) -> CLLocationDistance? {
    guard let itemLocation = mapItemLocation(item) else {
      return nil
    }
    return itemLocation.distance(
      from: CLLocation(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      ))
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

  static func addressEvidenceSignature(_ address: ChargingLocationAddress) -> String {
    [
      normalized(address.street) ?? "-",
      normalized(address.houseNumber) ?? "-",
      normalized(address.postalCode) ?? "-",
      normalized(address.city) ?? "-",
    ].joined(separator: "|")
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
  let id: UUID?
  let operatorName: String
  let coordinate: Coordinate
  let address: ChargingLocationAddress

  init(
    id: UUID?,
    operatorName: String,
    coordinate: Coordinate,
    address: ChargingLocationAddress
  ) {
    self.id = id
    self.operatorName = operatorName
    self.coordinate = coordinate
    self.address = address
  }

  init(_ lookup: ChargingLocationLookup) {
    self.init(
      id: lookup.id,
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
    case .operatorScoped(let distance), .resultGroup(let distance, _):
      return distance
    }
  }

  var isOperatorScopedMatch: Bool {
    if case .operatorScoped = match {
      return true
    }
    return false
  }

  var isResultGroupMatch: Bool {
    if case .resultGroup = match {
      return true
    }
    return false
  }

  var stablePlaceIdentifier: String? {
    guard case .resultGroup(_, let identifier) = match else {
      return nil
    }
    return identifier
  }
}
