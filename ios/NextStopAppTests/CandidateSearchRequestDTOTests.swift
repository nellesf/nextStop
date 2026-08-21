import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class CandidateSearchRequestDTOTests: XCTestCase {
  func testHTTPServiceAddsConfiguredBearerCredential() throws {
    let token = String(repeating: "a", count: 64)
    let service = HTTPCandidateSearchService(
      baseURL: URL(string: "https://api.nextstop.tech"),
      bearerToken: token
    )

    let request = try service.makeURLRequest(request: makeSearchRequest())

    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://api.nextstop.tech/v1/charging-parks/search"
    )
  }

  func testHTTPServiceFailsClosedWithoutValidBearerCredential() throws {
    let invalidTokens: [String?] = [
      nil, "", "short", "$(NEXTSTOP_API_BEARER_TOKEN)", "valid token with spaces",
    ]
    for token in invalidTokens {
      let service = HTTPCandidateSearchService(
        baseURL: URL(string: "https://api.nextstop.tech"),
        bearerToken: token
      )

      XCTAssertThrowsError(try service.makeURLRequest(request: makeSearchRequest())) { error in
        XCTAssertEqual(error as? CandidateSearchServiceError, .invalidConfiguration)
      }
    }
  }

  func testFirstPageMatchesOpenAPIAndContainsNoProfileOrDestinationData() throws {
    let request = RouteSearchRequest(
      requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      route: try RoutePolyline(
        coordinates: [
          Coordinate(latitude: 48.1372, longitude: 11.5756),
          Coordinate(latitude: 49.1, longitude: 11.9),
          Coordinate(latitude: 50.1, longitude: 12.2),
          Coordinate(latitude: 51.1, longitude: 12.6),
          Coordinate(latitude: 52.1, longitude: 13.0),
          Coordinate(latitude: 52.5251, longitude: 13.3694),
        ]
      ),
      criteria: RideCriteria(
        distanceRange: .kilometers100To150,
        minimumChargingPoints: .eight,
        minimumPower: .oneHundredFifty,
        foodChain: .burgerKing
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let data = try encoder.encode(CandidateSearchRequestDTO(request: request))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertEqual(
      json,
      #"{"criteria":{"distanceRangeMeters":{"maximum":150000,"minimum":100000},"foodChain":"burger_king","minimumChargingPoints":8,"minimumPowerKW":150},"requestId":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","route":{"coordinates":[[11.5756,48.1372],[11.9,49.1],[12.2,50.1],[12.6,51.1],[13,52.1],[13.3694,52.5251]],"type":"LineString"}}"#
    )
    XCTAssertFalse(json.localizedCaseInsensitiveContains("profile"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("destination"))
    XCTAssertFalse(json.contains("Berlin"))
  }

  func testLaterPageIncludesOnlySnapshotTokenAndCursor() throws {
    let request = RouteSearchRequest(
      requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      route: try RoutePolyline(
        coordinates: [
          Coordinate(latitude: 50, longitude: 8),
          Coordinate(latitude: 51, longitude: 9),
        ]
      ),
      criteria: SearchConfiguration.defaultCriteria,
      snapshotToken: "snapshot-1",
      cursor: "cursor-2"
    )

    let data = try JSONEncoder().encode(CandidateSearchRequestDTO(request: request))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let page = try XCTUnwrap(object["page"] as? [String: Any])
    let criteria = try XCTUnwrap(object["criteria"] as? [String: Any])

    XCTAssertEqual(page["snapshotToken"] as? String, "snapshot-1")
    XCTAssertEqual(page["cursor"] as? String, "cursor-2")
    XCTAssertEqual(Set(page.keys), ["snapshotToken", "cursor"])
    XCTAssertNil(criteria["foodChain"])
  }

  private func makeSearchRequest() throws -> RouteSearchRequest {
    RouteSearchRequest(
      requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      route: try RoutePolyline(
        coordinates: [
          Coordinate(latitude: 48.1372, longitude: 11.5756),
          Coordinate(latitude: 49.1, longitude: 11.9),
          Coordinate(latitude: 50.1, longitude: 12.2),
          Coordinate(latitude: 51.1, longitude: 12.6),
          Coordinate(latitude: 52.1, longitude: 13.0),
          Coordinate(latitude: 52.5251, longitude: 13.3694),
        ]
      ),
      criteria: SearchConfiguration.defaultCriteria
    )
  }
}
