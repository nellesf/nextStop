import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

final class CandidateSearchRequestDTOTests: XCTestCase {
  func testFirstPageMatchesOpenAPIAndContainsNoProfileOrDestinationData() throws {
    let request = RouteSearchRequest(
      requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      route: try RoutePolyline(
        coordinates: [
          Coordinate(latitude: 48.1372, longitude: 11.5756),
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
      #"{"criteria":{"distanceRangeMeters":{"maximum":150000,"minimum":100000},"foodChain":"burger_king","minimumChargingPoints":8,"minimumPowerKW":150},"requestId":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","route":{"coordinates":[[11.5756,48.1372],[13.3694,52.5251]],"type":"LineString"}}"#
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
}
