import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class CandidateSearchResponseDTOTests: XCTestCase {
  func testMapsCandidateResponseIntoValidatedDomainValues() throws {
    let page = try decodePage(candidates: [candidateJSON(lowerBound: 12_000)])

    XCTAssertEqual(page.snapshotToken, "snapshot-token")
    XCTAssertNil(page.nextCursor)
    XCTAssertEqual(page.coverage.status, .degraded)
    XCTAssertEqual(page.coverage.unavailableSourceIDs, ["ich_tanke_strom:live"])
    XCTAssertEqual(page.candidates.count, 1)
    let candidate = try XCTUnwrap(page.candidates.first)
    XCTAssertEqual(candidate.park.name, "Autohof Nord")
    XCTAssertEqual(candidate.park.chargingPointCount, 4)
    XCTAssertEqual(
      candidate.park.operatorChargingPoints,
      [try OperatorChargingPointSummary(name: "Operator", chargingPointCount: 4)]
    )
    XCTAssertEqual(candidate.park.availability.unknownCount, 4)
    XCTAssertEqual(candidate.park.maximumPower, Kilowatts(150))
    XCTAssertEqual(candidate.park.locationLookups.first?.operatorName, "Operator")
    XCTAssertEqual(candidate.park.locationLookups.first?.address.postalCode, "60389")
    XCTAssertEqual(candidate.distanceFromRoute, Meters(321))
    XCTAssertEqual(candidate.straightLineLowerBound, Meters(12_000))
    XCTAssertEqual(candidate.park.sourceReferences.first?.sourceID, "bundesnetzagentur")
    XCTAssertEqual(candidate.foodPOIs.first?.name, "McDonald's")
    XCTAssertEqual(candidate.foodPOIs.first?.distanceFromPark, Meters(250))
    XCTAssertEqual(page.attributions.first?.notice, "© OpenStreetMap contributors")
  }

  func testRejectsAvailabilityCompletenessContradiction() throws {
    let invalid = candidateJSON(lowerBound: 12_000)
      .replacingOccurrences(of: #""complete": false"#, with: #""complete": true"#)

    XCTAssertThrowsError(try decodePage(candidates: [invalid]))
  }

  func testRejectsOperatorCountsThatDoNotMatchParkTotal() throws {
    let invalid = candidateJSON(lowerBound: 12_000)
      .replacingOccurrences(of: #""chargingPoints": 4}]"#, with: #""chargingPoints": 3}]"#)

    XCTAssertThrowsError(try decodePage(candidates: [invalid]))
  }

  func testRejectsLocationLookupForOperatorOutsidePowerFilteredPark() throws {
    let invalid = candidateJSON(lowerBound: 12_000)
      .replacingOccurrences(
        of: #""operatorName": "Operator""#,
        with: #""operatorName": "Filtered Out Operator""#
      )

    XCTAssertThrowsError(try decodePage(candidates: [invalid]))
  }

  func testRejectsCandidatesNotOrderedBySafeLowerBound() throws {
    XCTAssertThrowsError(
      try decodePage(candidates: [
        candidateJSON(idSuffix: 1, lowerBound: 20_000),
        candidateJSON(idSuffix: 2, lowerBound: 10_000),
      ])
    )
  }

  func testMapsKnownProblemTypesToActionableFailures() {
    let preparing = Data(
      #"{"type":"urn:nextstop:error:projection-unavailable","status":503}"#.utf8
    )
    let expired = Data(
      #"{"type":"urn:nextstop:error:invalid-pagination-token","status":409}"#.utf8
    )
    let foodPreparing = Data(
      #"{"type":"urn:nextstop:error:food-poi-unavailable","status":503}"#.utf8
    )
    let unauthorized = Data(
      #"{"type":"urn:nextstop:error:unauthorized","status":401}"#.utf8
    )
    let capacityExhausted = Data(
      #"{"type":"urn:nextstop:error:search-capacity-exhausted","status":429}"#.utf8
    )

    XCTAssertEqual(
      HTTPCandidateSearchService.error(for: 503, data: preparing),
      .dataPreparing
    )
    XCTAssertEqual(
      HTTPCandidateSearchService.error(for: 409, data: expired),
      .snapshotExpired
    )
    XCTAssertEqual(
      HTTPCandidateSearchService.error(for: 503, data: foodPreparing),
      .foodDataPreparing
    )
    XCTAssertEqual(
      HTTPCandidateSearchService.error(for: 401, data: unauthorized),
      .invalidConfiguration
    )
    XCTAssertEqual(
      HTTPCandidateSearchService.error(for: 429, data: capacityExhausted),
      .unavailable
    )
  }

  private func decodePage(candidates: [String]) throws -> CandidateSearchPage {
    let data = Data(
      """
      {
        "snapshotToken": "snapshot-token",
        "nextCursor": null,
        "generatedAt": "2026-08-15T13:33:35.000Z",
        "candidates": [\(candidates.joined(separator: ","))],
        "coverage": {
          "status": "degraded",
          "activeSources": ["bundesnetzagentur_ladesaeulenregister", "ich_tanke_strom"],
          "unavailableSources": ["ich_tanke_strom:live"],
          "projectionUpdatedAt": "2026-08-15T13:33:34.000Z"
        },
        "attributions": [{
          "id": "openstreetmap_food_poi",
          "name": "OpenStreetMap",
          "notice": "© OpenStreetMap contributors",
          "licenseName": "Open Database License (ODbL) 1.0",
          "licenseURL": "https://www.openstreetmap.org/copyright",
          "transportName": "Geofabrik",
          "transportURL": "https://download.geofabrik.de/"
        }]
      }
      """.utf8
    )
    return try JSONDecoder().decode(CandidateSearchResponseDTO.self, from: data).domainPage()
  }

  private func candidateJSON(idSuffix: Int = 1, lowerBound: Int) -> String {
    let suffix = String(format: "%012d", idSuffix)
    return """
      {
        "id": "10000000-0000-4000-8000-\(suffix)",
        "name": "Autohof Nord",
        "coordinate": {"latitude": 53.55, "longitude": 10.0},
        "navigationCoordinate": {"latitude": 53.5501, "longitude": 10.0001},
        "distanceFromRouteMeters": 321,
        "straightLineLowerBoundMeters": \(lowerBound),
        "chargingPoints": 4,
        "availability": {
          "knownAvailable": 0,
          "knownUnavailable": 0,
          "unknown": 4,
          "total": 4,
          "complete": false,
          "observedAt": null
        },
        "maximumPowerKW": 150,
        "operators": ["Operator"],
        "operatorChargingPoints": [{"name": "Operator", "chargingPoints": 4}],
        "locationLookups": [{
          "id": "20000000-0000-4000-8000-000000000001",
          "operatorName": "Operator",
          "coordinate": {"latitude": 53.5501, "longitude": 10.0001},
          "address": {
            "street": "Friedberger Landstraße",
            "houseNumber": "291",
            "postalCode": "60389",
            "city": "Frankfurt am Main"
          }
        }],
        "sources": [{
          "id": "bundesnetzagentur",
          "name": "Bundesnetzagentur Ladesäulenregister",
          "qualityTier": "authority",
          "staticObservedAt": "2026-07-07T00:00:00.000Z"
        }],
        "dataUpdatedAt": "2026-07-07T00:00:00.000Z",
        "foodPOI": {
          "id": "osm:node:123",
          "chain": "mcdonalds",
          "name": "McDonald's",
          "coordinate": {"latitude": 53.5502, "longitude": 10.0002},
          "distanceFromChargingParkMeters": 250,
          "openingHours": null,
          "sourceRecordURL": "https://www.openstreetmap.org/node/123"
        }
      }
      """
  }
}
