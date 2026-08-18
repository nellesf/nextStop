import Foundation
import NextStopCore

struct BackendCandidate: Identifiable, Hashable, Sendable {
  var id: UUID { park.id }

  let park: ChargingPark
  let distanceFromRoute: Meters
  let straightLineLowerBound: Meters
  let foodPOIs: [FoodPOI]

  init(
    park: ChargingPark,
    distanceFromRoute: Meters,
    straightLineLowerBound: Meters,
    foodPOIs: [FoodPOI] = []
  ) {
    self.park = park
    self.distanceFromRoute = distanceFromRoute
    self.straightLineLowerBound = straightLineLowerBound
    self.foodPOIs = foodPOIs
  }
}

struct DataAttribution: Hashable, Sendable, Identifiable {
  let id: String
  let name: String
  let notice: String
  let licenseName: String
  let licenseURL: URL
  let transportName: String?
  let transportURL: URL?
}

struct CandidateSearchPage: Hashable, Sendable {
  let snapshotToken: String
  let nextCursor: String?
  let candidates: [BackendCandidate]
  let coverage: CandidateSearchCoverage
  let attributions: [DataAttribution]

  init(
    snapshotToken: String,
    nextCursor: String?,
    candidates: [BackendCandidate],
    coverage: CandidateSearchCoverage,
    attributions: [DataAttribution] = []
  ) {
    self.snapshotToken = snapshotToken
    self.nextCursor = nextCursor
    self.candidates = candidates
    self.coverage = coverage
    self.attributions = attributions
  }
}

enum CandidateCoverageStatus: String, Decodable, Hashable, Sendable {
  case complete
  case degraded
  case stale
}

struct CandidateSearchCoverage: Hashable, Sendable {
  let status: CandidateCoverageStatus
  let activeSourceIDs: [String]
  let unavailableSourceIDs: [String]
  let projectionUpdatedAt: Date
}

enum CandidateSearchServiceError: Error, Equatable {
  case invalidConfiguration
  case invalidRequest
  case invalidResponse
  case dataPreparing
  case foodDataPreparing
  case snapshotExpired
  case unavailable
}

@MainActor
protocol CandidatePageSearching: AnyObject {
  func search(request: RouteSearchRequest) async throws -> CandidateSearchPage
}

@MainActor
final class HTTPCandidateSearchService: CandidatePageSearching {
  private static let maximumResponseBytes = 2 * 1_024 * 1_024
  private let baseURL: URL?
  private let session: URLSession
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  convenience init(session: URLSession = .shared) {
    self.init(baseURL: Self.configuredBaseURL(), session: session)
  }

  init(baseURL: URL?, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
    encoder = JSONEncoder()
    decoder = JSONDecoder()
  }

  func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
    guard let baseURL else {
      throw CandidateSearchServiceError.invalidConfiguration
    }
    let url = baseURL.appending(path: "v1/charging-parks/search")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.timeoutInterval = 20
    do {
      urlRequest.httpBody = try encoder.encode(CandidateSearchRequestDTO(request: request))
    } catch {
      throw CandidateSearchServiceError.invalidRequest
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CandidateSearchServiceError.unavailable
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CandidateSearchServiceError.invalidResponse
    }
    guard data.count <= Self.maximumResponseBytes else {
      throw CandidateSearchServiceError.invalidResponse
    }
    guard httpResponse.statusCode == 200 else {
      throw Self.error(for: httpResponse.statusCode, data: data, decoder: decoder)
    }
    do {
      return try decoder.decode(CandidateSearchResponseDTO.self, from: data).domainPage()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CandidateSearchServiceError.invalidResponse
    }
  }

  private static func configuredBaseURL(bundle: Bundle = .main) -> URL? {
    if let override = ProcessInfo.processInfo.environment["NEXTSTOP_API_BASE_URL"],
      !override.isEmpty
    {
      return URL(string: override)
    }
    guard let value = bundle.object(forInfoDictionaryKey: "NextStopAPIBaseURL") as? String,
      !value.isEmpty
    else {
      return nil
    }
    return URL(string: value)
  }

  static func error(
    for statusCode: Int,
    data: Data,
    decoder: JSONDecoder = JSONDecoder()
  ) -> CandidateSearchServiceError {
    guard let problem = try? decoder.decode(ProblemDTO.self, from: data),
      problem.status == statusCode
    else {
      return statusCode >= 500 ? .unavailable : .invalidResponse
    }
    switch (statusCode, problem.type) {
    case (503, "urn:nextstop:error:projection-unavailable"):
      return .dataPreparing
    case (503, "urn:nextstop:error:food-poi-unavailable"):
      return .foodDataPreparing
    case (409, "urn:nextstop:error:invalid-pagination-token"):
      return .snapshotExpired
    default:
      return statusCode >= 500 ? .unavailable : .invalidResponse
    }
  }
}

struct CandidateSearchResponseDTO: Decodable, Equatable {
  let snapshotToken: String
  let nextCursor: String?
  let generatedAt: String
  let candidates: [CandidateDTO]
  let coverage: CoverageDTO
  let attributions: [AttributionDTO]

  func domainPage() throws -> CandidateSearchPage {
    guard !snapshotToken.isEmpty,
      parseServerDate(generatedAt) != nil
    else {
      throw CandidateSearchServiceError.invalidResponse
    }
    let mappedCandidates = try candidates.map { try $0.domainCandidate() }
    guard
      zip(mappedCandidates, mappedCandidates.dropFirst()).allSatisfy({ pair in
        pair.0.straightLineLowerBound <= pair.1.straightLineLowerBound
      })
    else {
      throw CandidateSearchServiceError.invalidResponse
    }
    return CandidateSearchPage(
      snapshotToken: snapshotToken,
      nextCursor: nextCursor,
      candidates: mappedCandidates,
      coverage: try coverage.domainCoverage(),
      attributions: try attributions.map { try $0.domainAttribution() }
    )
  }

  struct CandidateDTO: Decodable, Equatable {
    let id: String
    let name: String
    let coordinate: CoordinateDTO
    let navigationCoordinate: CoordinateDTO
    let distanceFromRouteMeters: Int
    let straightLineLowerBoundMeters: Int
    let chargingPoints: Int
    let availability: AvailabilityDTO
    let maximumPowerKW: Int
    let operators: [String]
    let operatorChargingPoints: [OperatorChargingPointsDTO]
    let sources: [SourceDTO]
    let dataUpdatedAt: String
    let foodPOI: FoodPOIDTO?

    func domainCandidate() throws -> BackendCandidate {
      guard let id = UUID(uuidString: id),
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        distanceFromRouteMeters >= 0,
        straightLineLowerBoundMeters >= 0,
        chargingPoints > 0,
        maximumPowerKW > 0,
        !operators.isEmpty,
        !operators.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        Set(operators).count == operators.count,
        !operatorChargingPoints.isEmpty,
        Set(operatorChargingPoints.map(\.name)).count == operatorChargingPoints.count,
        operatorChargingPoints.reduce(0, { $0 + $1.chargingPoints }) == chargingPoints,
        Set(operatorChargingPoints.map(\.name)) == Set(operators),
        !sources.isEmpty,
        availability.complete == (availability.unknown == 0),
        let updatedAt = parseServerDate(dataUpdatedAt)
      else {
        throw CandidateSearchServiceError.invalidResponse
      }
      let lastLiveObservationAt: Date?
      if let observedAt = availability.observedAt {
        guard let parsed = parseServerDate(observedAt) else {
          throw CandidateSearchServiceError.invalidResponse
        }
        lastLiveObservationAt = parsed
      } else {
        lastLiveObservationAt = nil
      }
      let parkAvailability = try ParkAvailability(
        knownAvailableCount: availability.knownAvailable,
        knownUnavailableCount: availability.knownUnavailable,
        unknownCount: availability.unknown,
        totalCount: availability.total,
        lastLiveObservationAt: lastLiveObservationAt
      )
      let sourceReferences = try sources.map { source in
        guard !source.id.isEmpty,
          !source.name.isEmpty,
          let staticObservedAt = parseServerDate(source.staticObservedAt),
          source.liveObservedAt == nil || parseServerDate(source.liveObservedAt ?? "") != nil
        else {
          throw CandidateSearchServiceError.invalidResponse
        }
        return try DataSourceReference(
          sourceID: source.id,
          sourceRecordID: "projection:\(id.uuidString.lowercased())",
          qualityTier: source.qualityTier,
          observedAt: staticObservedAt,
          fetchedAt: updatedAt
        )
      }
      let park = try ChargingPark(
        id: id,
        name: name,
        coordinate: try coordinate.domainCoordinate(),
        navigationCoordinate: try navigationCoordinate.domainCoordinate(),
        operatorChargingPoints: try operatorChargingPoints.map {
          try OperatorChargingPointSummary(
            name: $0.name,
            chargingPointCount: $0.chargingPoints
          )
        },
        chargingPointCount: chargingPoints,
        availability: parkAvailability,
        maximumPower: Kilowatts(maximumPowerKW),
        sourceReferences: sourceReferences
      )
      let foodPOIs: [FoodPOI]
      if let foodPOI {
        guard let chain = FoodChain(rawValue: foodPOI.chain),
          !foodPOI.id.isEmpty,
          !foodPOI.sourceRecordURL.isEmpty,
          (0...SearchConfiguration.maximumFoodDistance.value).contains(
            foodPOI.distanceFromChargingParkMeters
          )
        else {
          throw CandidateSearchServiceError.invalidResponse
        }
        foodPOIs = [
          try FoodPOI(
            id: foodPOI.id,
            chain: chain,
            name: foodPOI.name,
            coordinate: try foodPOI.coordinate.domainCoordinate(),
            distanceFromPark: Meters(foodPOI.distanceFromChargingParkMeters),
            openingStatus: .unknown
          )
        ]
      } else {
        foodPOIs = []
      }
      return BackendCandidate(
        park: park,
        distanceFromRoute: Meters(distanceFromRouteMeters),
        straightLineLowerBound: Meters(straightLineLowerBoundMeters),
        foodPOIs: foodPOIs
      )
    }
  }

  struct FoodPOIDTO: Decodable, Equatable {
    let id: String
    let chain: String
    let name: String
    let coordinate: CoordinateDTO
    let distanceFromChargingParkMeters: Int
    let openingHours: String?
    let sourceRecordURL: String
  }

  struct AttributionDTO: Decodable, Equatable {
    let id: String
    let name: String
    let notice: String
    let licenseName: String
    let licenseURL: String
    let transportName: String?
    let transportURL: String?

    func domainAttribution() throws -> DataAttribution {
      guard !id.isEmpty, !name.isEmpty, !notice.isEmpty, !licenseName.isEmpty,
        let licenseURL = URL(string: licenseURL),
        licenseURL.scheme == "https",
        transportURL == nil || URL(string: transportURL ?? "")?.scheme == "https"
      else {
        throw CandidateSearchServiceError.invalidResponse
      }
      return DataAttribution(
        id: id,
        name: name,
        notice: notice,
        licenseName: licenseName,
        licenseURL: licenseURL,
        transportName: transportName,
        transportURL: transportURL.flatMap(URL.init(string:))
      )
    }
  }

  struct OperatorChargingPointsDTO: Decodable, Equatable {
    let name: String
    let chargingPoints: Int
  }

  struct CoordinateDTO: Decodable, Equatable {
    let latitude: Double
    let longitude: Double

    func domainCoordinate() throws -> Coordinate {
      try Coordinate(latitude: latitude, longitude: longitude)
    }
  }

  struct AvailabilityDTO: Decodable, Equatable {
    let knownAvailable: Int
    let knownUnavailable: Int
    let unknown: Int
    let total: Int
    let complete: Bool
    let observedAt: String?
  }

  struct SourceDTO: Decodable, Equatable {
    let id: String
    let name: String
    let qualityTier: DataQualityTier
    let staticObservedAt: String
    let liveObservedAt: String?
  }

  struct CoverageDTO: Decodable, Equatable {
    let status: CandidateCoverageStatus
    let activeSources: [String]
    let unavailableSources: [String]
    let projectionUpdatedAt: String

    func domainCoverage() throws -> CandidateSearchCoverage {
      guard let projectionUpdatedAt = parseServerDate(projectionUpdatedAt),
        !activeSources.contains(where: \.isEmpty),
        !unavailableSources.contains(where: \.isEmpty),
        Set(activeSources).count == activeSources.count,
        Set(unavailableSources).count == unavailableSources.count
      else {
        throw CandidateSearchServiceError.invalidResponse
      }
      return CandidateSearchCoverage(
        status: status,
        activeSourceIDs: activeSources,
        unavailableSourceIDs: unavailableSources,
        projectionUpdatedAt: projectionUpdatedAt
      )
    }
  }
}

private struct ProblemDTO: Decodable {
  let type: String
  let status: Int
}

private func parseServerDate(_ value: String) -> Date? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractionalFormatter.date(from: value) {
    return date
  }
  return ISO8601DateFormatter().date(from: value)
}
