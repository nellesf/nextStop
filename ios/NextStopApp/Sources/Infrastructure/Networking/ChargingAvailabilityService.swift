import Foundation
import NextStopCore

struct ChargingAvailabilitySelection: Hashable, Sendable {
  let id: UUID
  let operatorNames: [String]
  let expectedChargingPoints: Int

  static func from(_ results: [RouteSearchResult]) -> [Self] {
    var selections: [UUID: Self] = [:]
    for result in results {
      for candidate in result.candidates {
        let operators = candidate.park.operatorChargingPoints.filter {
          result.eligibleOperatorNames?.contains($0.name) ?? true
        }
        // Never truncate a unit's operators: its live total must cover the exact displayed subset.
        guard !operators.isEmpty, operators.count <= 20 else { continue }
        selections[candidate.id] = Self(
          id: candidate.id, operatorNames: operators.map(\.name).sorted(),
          expectedChargingPoints: operators.reduce(0) { $0 + $1.chargingPointCount }
        )
      }
    }
    return selections.values.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

struct ChargingAvailabilityBatch: Sendable {
  let generatedAt: Date
  let contextExpiresAt: Date
  let refreshPending: Bool
  let retryAfterSeconds: TimeInterval?
  let candidates: [UUID: ParkAvailability]
}

enum ChargingAvailabilityError: Error, Equatable {
  case unavailable
  case invalidResponse
}

@MainActor
protocol ChargingAvailabilityFetching: AnyObject {
  func fetchAvailability(
    context: String, candidates: [ChargingAvailabilitySelection]
  ) async throws -> ChargingAvailabilityBatch
}

@MainActor
final class HTTPChargingAvailabilityService: ChargingAvailabilityFetching {
  typealias Load = @MainActor (URLRequest) async throws -> (Data, URLResponse)
  private let baseURL: URL?
  private let accessTokenProvider: (any SearchAccessTokenProviding)?
  private let load: Load

  init(
    baseURL: URL?, accessTokenProvider: (any SearchAccessTokenProviding)?,
    load: @escaping Load
  ) {
    self.baseURL = baseURL
    self.accessTokenProvider = accessTokenProvider
    self.load = load
  }

  func fetchAvailability(
    context: String, candidates: [ChargingAvailabilitySelection]
  ) async throws -> ChargingAvailabilityBatch {
    try Task.checkCancellation()
    guard let baseURL, let accessTokenProvider,
      !context.isEmpty, context.utf8.count <= 1_024,
      (1...50).contains(candidates.count), Set(candidates.map(\.id)).count == candidates.count,
      candidates.allSatisfy({
        (1...20).contains($0.operatorNames.count)
          && Set($0.operatorNames).count == $0.operatorNames.count
          && $0.operatorNames.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 200 }
          && $0.expectedChargingPoints > 0
      })
    else { throw ChargingAvailabilityError.unavailable }

    let body = AvailabilityRequestDTO(
      context: context,
      candidates: candidates.map {
        .init(id: $0.id.uuidString.lowercased(), operatorNames: $0.operatorNames)
      }
    )
    var request = URLRequest(url: baseURL.appending(path: "v1/charging-parks/availability"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(body)

    for attempt in 0...1 {
      let token = try await accessTokenProvider.accessToken(forceRefresh: attempt == 1)
      try Task.checkCancellation()
      guard let validatedToken = HTTPCandidateSearchService.validatedAccessToken(token) else {
        throw ChargingAvailabilityError.unavailable
      }
      request.setValue("Bearer \(validatedToken)", forHTTPHeaderField: "Authorization")
      let (data, response) = try await load(request)
      try Task.checkCancellation()
      guard let response = response as? HTTPURLResponse, data.count <= 256 * 1_024 else {
        throw ChargingAvailabilityError.invalidResponse
      }
      if response.statusCode == 401, attempt == 0 { continue }
      guard response.statusCode == 200 else { throw ChargingAvailabilityError.unavailable }
      do {
        return try JSONDecoder().decode(AvailabilityResponseDTO.self, from: data)
          .validated(context: context, selections: candidates)
      } catch {
        throw ChargingAvailabilityError.invalidResponse
      }
    }
    throw ChargingAvailabilityError.unavailable
  }
}

private struct AvailabilityRequestDTO: Encodable {
  let context: String
  let candidates: [Candidate]
  struct Candidate: Encodable {
    let id: String
    let operatorNames: [String]
  }
}

private struct AvailabilityResponseDTO: Decodable {
  let context: String
  let generatedAt: String
  let expiresAt: String
  let refreshPending: Bool
  let retryAfterSeconds: Double?
  let candidates: [Candidate]

  struct Candidate: Decodable {
    let id: UUID
    let operatorNames: [String]
    let availability: CandidateSearchResponseDTO.AvailabilityDTO
  }

  func validated(
    context expectedContext: String, selections: [ChargingAvailabilitySelection]
  ) throws -> ChargingAvailabilityBatch {
    guard context == expectedContext,
      let generated = Self.date(generatedAt), let expires = Self.date(expiresAt),
      expires > generated,
      retryAfterSeconds.map({ $0.isFinite && (0...60).contains($0) }) ?? true,
      candidates.count == selections.count,
      Set(candidates.map(\.id)) == Set(selections.map(\.id)),
      Set(candidates.map(\.id)).count == candidates.count
    else { throw ChargingAvailabilityError.invalidResponse }
    let expected = Dictionary(uniqueKeysWithValues: selections.map { ($0.id, $0) })
    var values: [UUID: ParkAvailability] = [:]
    for candidate in candidates {
      guard let selection = expected[candidate.id],
        candidate.operatorNames.count == selection.operatorNames.count,
        Set(candidate.operatorNames) == Set(selection.operatorNames),
        candidate.availability.total == selection.expectedChargingPoints,
        candidate.availability.complete == (candidate.availability.unknown == 0)
      else { throw ChargingAvailabilityError.invalidResponse }
      let availability = candidate.availability
      guard availability.knownAvailable >= 0, availability.knownUnavailable >= 0,
        availability.unknown >= 0,
        availability.knownAvailable <= availability.total,
        availability.knownUnavailable <= availability.total - availability.knownAvailable,
        availability.unknown == availability.total - availability.knownAvailable
          - availability.knownUnavailable
      else { throw ChargingAvailabilityError.invalidResponse }
      let observedAt = availability.observedAt.flatMap(Self.date)
      guard availability.observedAt == nil || observedAt != nil,
        observedAt.map({ $0 <= generated }) ?? true,
        availability.unknown == availability.total
          || observedAt.map({ generated.timeIntervalSince($0) <= 300 }) == true
      else { throw ChargingAvailabilityError.invalidResponse }
      values[candidate.id] = try ParkAvailability(
        knownAvailableCount: availability.knownAvailable,
        knownUnavailableCount: availability.knownUnavailable,
        unknownCount: availability.unknown, totalCount: availability.total,
        lastLiveObservationAt: observedAt
      )
    }
    return ChargingAvailabilityBatch(
      generatedAt: generated, contextExpiresAt: expires,
      refreshPending: refreshPending, retryAfterSeconds: retryAfterSeconds, candidates: values
    )
  }

  private static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}
