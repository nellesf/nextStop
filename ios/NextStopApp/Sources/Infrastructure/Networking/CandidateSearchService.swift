import Foundation
import NextStopCore

struct BackendCandidate: Identifiable, Hashable, Sendable {
  var id: UUID { park.id }

  let park: ChargingPark
  let distanceFromRoute: Meters
  let straightLineLowerBound: Meters
}

struct CandidateSearchPage: Hashable, Sendable {
  let snapshotToken: String
  let nextCursor: String?
  let candidates: [BackendCandidate]
}

enum CandidateSearchServiceError: Error, Equatable {
  case invalidConfiguration
  case invalidRequest
  case invalidResponse
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
    guard httpResponse.statusCode == 200 else {
      throw CandidateSearchServiceError.unavailable
    }
    guard data.count <= Self.maximumResponseBytes else {
      throw CandidateSearchServiceError.invalidResponse
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

}

struct CandidateSearchResponseDTO: Decodable, Equatable {
  let snapshotToken: String
  let nextCursor: String?
  let candidates: [CandidateDTO]

  func domainPage() throws -> CandidateSearchPage {
    guard !snapshotToken.isEmpty else {
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
      candidates: mappedCandidates
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
    let sources: [SourceDTO]
    let dataUpdatedAt: String

    func domainCandidate() throws -> BackendCandidate {
      guard let id = UUID(uuidString: id),
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        distanceFromRouteMeters >= 0,
        straightLineLowerBoundMeters >= 0,
        chargingPoints > 0,
        maximumPowerKW > 0,
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
          let staticObservedAt = parseServerDate(source.staticObservedAt)
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
        operators: operators,
        chargingPointCount: chargingPoints,
        availability: parkAvailability,
        maximumPower: Kilowatts(maximumPowerKW),
        sourceReferences: sourceReferences
      )
      return BackendCandidate(
        park: park,
        distanceFromRoute: Meters(distanceFromRouteMeters),
        straightLineLowerBound: Meters(straightLineLowerBoundMeters)
      )
    }
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
  }
}

private func parseServerDate(_ value: String) -> Date? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractionalFormatter.date(from: value) {
    return date
  }
  return ISO8601DateFormatter().date(from: value)
}
