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
  case authenticationUnavailable
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
  typealias Load = @MainActor (URLRequest) async throws -> (Data, URLResponse)
  typealias Now = @MainActor () -> Date
  typealias Sleep = @MainActor (TimeInterval) async throws -> Void

  private static let maximumResponseBytes = 2 * 1_024 * 1_024
  private static let transientRetryDelay: TimeInterval = 0.4
  private static let maximumRetryAfter: TimeInterval = 2
  private let baseURL: URL?
  private let accessTokenProvider: (any SearchAccessTokenProviding)?
  private let load: Load
  private let now: Now
  private let sleep: Sleep
  private let diagnostics: any AppDiagnosticRecording
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    baseURL: URL?,
    accessTokenProvider: (any SearchAccessTokenProviding)?,
    session: URLSession = .shared,
    load: Load? = nil,
    now: @escaping Now = Date.init,
    sleep: @escaping Sleep = { seconds in
      try await Task.sleep(for: .milliseconds(Int64((seconds * 1_000).rounded(.up))))
    },
    diagnostics: any AppDiagnosticRecording = NoopAppDiagnostics()
  ) {
    self.baseURL = baseURL
    self.accessTokenProvider = accessTokenProvider
    self.load = load ?? { request in try await session.data(for: request) }
    self.now = now
    self.sleep = sleep
    self.diagnostics = diagnostics
    encoder = JSONEncoder()
    decoder = JSONDecoder()
  }

  func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
    try Task.checkCancellation()
    let token = try await accessToken(forceRefresh: false)
    // Reuse the exact signed page request throughout recovery, changing only the
    // authorization header if the one permitted token refresh is needed.
    var urlRequest = try makeURLRequest(request: request, accessToken: token)
    var mayRefreshToken = true
    var mayRetryTransientFailure = true
    var attempt = 0

    while true {
      try Task.checkCancellation()
      attempt += 1
      let startedAt = now()
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await load(urlRequest)
        try Task.checkCancellation()
      } catch {
        if Self.isCancellation(error) { throw CancellationError() }
        let retry = mayRetryTransientFailure && Self.isTransient(error)
        let nsError = error as NSError
        let isURLError = nsError.domain == NSURLErrorDomain
        record(
          outcome: retry ? .retryScheduled : .failure,
          category: Self.category(for: error),
          startedAt: startedAt,
          attempt: attempt,
          errorDomain: isURLError ? .url : .unknown,
          errorCode: isURLError ? nsError.code : nil
        )
        guard retry else { throw CandidateSearchServiceError.unavailable }
        mayRetryTransientFailure = false
        try await waitBeforeRetry(seconds: Self.transientRetryDelay)
        continue
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        record(
          outcome: .failure, category: .invalidResponse, startedAt: startedAt, attempt: attempt)
        throw CandidateSearchServiceError.invalidResponse
      }
      guard data.count <= Self.maximumResponseBytes else {
        record(
          outcome: .failure, category: .invalidResponse, startedAt: startedAt,
          attempt: attempt, response: httpResponse
        )
        throw CandidateSearchServiceError.invalidResponse
      }
      if httpResponse.statusCode == 401 {
        record(
          outcome: mayRefreshToken ? .retryScheduled : .failure,
          category: .authentication, startedAt: startedAt,
          attempt: attempt, response: httpResponse
        )
        guard mayRefreshToken else { throw CandidateSearchServiceError.authenticationUnavailable }
        mayRefreshToken = false
        let refreshedToken = try await accessToken(forceRefresh: true)
        urlRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
        continue
      }
      guard httpResponse.statusCode == 200 else {
        let error = Self.error(for: httpResponse.statusCode, data: data, decoder: decoder)
        let delay =
          mayRetryTransientFailure && Self.isTransient(httpResponse, error: error)
          ? retryDelay(for: httpResponse) : nil
        record(
          outcome: delay == nil ? .failure : .retryScheduled,
          category: httpResponse.statusCode == 429 ? .throttled : .http,
          startedAt: startedAt, attempt: attempt, response: httpResponse
        )
        guard let delay else { throw error }
        mayRetryTransientFailure = false
        try await waitBeforeRetry(seconds: delay)
        continue
      }
      let page: CandidateSearchPage
      do {
        page = try decoder.decode(CandidateSearchResponseDTO.self, from: data).domainPage()
      } catch {
        record(
          outcome: .failure, category: .invalidResponse, startedAt: startedAt,
          attempt: attempt, response: httpResponse
        )
        throw CandidateSearchServiceError.invalidResponse
      }
      if attempt > 1 {
        record(
          outcome: .recovered, category: .http, startedAt: startedAt,
          attempt: attempt, response: httpResponse
        )
      }
      return page
    }
  }

  private func waitBeforeRetry(seconds: TimeInterval) async throws {
    try Task.checkCancellation()
    try await sleep(seconds)
    try Task.checkCancellation()
  }

  private func retryDelay(for response: HTTPURLResponse) -> TimeInterval? {
    guard let header = response.value(forHTTPHeaderField: "Retry-After") else {
      return Self.transientRetryDelay
    }
    let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count <= 64 else { return nil }
    let requestedDelay: TimeInterval
    if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let seconds = TimeInterval(value), seconds.isFinite
    {
      requestedDelay = seconds
    } else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
      formatter.isLenient = false
      guard let retryAt = formatter.date(from: value), formatter.string(from: retryAt) == value
      else {
        return nil
      }
      requestedDelay = max(0, retryAt.timeIntervalSince(now()))
    }
    // Never shorten a server-requested backoff just to fit the interactive cap.
    guard requestedDelay.isFinite, requestedDelay <= Self.maximumRetryAfter else { return nil }
    return max(Self.transientRetryDelay, requestedDelay)
  }

  private static func isTransient(_ response: HTTPURLResponse, error: CandidateSearchServiceError)
    -> Bool
  {
    switch response.statusCode {
    case 408, 500, 502, 504:
      true
    case 429, 503:
      error == .unavailable
    default:
      false
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
  }

  private static func isTransient(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return false }
    return switch URLError.Code(rawValue: nsError.code) {
    case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
      .notConnectedToInternet:
      true
    default:
      false
    }
  }

  private static func category(for error: Error) -> AppDiagnosticCategory {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return .unknown }
    return switch URLError.Code(rawValue: nsError.code) {
    case .timedOut: .networkTimeout
    case .networkConnectionLost: .networkLost
    case .notConnectedToInternet: .offline
    case .cannotConnectToHost, .dnsLookupFailed: .connection
    default: .unknown
    }
  }

  private func record(
    outcome: AppDiagnosticOutcome,
    category: AppDiagnosticCategory,
    startedAt: Date,
    attempt: Int,
    response: HTTPURLResponse? = nil,
    errorDomain: AppDiagnosticErrorDomain? = nil,
    errorCode: Int? = nil
  ) {
    let timestamp = now()
    diagnostics.record(
      AppDiagnosticEvent(
        timestamp: timestamp,
        operation: .candidateSearch,
        outcome: outcome,
        category: category,
        durationMilliseconds: Self.durationMilliseconds(from: startedAt, to: timestamp),
        attempt: attempt,
        httpStatus: response?.statusCode,
        errorDomain: errorDomain,
        errorCode: errorCode,
        serverRequestID: response?.value(forHTTPHeaderField: "X-Request-ID").flatMap(
          UUID.init(uuidString:)),
        edgeRequestID: Self.edgeRequestID(response?.value(forHTTPHeaderField: "X-Edge-Request-ID"))
      )
    )
  }

  private static func edgeRequestID(_ value: String?) -> UUID? {
    guard let value else { return nil }
    let bytes = Array(value.utf8)
    guard bytes.count == 32,
      bytes.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return nil }
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
    let uuid = groups.map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "-")
    return UUID(uuidString: uuid)
  }

  func makeURLRequest(
    request: RouteSearchRequest,
    accessToken: String
  ) throws -> URLRequest {
    guard let baseURL,
      Self.validatedAccessToken(accessToken) != nil
    else {
      throw CandidateSearchServiceError.invalidConfiguration
    }
    let url = baseURL.appending(path: "v1/charging-parks/search")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    urlRequest.timeoutInterval = 20
    do {
      urlRequest.httpBody = try encoder.encode(CandidateSearchRequestDTO(request: request))
    } catch {
      throw CandidateSearchServiceError.invalidRequest
    }
    return urlRequest
  }

  private func accessToken(forceRefresh: Bool) async throws -> String {
    let startedAt = now()
    do {
      guard let accessTokenProvider else {
        throw CandidateSearchServiceError.invalidConfiguration
      }
      let value = try await accessTokenProvider.accessToken(forceRefresh: forceRefresh)
      try Task.checkCancellation()
      guard let token = Self.validatedAccessToken(value) else {
        throw CandidateSearchServiceError.authenticationUnavailable
      }
      return token
    } catch {
      if Self.isCancellation(error) { throw CancellationError() }
      let timestamp = now()
      diagnostics.record(
        AppDiagnosticEvent(
          timestamp: timestamp, operation: .authentication, outcome: .failure,
          category: .authentication,
          durationMilliseconds: Self.durationMilliseconds(from: startedAt, to: timestamp)
        )
      )
      throw error as? CandidateSearchServiceError ?? .authenticationUnavailable
    }
  }

  private static func durationMilliseconds(from startedAt: Date, to timestamp: Date) -> Int {
    let elapsed = (timestamp.timeIntervalSince(startedAt) * 1_000).rounded()
    return elapsed.isFinite && elapsed >= 0 && elapsed < Double(Int.max) ? Int(elapsed) : 0
  }

  static func configuredBaseURL(bundle: Bundle = .main) -> URL? {
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

  static func validatedAccessToken(_ value: String) -> String? {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.utf8.count >= 32,
      token.utf8.count <= 4_096,
      !token.contains(where: { $0.isWhitespace }),
      !token.contains("$(")
    else {
      return nil
    }
    return token
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
    case (401, "urn:nextstop:error:unauthorized"):
      return .authenticationUnavailable
    case (429, "urn:nextstop:error:search-capacity-exhausted"):
      return .unavailable
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
    let locationLookups: [ChargingLocationLookupDTO]?
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
        sourceReferences: sourceReferences,
        locationLookups: try (locationLookups ?? []).map { try $0.domainLookup() }
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

  struct ChargingLocationLookupDTO: Decodable, Equatable {
    let id: String
    let operatorName: String
    let coordinate: CoordinateDTO
    let address: ChargingLocationAddressDTO

    func domainLookup() throws -> ChargingLocationLookup {
      guard let id = UUID(uuidString: id) else {
        throw CandidateSearchServiceError.invalidResponse
      }
      return try ChargingLocationLookup(
        id: id,
        operatorName: operatorName,
        coordinate: try coordinate.domainCoordinate(),
        address: ChargingLocationAddress(
          street: address.street,
          houseNumber: address.houseNumber,
          postalCode: address.postalCode,
          city: address.city
        )
      )
    }
  }

  struct ChargingLocationAddressDTO: Decodable, Equatable {
    let street: String?
    let houseNumber: String?
    let postalCode: String?
    let city: String?
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
