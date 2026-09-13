import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class HTTPCandidateSearchRecoveryTests: XCTestCase {
  func testTransientNetworkFailuresRetryTheIdenticalSignedPageOnce() async throws {
    for code in [
      URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost,
      .dnsLookupFailed, .notConnectedToInternet,
    ] {
      let fixture = HTTPRecoveryFixture(replies: [.failure(URLError(code)), .success(.page)])
      let page = try await fixture.service().search(request: request())

      XCTAssertEqual(page.snapshotToken, "snapshot-token")
      XCTAssertEqual(fixture.requests.count, 2)
      XCTAssertEqual(fixture.requests[0].httpBody, fixture.requests[1].httpBody)
      XCTAssertEqual(
        fixture.requests[0].allHTTPHeaderFields, fixture.requests[1].allHTTPHeaderFields)
      XCTAssertEqual(fixture.waits, [0.4])
      XCTAssertEqual(fixture.events.map(\.outcome), [.retryScheduled, .recovered])
      XCTAssertEqual(fixture.events.map(\.attempt), [1, 2])
      XCTAssertEqual(fixture.events[0].errorDomain, .url)
      XCTAssertEqual(fixture.events[0].errorCode, code.rawValue)
      XCTAssertEqual(fixture.events[0].durationMilliseconds, 100)
    }
  }

  func testPersistentNetworkFailureStopsAfterOneRecoveryAttempt() async throws {
    let fixture = HTTPRecoveryFixture(replies: [
      .failure(URLError(.timedOut)), .failure(URLError(.networkConnectionLost)), .success(.page),
    ])
    do {
      _ = try await fixture.service().search(request: request())
      XCTFail("The single transient recovery budget must not reset")
    } catch {
      XCTAssertEqual(error as? CandidateSearchServiceError, .unavailable)
    }
    XCTAssertEqual(fixture.requests.count, 2)
    XCTAssertEqual(fixture.waits, [0.4])
    XCTAssertEqual(fixture.events.map(\.outcome), [.retryScheduled, .failure])
  }

  func testTemporaryHTTPFailuresRecoverAndRetainServerRequestIDs() async throws {
    for status in [408, 429, 500, 502, 503, 504] {
      let serverRequestID = UUID(uuidString: "12345678-1234-4234-8234-123456789012")!
      let body =
        status == 429
        ? #"{"type":"urn:nextstop:error:search-capacity-exhausted","status":429}"#
        : "{}"
      let fixture = HTTPRecoveryFixture(replies: [
        .success(
          HTTPRecoveryReply(
            status: status, body: body,
            headers: [
              "X-Request-ID": serverRequestID.uuidString,
              "X-Edge-Request-ID": "ABCDEF12345678901234567890ABCDEF",
            ]
          )),
        .success(.page),
      ])
      _ = try await fixture.service().search(request: request())

      XCTAssertEqual(fixture.requests.count, 2)
      XCTAssertEqual(fixture.events.map(\.httpStatus), [status, 200])
      XCTAssertEqual(fixture.events[0].serverRequestID, serverRequestID)
      XCTAssertEqual(
        fixture.events[0].edgeRequestID, UUID(uuidString: "ABCDEF12-3456-7890-1234-567890ABCDEF"))
      XCTAssertEqual(fixture.events.map(\.outcome), [.retryScheduled, .recovered])
    }
  }

  func testPreparingExpiredSnapshotAndPermanentResponsesDoNotRetry() async throws {
    let cases: [(Int, String, CandidateSearchServiceError)] = [
      (503, "projection-unavailable", .dataPreparing),
      (503, "food-poi-unavailable", .foodDataPreparing),
      (409, "invalid-pagination-token", .snapshotExpired),
      (403, "forbidden", .invalidResponse),
      (429, "unknown-throttle", .invalidResponse),
    ]
    for (status, type, expectedError) in cases {
      let fixture = HTTPRecoveryFixture(replies: [
        .success(
          HTTPRecoveryReply(
            status: status,
            body: "{\"type\":\"urn:nextstop:error:\(type)\",\"status\":\(status)}"
          )),
        .success(.page),
      ])
      do {
        _ = try await fixture.service().search(request: request())
        XCTFail("Semantic and permanent failures must preserve their existing action")
      } catch {
        XCTAssertEqual(error as? CandidateSearchServiceError, expectedError)
      }
      XCTAssertEqual(fixture.requests.count, 1)
      XCTAssertEqual(fixture.waits, [])
      XCTAssertEqual(fixture.events.map(\.outcome), [.failure])
    }
  }

  func testRetryAfterSecondsAndHTTPDateAreHonored() async throws {
    for header in ["1", "Fri, 15 Jan 2027 08:00:01 GMT"] {
      let fixture = HTTPRecoveryFixture(replies: [
        .success(HTTPRecoveryReply(status: 503, headers: ["Retry-After": header])),
        .success(.page),
      ])
      _ = try await fixture.service().search(request: request())
      // The HTTP response consumes 100 ms of the injected clock. An absolute
      // server date therefore has 900 ms remaining; delta-seconds starts now.
      XCTAssertEqual(
        fixture.waits.map { Int(($0 * 1_000).rounded()) }, [header == "1" ? 1_000 : 900])
      XCTAssertEqual(fixture.requests.count, 2)
    }
  }

  func testLongOrInvalidRetryAfterNeverTriggersAnEarlyRetry() async throws {
    for header in [
      "3", "60", "-1", "invalid", "Fri, 15 Jan 2027 08:01:00 GMT",
      "Fri, 15 Jan 2027 08:00:01 GMT ignored",
    ] {
      let fixture = HTTPRecoveryFixture(replies: [
        .success(HTTPRecoveryReply(status: 503, headers: ["Retry-After": header])),
        .success(.page),
      ])
      do {
        _ = try await fixture.service().search(request: request())
        XCTFail("Do not shorten or guess an unsupported server-requested backoff")
      } catch {
        XCTAssertEqual(error as? CandidateSearchServiceError, .unavailable)
      }
      XCTAssertEqual(fixture.requests.count, 1)
      XCTAssertEqual(fixture.waits, [])
      XCTAssertEqual(fixture.events.map(\.outcome), [.failure])
    }
  }

  func testTransientRetryBudgetSurvivesAuthenticationRefreshInEitherOrder() async throws {
    let unauthorized = HTTPRecoveryReply(status: 401)
    let sequences: [[Result<HTTPRecoveryReply, Error>]] = [
      [.failure(URLError(.timedOut)), .success(unauthorized), .failure(URLError(.timedOut))],
      [.success(unauthorized), .failure(URLError(.timedOut)), .failure(URLError(.timedOut))],
    ]
    for replies in sequences {
      let fixture = HTTPRecoveryFixture(replies: replies + [.success(.page)])
      do {
        _ = try await fixture.service().search(request: request())
        XCTFail("Auth refresh must not grant a second transient retry")
      } catch {
        XCTAssertEqual(error as? CandidateSearchServiceError, .unavailable)
      }
      let refreshes = await fixture.tokens.refreshes
      XCTAssertEqual(refreshes, [false, true])
      XCTAssertEqual(fixture.requests.count, 3)
      XCTAssertEqual(fixture.waits, [0.4])
      XCTAssertEqual(
        fixture.requests.map(\.httpBody), Array(repeating: fixture.requests[0].httpBody, count: 3))
      XCTAssertEqual(fixture.events.map(\.attempt), [1, 2, 3])
    }
  }

  func testAuthRefreshAndTransientRetryCanRecoverTogether() async throws {
    let fixture = HTTPRecoveryFixture(replies: [
      .success(HTTPRecoveryReply(status: 401)),
      .failure(URLError(.networkConnectionLost)), .success(.page),
    ])
    _ = try await fixture.service().search(request: request())

    XCTAssertEqual(fixture.requests.count, 3)
    XCTAssertEqual(fixture.events.map(\.outcome), [.retryScheduled, .retryScheduled, .recovered])
    XCTAssertEqual(
      fixture.requests[0].value(forHTTPHeaderField: "Authorization"),
      "Bearer " + String(repeating: "a", count: 32))
    XCTAssertEqual(
      fixture.requests[1].value(forHTTPHeaderField: "Authorization"),
      "Bearer " + String(repeating: "b", count: 32))
    XCTAssertEqual(fixture.requests[1].allHTTPHeaderFields, fixture.requests[2].allHTTPHeaderFields)
  }

  func testSecondUnauthorizedStopsAndAuthenticationFailuresAreDiagnosed() async throws {
    let fixture = HTTPRecoveryFixture(replies: [
      .success(HTTPRecoveryReply(status: 401)), .success(HTTPRecoveryReply(status: 401)),
      .success(.page),
    ])
    do {
      _ = try await fixture.service().search(request: request())
      XCTFail("A second unauthorized response must stop")
    } catch {
      XCTAssertEqual(error as? CandidateSearchServiceError, .authenticationUnavailable)
    }
    XCTAssertEqual(fixture.requests.count, 2)
    XCTAssertEqual(fixture.waits, [])
    XCTAssertEqual(fixture.events.map(\.outcome), [.retryScheduled, .failure])

    let missingCredentials = HTTPRecoveryFixture(replies: [.success(.page)])
    let service = HTTPCandidateSearchService(
      baseURL: URL(string: "https://api.nextstop.test"), accessTokenProvider: nil,
      diagnostics: missingCredentials
    )
    do {
      _ = try await service.search(request: request())
      XCTFail("No request can be sent without credentials")
    } catch {
      XCTAssertEqual(error as? CandidateSearchServiceError, .invalidConfiguration)
    }
    XCTAssertEqual(missingCredentials.events.map(\.operation), [.authentication])
    XCTAssertEqual(missingCredentials.events.map(\.category), [.authentication])
  }

  func testCancellationAndCertificateFailuresAreNeverRetried() async throws {
    let cancellations: [Error] = [CancellationError(), URLError(.cancelled)]
    for cancellation in cancellations {
      let fixture = HTTPRecoveryFixture(replies: [.failure(cancellation), .success(.page)])
      do {
        _ = try await fixture.service().search(request: request())
        XCTFail("Cancellation must propagate")
      } catch is CancellationError {
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.waits, [])
        XCTAssertEqual(fixture.events, [])
      }
    }
    let fixture = HTTPRecoveryFixture(replies: [
      .failure(URLError(.serverCertificateUntrusted)), .success(.page),
    ])
    do {
      _ = try await fixture.service().search(request: request())
      XCTFail("Certificate failures must not be retried")
    } catch {
      XCTAssertEqual(error as? CandidateSearchServiceError, .unavailable)
    }
    XCTAssertEqual(fixture.requests.count, 1)
    XCTAssertEqual(fixture.events.map(\.outcome), [.failure])
  }

  func testCancellationDuringRecoveryDelayPreventsAnotherRequest() async throws {
    let fixture = HTTPRecoveryFixture(replies: [.failure(URLError(.timedOut)), .success(.page)])
    let service = fixture.service(sleep: { _ in throw CancellationError() })
    do {
      _ = try await service.search(request: request())
      XCTFail("Cancellation during backoff must propagate")
    } catch is CancellationError {
      XCTAssertEqual(fixture.requests.count, 1)
    }
  }

  func testInvalidSuccessPayloadIsNotRetriedAndDoesNotRecordUntrustedHeader() async throws {
    let fixture = HTTPRecoveryFixture(replies: [
      .success(
        HTTPRecoveryReply(
          status: 200, body: "invalid-json",
          headers: [
            "X-Request-ID": "Bearer secret at 49.664160,11.470720"
          ])),
      .success(.page),
    ])
    do {
      _ = try await fixture.service().search(request: request())
      XCTFail("Schema failure must not be treated as temporary network loss")
    } catch {
      XCTAssertEqual(error as? CandidateSearchServiceError, .invalidResponse)
    }
    XCTAssertEqual(fixture.requests.count, 1)
    XCTAssertEqual(fixture.events.map(\.category), [.invalidResponse])
    XCTAssertNil(fixture.events[0].serverRequestID)
  }

  func testMalformedEdgeRequestIDsAreNotRecorded() async throws {
    for value in [
      "abcdef12-3456-7890-1234-567890abcdef",
      "ABCDEF12345678901234567890ABCDEG",
      String(repeating: "a", count: 31),
      String(repeating: "a", count: 33),
    ] {
      let fixture = HTTPRecoveryFixture(replies: [
        .success(
          HTTPRecoveryReply(
            status: 502,
            headers: [
              "Retry-After": "60", "X-Edge-Request-ID": value,
            ]))
      ])
      do {
        _ = try await fixture.service().search(request: request())
        XCTFail("The proxy failure remains unresolved")
      } catch {
        XCTAssertEqual(error as? CandidateSearchServiceError, .unavailable)
      }
      XCTAssertNil(fixture.events[0].edgeRequestID)
      XCTAssertNil(fixture.events[0].serverRequestID)
    }
  }

  private func request() throws -> RouteSearchRequest {
    try RouteSearchRequest(
      requestID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
      route: RoutePolyline(coordinates: [
        Coordinate(latitude: 49.664160, longitude: 11.470720),
        Coordinate(latitude: 51.337296, longitude: 12.3761666),
      ]),
      criteria: RideCriteria(
        distanceRange: .kilometers100To150, minimumChargingPoints: .eight,
        minimumPower: .twoHundred, foodChain: nil
      ),
      snapshotToken: "signed-snapshot",
      cursor: "signed-cursor"
    )
  }
}

@MainActor
private final class HTTPRecoveryFixture: AppDiagnosticRecording {
  var replies: [Result<HTTPRecoveryReply, Error>]
  var requests: [URLRequest] = []
  var waits: [TimeInterval] = []
  var events: [AppDiagnosticEvent] = []
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  let tokens = HTTPRecoveryTokenProvider()

  init(replies: [Result<HTTPRecoveryReply, Error>]) { self.replies = replies }

  func record(_ event: AppDiagnosticEvent) { events.append(event) }

  func service(sleep: HTTPCandidateSearchService.Sleep? = nil) -> HTTPCandidateSearchService {
    HTTPCandidateSearchService(
      baseURL: URL(string: "https://api.nextstop.test"),
      accessTokenProvider: tokens,
      load: { request in
        self.requests.append(request)
        self.now = self.now.addingTimeInterval(0.1)
        guard !self.replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = try self.replies.removeFirst().get()
        return (
          Data(reply.body.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        )
      },
      now: { self.now },
      sleep: sleep ?? { seconds in
        self.waits.append(seconds)
        self.now = self.now.addingTimeInterval(seconds)
      },
      diagnostics: self
    )
  }
}

private struct HTTPRecoveryReply: Sendable {
  let status: Int
  var body: String = "{}"
  var headers: [String: String] = [:]

  static let page = HTTPRecoveryReply(
    status: 200,
    body:
      #"{"snapshotToken":"snapshot-token","nextCursor":null,"generatedAt":"2026-08-15T13:33:35.000Z","candidates":[],"coverage":{"status":"complete","activeSources":["bundesnetzagentur_ladesaeulenregister"],"unavailableSources":[],"projectionUpdatedAt":"2026-08-15T13:33:34.000Z"},"attributions":[]}"#
  )
}

private actor HTTPRecoveryTokenProvider: SearchAccessTokenProviding {
  private(set) var refreshes: [Bool] = []
  func accessToken(forceRefresh: Bool) async throws -> String {
    refreshes.append(forceRefresh)
    return String(repeating: forceRefresh ? "b" : "a", count: 32)
  }
}
