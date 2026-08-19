import Foundation

public enum DataQualityTier: String, Codable, Sendable {
  case operatorData = "operator"
  case authority
  case openData = "open_data"
  case community
}

public struct DataSource: Identifiable, Hashable, Codable, Sendable {
  public let id: String
  public let name: String
  public let qualityTier: DataQualityTier
  public let attribution: String?

  public init(
    id: String,
    name: String,
    qualityTier: DataQualityTier,
    attribution: String? = nil
  ) throws {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptySourceIdentifier
    }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    self.id = id
    self.name = name
    self.qualityTier = qualityTier
    self.attribution = attribution
  }
}

public struct DataSourceReference: Hashable, Codable, Sendable {
  public let sourceID: String
  public let sourceRecordID: String
  public let qualityTier: DataQualityTier
  public let observedAt: Date?
  public let fetchedAt: Date

  public init(
    sourceID: String,
    sourceRecordID: String,
    qualityTier: DataQualityTier,
    observedAt: Date?,
    fetchedAt: Date
  ) throws {
    guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sourceRecordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DomainValidationError.emptySourceIdentifier
    }
    self.sourceID = sourceID
    self.sourceRecordID = sourceRecordID
    self.qualityTier = qualityTier
    self.observedAt = observedAt
    self.fetchedAt = fetchedAt
  }
}

public struct Operator: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let canonicalName: String
  public let aliases: Set<String>

  public init(id: UUID, canonicalName: String, aliases: Set<String> = []) throws {
    guard !canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    self.id = id
    self.canonicalName = canonicalName
    self.aliases = aliases
  }
}

public struct ChargingConnector: Identifiable, Hashable, Codable, Sendable {
  public let id: String
  public let standard: String?
  public let currentType: String?
  public let maximumPower: Kilowatts?

  public init(
    id: String,
    standard: String? = nil,
    currentType: String? = nil,
    maximumPower: Kilowatts? = nil
  ) throws {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptySourceIdentifier
    }
    self.id = id
    self.standard = standard
    self.currentType = currentType
    self.maximumPower = maximumPower
  }
}

public struct PowerCapability: Hashable, Codable, Sendable {
  public let maximumPower: Kilowatts
  public let chargingPointCountAtOrAbovePower: Int?

  public init(maximumPower: Kilowatts, chargingPointCountAtOrAbovePower: Int? = nil) {
    if let chargingPointCountAtOrAbovePower {
      precondition(chargingPointCountAtOrAbovePower >= 0)
    }
    self.maximumPower = maximumPower
    self.chargingPointCountAtOrAbovePower = chargingPointCountAtOrAbovePower
  }
}

public struct ChargingPoint: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let canonicalEVSEIdentity: String?
  public let locationID: UUID
  public let operatorID: UUID?
  public let connectors: [ChargingConnector]
  public let availability: Availability
  public let powerCapability: PowerCapability
  public let sourceReferences: [DataSourceReference]

  public init(
    id: UUID,
    canonicalEVSEIdentity: String?,
    locationID: UUID,
    operatorID: UUID?,
    connectors: [ChargingConnector],
    availability: Availability,
    powerCapability: PowerCapability,
    sourceReferences: [DataSourceReference]
  ) {
    self.id = id
    self.canonicalEVSEIdentity = canonicalEVSEIdentity
    self.locationID = locationID
    self.operatorID = operatorID
    self.connectors = connectors
    self.availability = availability
    self.powerCapability = powerCapability
    self.sourceReferences = sourceReferences
  }
}

public struct ChargingLocation: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let name: String?
  public let coordinate: Coordinate
  public let accessCoordinate: Coordinate?
  public let operatorIDs: Set<UUID>
  public let chargingPointIDs: Set<UUID>
  public let sourceReferences: [DataSourceReference]

  public init(
    id: UUID,
    name: String?,
    coordinate: Coordinate,
    accessCoordinate: Coordinate?,
    operatorIDs: Set<UUID>,
    chargingPointIDs: Set<UUID>,
    sourceReferences: [DataSourceReference]
  ) {
    self.id = id
    self.name = name
    self.coordinate = coordinate
    self.accessCoordinate = accessCoordinate
    self.operatorIDs = operatorIDs
    self.chargingPointIDs = chargingPointIDs
    self.sourceReferences = sourceReferences
  }
}

public enum OpeningStatus: String, Codable, Sendable {
  case open
  case closed
  case unknown
}

public struct FoodPOI: Hashable, Codable, Sendable {
  public let id: String
  public let applePlaceIdentifier: String?
  public let chain: FoodChain
  public let name: String
  public let coordinate: Coordinate
  public let distanceFromPark: Meters
  public let openingStatus: OpeningStatus

  public init(
    id: String,
    applePlaceIdentifier: String? = nil,
    chain: FoodChain,
    name: String,
    coordinate: Coordinate,
    distanceFromPark: Meters,
    openingStatus: OpeningStatus
  ) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    self.id = id
    self.applePlaceIdentifier = applePlaceIdentifier
    self.chain = chain
    self.name = name
    self.coordinate = coordinate
    self.distanceFromPark = distanceFromPark
    self.openingStatus = openingStatus
  }
}

public struct OperatorChargingPointSummary: Identifiable, Hashable, Codable, Sendable {
  public var id: String { name }

  public let name: String
  public let chargingPointCount: Int

  public init(name: String, chargingPointCount: Int) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    guard chargingPointCount > 0 else {
      throw DomainValidationError.nonPositiveChargingPointCount(chargingPointCount)
    }
    self.name = name
    self.chargingPointCount = chargingPointCount
  }
}

public struct ChargingLocationAddress: Hashable, Codable, Sendable {
  public let street: String?
  public let houseNumber: String?
  public let postalCode: String?
  public let city: String?

  public init(
    street: String? = nil,
    houseNumber: String? = nil,
    postalCode: String? = nil,
    city: String? = nil
  ) {
    self.street = street
    self.houseNumber = houseNumber
    self.postalCode = postalCode
    self.city = city
  }
}

public struct ChargingLocationLookup: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let operatorName: String
  public let coordinate: Coordinate
  public let address: ChargingLocationAddress

  public init(
    id: UUID,
    operatorName: String,
    coordinate: Coordinate,
    address: ChargingLocationAddress
  ) throws {
    guard !operatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    self.id = id
    self.operatorName = operatorName
    self.coordinate = coordinate
    self.address = address
  }
}

public struct ChargingPark: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let name: String
  public let coordinate: Coordinate
  public let navigationCoordinate: Coordinate
  public let operatorChargingPoints: [OperatorChargingPointSummary]
  public let chargingPointCount: Int
  public let availability: ParkAvailability
  public let maximumPower: Kilowatts
  public let sourceReferences: [DataSourceReference]
  public let locationLookups: [ChargingLocationLookup]

  public init(
    id: UUID,
    name: String,
    coordinate: Coordinate,
    navigationCoordinate: Coordinate,
    operatorChargingPoints: [OperatorChargingPointSummary],
    chargingPointCount: Int,
    availability: ParkAvailability,
    maximumPower: Kilowatts,
    sourceReferences: [DataSourceReference],
    locationLookups: [ChargingLocationLookup] = []
  ) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DomainValidationError.emptyName
    }
    guard chargingPointCount == availability.totalCount else {
      throw DomainValidationError.availabilityTotalMismatch(
        expected: chargingPointCount,
        actual: availability.totalCount
      )
    }
    let uniqueOperatorNames = Set(operatorChargingPoints.map(\.name))
    guard !operatorChargingPoints.isEmpty,
      uniqueOperatorNames.count == operatorChargingPoints.count
    else {
      throw DomainValidationError.emptyName
    }
    let attributedChargingPointCount = operatorChargingPoints.reduce(0) {
      $0 + $1.chargingPointCount
    }
    guard attributedChargingPointCount == chargingPointCount else {
      throw DomainValidationError.operatorChargingPointTotalMismatch(
        expected: chargingPointCount,
        actual: attributedChargingPointCount
      )
    }
    let operatorNames = Set(operatorChargingPoints.map(\.name))
    if let invalidLookup = locationLookups.first(where: {
      !operatorNames.contains($0.operatorName)
    }) {
      throw DomainValidationError.locationLookupOperatorNotInPark(invalidLookup.operatorName)
    }
    self.id = id
    self.name = name
    self.coordinate = coordinate
    self.navigationCoordinate = navigationCoordinate
    self.operatorChargingPoints = operatorChargingPoints.sorted { $0.name < $1.name }
    self.chargingPointCount = chargingPointCount
    self.availability = availability
    self.maximumPower = maximumPower
    self.sourceReferences = sourceReferences
    self.locationLookups = locationLookups
  }
}

public struct EnrichedChargingParkCandidate: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID { park.id }

  public let park: ChargingPark
  public let distanceFromRoute: Meters
  public let actualDrivingDistance: Meters
  public let foodPOIs: [FoodPOI]

  public init(
    park: ChargingPark,
    distanceFromRoute: Meters,
    actualDrivingDistance: Meters,
    foodPOIs: [FoodPOI]
  ) {
    self.park = park
    self.distanceFromRoute = distanceFromRoute
    self.actualDrivingDistance = actualDrivingDistance
    self.foodPOIs = foodPOIs
  }
}

public struct RoutePolyline: Hashable, Codable, Sendable {
  public let coordinates: [Coordinate]

  public init(coordinates: [Coordinate]) throws {
    guard coordinates.count >= 2 else {
      throw DomainValidationError.routeRequiresAtLeastTwoCoordinates
    }
    guard coordinates.count <= SearchConfiguration.maximumRouteCoordinateCount else {
      throw DomainValidationError.routeHasTooManyCoordinates(
        maximum: SearchConfiguration.maximumRouteCoordinateCount,
        actual: coordinates.count
      )
    }
    guard Set(coordinates).count >= 2 else {
      throw DomainValidationError.routeRequiresDistinctCoordinates
    }
    self.coordinates = coordinates
  }
}

public struct RouteSearchRequest: Hashable, Codable, Sendable {
  public let requestID: UUID
  public let route: RoutePolyline
  public let criteria: RideCriteria
  public let snapshotToken: String?
  public let cursor: String?

  public init(
    requestID: UUID,
    route: RoutePolyline,
    criteria: RideCriteria,
    snapshotToken: String? = nil,
    cursor: String? = nil
  ) {
    self.requestID = requestID
    self.route = route
    self.criteria = criteria
    self.snapshotToken = snapshotToken
    self.cursor = cursor
  }
}

public struct RouteSearchResult: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID { candidate.id }

  public let candidate: EnrichedChargingParkCandidate
  public let relatedCandidates: [EnrichedChargingParkCandidate]
  public let matchingFoodPOI: FoodPOI?

  public var candidates: [EnrichedChargingParkCandidate] {
    [candidate] + relatedCandidates
  }

  public var chargingPointCount: Int {
    candidates.reduce(0) { $0 + $1.park.chargingPointCount }
  }

  public var operatorChargingPoints: [RouteSearchOperatorSummary] {
    var counts: [String: Int] = [:]
    for summary in candidates.flatMap(\.park.operatorChargingPoints) {
      counts[summary.name, default: 0] += summary.chargingPointCount
    }
    return counts.map {
      RouteSearchOperatorSummary(name: $0.key, chargingPointCount: $0.value)
    }
    .sorted { $0.name < $1.name }
  }

  public var locationLookups: [ChargingLocationLookup] {
    var seenIDs = Set<UUID>()
    return candidates.flatMap(\.park.locationLookups).filter {
      seenIDs.insert($0.id).inserted
    }
  }

  public var availability: ParkAvailability {
    let parkAvailability = candidates.map(\.park.availability)
    return
      (try? ParkAvailability(
        knownAvailableCount: parkAvailability.reduce(0) { $0 + $1.knownAvailableCount },
        knownUnavailableCount: parkAvailability.reduce(0) { $0 + $1.knownUnavailableCount },
        unknownCount: parkAvailability.reduce(0) { $0 + $1.unknownCount },
        totalCount: parkAvailability.reduce(0) { $0 + $1.totalCount },
        lastLiveObservationAt: parkAvailability.compactMap(\.lastLiveObservationAt).max()
      )) ?? candidate.park.availability
  }

  public func representativePark(for operatorName: String) -> ChargingPark? {
    candidates.first {
      $0.park.operatorChargingPoints.contains { $0.name == operatorName }
    }?.park
  }

  public init(
    candidate: EnrichedChargingParkCandidate,
    relatedCandidates: [EnrichedChargingParkCandidate] = [],
    matchingFoodPOI: FoodPOI?
  ) {
    self.candidate = candidate
    var seenIDs = Set([candidate.id])
    self.relatedCandidates =
      relatedCandidates
      .filter { seenIDs.insert($0.id).inserted }
      .sorted { lhs, rhs in
        if lhs.actualDrivingDistance == rhs.actualDrivingDistance {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.actualDrivingDistance < rhs.actualDrivingDistance
      }
    self.matchingFoodPOI = matchingFoodPOI
  }
}

public struct RouteSearchOperatorSummary: Identifiable, Hashable, Codable, Sendable {
  public var id: String { name }

  public let name: String
  public let chargingPointCount: Int

  fileprivate init(name: String, chargingPointCount: Int) {
    self.name = name
    self.chargingPointCount = chargingPointCount
  }
}
