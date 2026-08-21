import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class AuthenticationTransportTests: XCTestCase {
  override func tearDown() {
    TestHTTPURLProtocol.handler = nil
    super.tearDown()
  }

  func testAppDelegateRetainsInjectedCandidateSearcherAsSharedCompositionRoot() {
    let searcher = SharedCandidatePageSearcherStub()

    let appDelegate = NextStopAppDelegate(candidatePageSearcher: searcher)

    XCTAssertEqual(
      ObjectIdentifier(appDelegate.candidatePageSearcher),
      ObjectIdentifier(searcher)
    )
  }

  func testAppAttestClientUsesStrictDTOsAndCanonicalArtifactBase64() async throws {
    let sequence = HTTPResponseSequence(responses: [
      HTTPResponseSequence.Response.json(
        status: 200,
        body:
          #"{"challengeId":"00000000-0000-4000-8000-000000000001","clientData":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY","expiresAt":"2099-01-01T00:00:00Z"}"#
      ),
      HTTPResponseSequence.Response.json(
        status: 200,
        body:
          #"{"accessToken":"abcdefghijklmnopqrstuvwxyz1234567890","tokenType":"Bearer","expiresInSeconds":900}"#
      ),
    ])
    TestHTTPURLProtocol.handler = { request in try sequence.response(for: request) }
    let client = AppAttestAuthenticationClient(
      baseURL: URL(string: "https://api.nextstop.test")!,
      session: makeTestSession(),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let challenge = try await client.challenge(
      keyID: Self.appAttestKeyID,
      purpose: .attestation
    )
    let token = try await client.attest(
      keyID: Self.appAttestKeyID,
      challengeID: challenge.id,
      attestationObject: Data([0xfb, 0xff])
    )

    XCTAssertEqual(
      challenge.clientData,
      Data("0123456789abcdef0123456789abcdef".utf8)
    )
    XCTAssertEqual(token.value, "abcdefghijklmnopqrstuvwxyz1234567890")
    let requests = sequence.recordedRequests
    XCTAssertEqual(
      requests.map { $0.url?.path },
      [
        "/v1/auth/app-attest/challenge", "/v1/auth/app-attest/attest",
      ])
    let challengeBody = try XCTUnwrap(requests.first?.httpBody)
    let challengeJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: challengeBody) as? [String: String]
    )
    XCTAssertEqual(challengeJSON["keyId"], Self.appAttestKeyID)
    XCTAssertEqual(challengeJSON["purpose"], "attestation")
    let attestationBody = try XCTUnwrap(requests.last?.httpBody)
    let attestationJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: attestationBody) as? [String: String]
    )
    XCTAssertEqual(attestationJSON["attestationObject"], "+/8=")
  }

  func testAppAttestClientRejectsNonCanonicalBase64URLChallenge() async {
    TestHTTPURLProtocol.handler = { request in
      HTTPResponseSequence.Response.json(
        request: request,
        status: 200,
        body:
          #"{"challengeId":"00000000-0000-4000-8000-000000000001","clientData":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=","expiresAt":"2099-01-01T00:00:00Z"}"#
      )
    }
    let client = AppAttestAuthenticationClient(
      baseURL: URL(string: "https://api.nextstop.test")!,
      session: makeTestSession()
    )

    do {
      _ = try await client.challenge(keyID: Self.appAttestKeyID, purpose: .attestation)
      XCTFail("Expected invalid response")
    } catch {
      XCTAssertEqual(error as? AppAttestAuthenticationClientError, .invalidResponse)
    }
  }

  func testAppAttestClientRejectsNonUUIDChallengeIdentifier() async {
    TestHTTPURLProtocol.handler = { request in
      HTTPResponseSequence.Response.json(
        request: request,
        status: 200,
        body:
          #"{"challengeId":"challenge-1","clientData":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY","expiresAt":"2099-01-01T00:00:00Z"}"#
      )
    }
    let client = AppAttestAuthenticationClient(
      baseURL: URL(string: "https://api.nextstop.test")!,
      session: makeTestSession()
    )

    do {
      _ = try await client.challenge(keyID: Self.appAttestKeyID, purpose: .attestation)
      XCTFail("Expected invalid response")
    } catch {
      XCTAssertEqual(error as? AppAttestAuthenticationClientError, .invalidResponse)
    }
  }

  func testAppAttestClientRejectsWrongUUIDVersionVariantAndCase() async {
    let rejectedChallengeIDs = [
      "00000000-0000-1000-8000-000000000001",
      "00000000-0000-4000-7000-000000000001",
      "00000000-0000-4000-8000-00000000000A",
    ]

    for challengeID in rejectedChallengeIDs {
      TestHTTPURLProtocol.handler = { request in
        HTTPResponseSequence.Response.json(
          request: request,
          status: 200,
          body: """
            {"challengeId":"\(challengeID)","clientData":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY","expiresAt":"2099-01-01T00:00:00Z"}
            """
        )
      }
      let client = AppAttestAuthenticationClient(
        baseURL: URL(string: "https://api.nextstop.test")!,
        session: makeTestSession()
      )

      do {
        _ = try await client.challenge(
          keyID: Self.appAttestKeyID,
          purpose: .attestation
        )
        XCTFail("Expected invalid response for \(challengeID)")
      } catch {
        XCTAssertEqual(error as? AppAttestAuthenticationClientError, .invalidResponse)
      }
    }
  }

  func testAppAttestClientRejectsChallengeThatIsNotExactlyThirtyTwoBytes() async {
    TestHTTPURLProtocol.handler = { request in
      HTTPResponseSequence.Response.json(
        request: request,
        status: 200,
        body:
          #"{"challengeId":"00000000-0000-4000-8000-000000000001","clientData":"MDEyMzQ1Njc4OWFiY2RlZg","expiresAt":"2099-01-01T00:00:00Z"}"#
      )
    }
    let client = AppAttestAuthenticationClient(
      baseURL: URL(string: "https://api.nextstop.test")!,
      session: makeTestSession()
    )

    do {
      _ = try await client.challenge(keyID: Self.appAttestKeyID, purpose: .assertion)
      XCTFail("Expected invalid response")
    } catch {
      XCTAssertEqual(error as? AppAttestAuthenticationClientError, .invalidResponse)
    }
  }

  func testAppAttestClientTreatsRateLimitAsTemporarilyUnavailable() async {
    TestHTTPURLProtocol.handler = { request in
      HTTPResponseSequence.Response.json(
        request: request,
        status: 429,
        body: #"{"status":429}"#
      )
    }
    let client = AppAttestAuthenticationClient(
      baseURL: URL(string: "https://api.nextstop.test")!,
      session: makeTestSession()
    )

    do {
      _ = try await client.challenge(keyID: Self.appAttestKeyID, purpose: .assertion)
      XCTFail("Expected unavailable")
    } catch {
      XCTAssertEqual(error as? AppAttestAuthenticationClientError, .unavailable)
    }
  }

  func testAppAttestClientDoesNotTreatRejectedProofAsMissingKey() async {
    TestHTTPURLProtocol.handler = { request in
      HTTPResponseSequence.Response.json(
        request: request,
        status: 401,
        body: #"{"status":401}"#
      )
    }
    let client = AppAttestAuthenticationClient(
      baseURL: URL(string: "https://api.nextstop.test")!,
      session: makeTestSession()
    )

    do {
      _ = try await client.assert(
        keyID: Self.appAttestKeyID,
        challengeID: "00000000-0000-4000-8000-000000000001",
        assertionObject: Data("assertion".utf8)
      )
      XCTFail("Expected rejected proof")
    } catch {
      XCTAssertEqual(error as? AppAttestAuthenticationClientError, .proofRejected)
    }
  }

  func testCandidateSearchRefreshesOnceAfterUnauthorized() async throws {
    let sequence = HTTPResponseSequence(responses: [
      .json(
        status: 401,
        body: #"{"type":"urn:nextstop:error:unauthorized","status":401}"#
      ),
      .json(status: 200, body: Self.emptyCandidatePage),
    ])
    TestHTTPURLProtocol.handler = { request in try sequence.response(for: request) }
    let provider = RefreshingTokenProvider(tokens: [
      "expired-" + String(repeating: "a", count: 32),
      "fresh-" + String(repeating: "b", count: 32),
    ])
    let service = HTTPCandidateSearchService(
      baseURL: URL(string: "https://api.nextstop.test"),
      accessTokenProvider: provider,
      session: makeTestSession()
    )

    let page = try await service.search(request: try makeSearchRequest())

    XCTAssertEqual(page.candidates, [])
    let forceRefreshValues = await provider.forceRefreshValues
    XCTAssertEqual(forceRefreshValues, [false, true])
    XCTAssertEqual(
      sequence.recordedRequests.compactMap {
        $0.value(forHTTPHeaderField: "Authorization")
      },
      [
        "Bearer expired-" + String(repeating: "a", count: 32),
        "Bearer fresh-" + String(repeating: "b", count: 32),
      ]
    )
  }

  func testCandidateSearchDoesNotRetrySecondUnauthorized() async {
    let sequence = HTTPResponseSequence(responses: [
      .json(status: 401, body: #"{"type":"urn:nextstop:error:unauthorized","status":401}"#),
      .json(status: 401, body: #"{"unexpected":"body"}"#),
    ])
    TestHTTPURLProtocol.handler = { request in try sequence.response(for: request) }
    let provider = RefreshingTokenProvider(tokens: [
      String(repeating: "a", count: 32), String(repeating: "b", count: 32),
    ])
    let service = HTTPCandidateSearchService(
      baseURL: URL(string: "https://api.nextstop.test"),
      accessTokenProvider: provider,
      session: makeTestSession()
    )

    do {
      _ = try await service.search(request: try makeSearchRequest())
      XCTFail("Expected authentication failure")
    } catch {
      XCTAssertEqual(error as? CandidateSearchServiceError, .authenticationUnavailable)
    }
    XCTAssertEqual(sequence.recordedRequests.count, 2)
    let forceRefreshValues = await provider.forceRefreshValues
    XCTAssertEqual(forceRefreshValues, [false, true])
  }

  #if DEBUG && targetEnvironment(simulator)
    func testFactorySelectsLoopbackBrokerWhenAppAttestIsUnsupportedInSimulator() async throws {
      let sequence = HTTPResponseSequence(responses: [
        HTTPResponseSequence.Response.json(
          status: 200,
          body:
            #"{"accessToken":"simulator-factory-token-12345678901234567","tokenType":"Bearer","expiresInSeconds":900}"#
        )
      ])
      TestHTTPURLProtocol.handler = { request in try sequence.response(for: request) }
      let provider = SearchAccessTokenProviderFactory.make(
        baseURL: URL(string: "https://api.nextstop.test")!,
        session: makeTestSession(),
        service: UnsupportedAppAttestServiceStub()
      )

      let token = try await provider.accessToken(forceRefresh: false)

      XCTAssertTrue(token.hasPrefix("simulator-factory-token-"))
      XCTAssertEqual(sequence.recordedRequests.count, 1)
      XCTAssertEqual(
        sequence.recordedRequests.first?.url?.absoluteString, "http://127.0.0.1:9482/token")
    }

    func testSimulatorBrokerCachesNormallyAndForceRefreshesAfterUnauthorized() async throws {
      let sequence = HTTPResponseSequence(responses: [
        .json(
          status: 200,
          body:
            #"{"accessToken":"simulator-broker-token-1234567890123456","tokenType":"Bearer","expiresInSeconds":900}"#
        ),
        .json(
          status: 200,
          body:
            #"{"accessToken":"simulator-refreshed-token-123456789012","tokenType":"Bearer","expiresInSeconds":900}"#
        ),
      ])
      TestHTTPURLProtocol.handler = { request in try sequence.response(for: request) }
      let provider = SimulatorSearchAccessTokenProvider(
        brokerURL: URL(string: "http://127.0.0.1:9482/token"),
        session: makeTestSession(),
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
      )

      let first = try await provider.accessToken(forceRefresh: false)
      let second = try await provider.accessToken(forceRefresh: false)
      let refreshed = try await provider.accessToken(forceRefresh: true)

      XCTAssertEqual(first, second)
      XCTAssertNotEqual(first, refreshed)
      XCTAssertEqual(sequence.recordedRequests.count, 2)
      XCTAssertEqual(sequence.recordedRequests.first?.httpMethod, "POST")
      XCTAssertEqual(
        sequence.recordedRequests.first?.value(
          forHTTPHeaderField: "X-NextStop-Simulator-Auth"
        ),
        "1"
      )
      XCTAssertNil(
        sequence.recordedRequests.first?.value(
          forHTTPHeaderField: "X-NextStop-Simulator-Force-Refresh"
        )
      )
      XCTAssertEqual(
        sequence.recordedRequests.last?.value(
          forHTTPHeaderField: "X-NextStop-Simulator-Force-Refresh"
        ),
        "1"
      )
      XCTAssertNil(sequence.recordedRequests.first?.httpBody)
    }

    func testSimulatorBrokerFailsClosedForInvalidDTO() async {
      TestHTTPURLProtocol.handler = { request in
        HTTPResponseSequence.Response.json(
          request: request,
          status: 200,
          body: #"{"accessToken":"too-short","tokenType":"Bearer","expiresInSeconds":900}"#
        )
      }
      let provider = SimulatorSearchAccessTokenProvider(
        brokerURL: URL(string: "http://127.0.0.1:9482/token"),
        session: makeTestSession()
      )

      do {
        _ = try await provider.accessToken(forceRefresh: false)
        XCTFail("Expected invalid response")
      } catch {
        XCTAssertEqual(error as? SearchAccessTokenProviderError, .invalidResponse)
      }
    }
  #endif

  private func makeTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestHTTPURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeSearchRequest() throws -> RouteSearchRequest {
    RouteSearchRequest(
      requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      route: try RoutePolyline(
        coordinates: [
          Coordinate(latitude: 48.1372, longitude: 11.5756),
          Coordinate(latitude: 49.1, longitude: 11.9),
        ]
      ),
      criteria: SearchConfiguration.defaultCriteria
    )
  }

  private static let emptyCandidatePage =
    #"{"snapshotToken":"snapshot-token","nextCursor":null,"generatedAt":"2026-08-15T13:33:35.000Z","candidates":[],"coverage":{"status":"complete","activeSources":["bundesnetzagentur_ladesaeulenregister"],"unavailableSources":[],"projectionUpdatedAt":"2026-08-15T13:33:34.000Z"},"attributions":[]}"#
  private static let appAttestKeyID = Data(repeating: 0xfb, count: 32)
    .base64EncodedString()
}

#if DEBUG && targetEnvironment(simulator)
  @MainActor
  private final class UnsupportedAppAttestServiceStub: AppAttestServicing {
    let isSupported = false

    func generateKey() async throws -> String {
      throw AppAttestServiceError.unsupported
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
      throw AppAttestServiceError.unsupported
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
      throw AppAttestServiceError.unsupported
    }
  }
#endif

@MainActor
private final class SharedCandidatePageSearcherStub: CandidatePageSearching {
  func search(request: RouteSearchRequest) async throws -> CandidateSearchPage {
    throw CandidateSearchServiceError.unavailable
  }
}

private actor RefreshingTokenProvider: SearchAccessTokenProviding {
  private var tokens: [String]
  private(set) var forceRefreshValues: [Bool] = []

  init(tokens: [String]) {
    self.tokens = tokens
  }

  func accessToken(forceRefresh: Bool) async throws -> String {
    forceRefreshValues.append(forceRefresh)
    guard !tokens.isEmpty else {
      throw SearchAccessTokenProviderError.unavailable
    }
    return tokens.removeFirst()
  }
}

private final class HTTPResponseSequence: @unchecked Sendable {
  struct Response: Sendable {
    let status: Int
    let body: Data

    static func json(status: Int, body: String) -> Response {
      Response(status: status, body: Data(body.utf8))
    }

    static func json(request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!,
        Data(body.utf8)
      )
    }
  }

  private let lock = NSLock()
  private var responses: [Response]
  private var requests: [URLRequest] = []

  init(responses: [Response]) {
    self.responses = responses
  }

  func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    guard !responses.isEmpty else {
      throw URLError(.badServerResponse)
    }
    let response = responses.removeFirst()
    return Response.json(
      request: request,
      status: response.status,
      body: String(data: response.body, encoding: .utf8) ?? ""
    )
  }

  var recordedRequests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

private final class TestHTTPURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
