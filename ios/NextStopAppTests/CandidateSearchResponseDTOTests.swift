import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

final class CandidateSearchResponseDTOTests: XCTestCase {
  func testMapsCandidateResponseIntoValidatedDomainValues() throws {
    let page = try decodePage(candidates: [candidateJSON(lowerBound: 12_000)])

    XCTAssertEqual(page.snapshotToken, "snapshot-token")
    XCTAssertNil(page.nextCursor)
    XCTAssertEqual(page.candidates.count, 1)
    let candidate = try XCTUnwrap(page.candidates.first)
    XCTAssertEqual(candidate.park.name, "Autohof Nord")
    XCTAssertEqual(candidate.park.chargingPointCount, 4)
    XCTAssertEqual(candidate.park.availability.unknownCount, 4)
    XCTAssertEqual(candidate.park.maximumPower, Kilowatts(150))
    XCTAssertEqual(candidate.distanceFromRoute, Meters(321))
    XCTAssertEqual(candidate.straightLineLowerBound, Meters(12_000))
    XCTAssertEqual(candidate.park.sourceReferences.first?.sourceID, "bundesnetzagentur")
  }

  func testRejectsAvailabilityCompletenessContradiction() throws {
    let invalid = candidateJSON(lowerBound: 12_000)
      .replacingOccurrences(of: #""complete": false"#, with: #""complete": true"#)

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

  private func decodePage(candidates: [String]) throws -> CandidateSearchPage {
    let data = Data(
      """
      {
        "snapshotToken": "snapshot-token",
        "nextCursor": null,
        "candidates": [\(candidates.joined(separator: ","))]
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
        "sources": [{
          "id": "bundesnetzagentur",
          "name": "Bundesnetzagentur Ladesäulenregister",
          "qualityTier": "authority",
          "staticObservedAt": "2026-07-07T00:00:00.000Z"
        }],
        "dataUpdatedAt": "2026-07-07T00:00:00.000Z"
      }
      """
  }
}
