import Foundation
import XCTest

@testable import NextStopCore

final class ChargingModelTests: XCTestCase {
  func testConnectorsDoNotDefineChargingPointCount() throws {
    let locationID = UUID()
    let connectorA = try ChargingConnector(
      id: "connector-a",
      standard: "ccs",
      maximumPower: Kilowatts(150)
    )
    let connectorB = try ChargingConnector(
      id: "connector-b",
      standard: "chademo",
      maximumPower: Kilowatts(50)
    )
    let chargingPoint = ChargingPoint(
      id: UUID(),
      canonicalEVSEIdentity: "DE*ABC*E123",
      locationID: locationID,
      operatorID: nil,
      connectors: [connectorA, connectorB],
      availability: Availability(
        state: .available,
        observedAt: Date(timeIntervalSince1970: 0),
        receivedAt: Date(timeIntervalSince1970: 0),
        isLive: true,
        freshness: .fresh
      ),
      powerCapability: PowerCapability(maximumPower: Kilowatts(150)),
      sourceReferences: []
    )

    XCTAssertEqual(chargingPoint.connectors.count, 2)
    XCTAssertEqual(Set([chargingPoint.id]).count, 1)
  }

  func testRouteRequiresAtLeastTwoCoordinates() throws {
    let coordinate = try Coordinate(latitude: 52, longitude: 10)

    XCTAssertThrowsError(try RoutePolyline(coordinates: [coordinate])) { error in
      XCTAssertEqual(error as? DomainValidationError, .routeRequiresAtLeastTwoCoordinates)
    }
  }

  func testRouteRejectsDegenerateCoordinates() throws {
    let coordinate = try Coordinate(latitude: 52, longitude: 10)

    XCTAssertThrowsError(try RoutePolyline(coordinates: [coordinate, coordinate])) { error in
      XCTAssertEqual(error as? DomainValidationError, .routeRequiresDistinctCoordinates)
    }
  }

  func testRouteRejectsMoreThanTransportMaximum() throws {
    let coordinates = try (0...SearchConfiguration.maximumRouteCoordinateCount).map { index in
      try Coordinate(latitude: 52, longitude: 10 + (Double(index) / 1_000_000))
    }

    XCTAssertThrowsError(try RoutePolyline(coordinates: coordinates)) { error in
      XCTAssertEqual(
        error as? DomainValidationError,
        .routeHasTooManyCoordinates(
          maximum: SearchConfiguration.maximumRouteCoordinateCount,
          actual: SearchConfiguration.maximumRouteCoordinateCount + 1
        )
      )
    }
  }

  func testRouteAcceptsSupportedEnvelopeBoundaries() throws {
    let routes = [
      [
        try Coordinate(latitude: 34, longitude: -25),
        try Coordinate(latitude: 34, longitude: -24.999),
      ],
      [
        try Coordinate(latitude: 72, longitude: 44.999),
        try Coordinate(latitude: 72, longitude: 45),
      ],
    ]

    for coordinates in routes {
      XCTAssertNoThrow(try RoutePolyline(coordinates: coordinates))
    }
  }

  func testRouteRejectsCoordinateOutsideSupportedEnvelope() throws {
    let supportedCoordinate = try Coordinate(latitude: 47, longitude: 8)
    let unsupportedCoordinates = [
      try Coordinate(latitude: 33.999_999, longitude: 8),
      try Coordinate(latitude: 72.000_001, longitude: 8),
      try Coordinate(latitude: 47, longitude: -25.000_001),
      try Coordinate(latitude: 47, longitude: 45.000_001),
    ]

    for unsupportedCoordinate in unsupportedCoordinates {
      XCTAssertThrowsError(
        try RoutePolyline(coordinates: [supportedCoordinate, unsupportedCoordinate])
      ) { error in
        XCTAssertEqual(
          error as? DomainValidationError,
          .routeCoordinateOutsideSupportedEnvelope(
            index: 1,
            latitude: unsupportedCoordinate.latitude,
            longitude: unsupportedCoordinate.longitude
          )
        )
      }
    }
  }

  func testRouteAcceptsSegmentBelowMaximumLength() throws {
    let coordinates = [
      try Coordinate(latitude: 50, longitude: 8),
      try Coordinate(latitude: 52.24, longitude: 8),
    ]

    XCTAssertNoThrow(try RoutePolyline(coordinates: coordinates))
  }

  func testRouteRejectsSegmentAboveMaximumLength() throws {
    let coordinates = [
      try Coordinate(latitude: 50, longitude: 8),
      try Coordinate(latitude: 52.26, longitude: 8),
    ]

    XCTAssertThrowsError(try RoutePolyline(coordinates: coordinates)) { error in
      guard let validationError = error as? DomainValidationError else {
        return XCTFail("Expected a domain validation error, got \(error)")
      }
      guard
        case .routeSegmentExceedsMaximumLength(let startIndex, let maximum, let actual) =
          validationError
      else {
        return XCTFail("Expected an overlong-segment error, got \(validationError)")
      }

      XCTAssertEqual(startIndex, 0)
      XCTAssertEqual(maximum, SearchConfiguration.maximumRouteSegmentLength)
      XCTAssertGreaterThan(actual, SearchConfiguration.maximumRouteSegmentLength)
    }
  }

  func testRouteRejectsTotalLengthAboveMaximum() throws {
    let first = try Coordinate(latitude: 50, longitude: 8)
    let second = try Coordinate(latitude: 52, longitude: 8)
    let coordinates = (0...12).map { $0.isMultiple(of: 2) ? first : second }

    XCTAssertThrowsError(try RoutePolyline(coordinates: coordinates)) { error in
      guard let validationError = error as? DomainValidationError else {
        return XCTFail("Expected a domain validation error, got \(error)")
      }
      guard case .routeExceedsMaximumLength(let maximum, let actual) = validationError else {
        return XCTFail("Expected an overlong-route error, got \(validationError)")
      }

      XCTAssertEqual(maximum, SearchConfiguration.maximumRouteLength)
      XCTAssertGreaterThan(actual, SearchConfiguration.maximumRouteLength)
    }
  }

  func testRouteAcceptsTotalLengthBelowMaximum() throws {
    let first = try Coordinate(latitude: 50, longitude: 8)
    let second = try Coordinate(latitude: 52, longitude: 8)
    let coordinates = (0...11).map { $0.isMultiple(of: 2) ? first : second }

    XCTAssertNoThrow(try RoutePolyline(coordinates: coordinates))
  }

  func testGeodesicDistanceMatchesWGS84RegressionValue() throws {
    let flindersPeak = try Coordinate(
      latitude: -37.951_033_416_7,
      longitude: 144.424_867_888_9
    )
    let buninyong = try Coordinate(
      latitude: -37.652_821_138_9,
      longitude: 143.926_495_527_8
    )

    XCTAssertEqual(
      Geodesy.distanceMeters(from: flindersPeak, to: buninyong),
      54_972.271,
      accuracy: 0.001
    )
  }

  func testRepresentativeEuropeanRouteRemainsValid() throws {
    let coordinates = [
      try Coordinate(latitude: 48.137_154, longitude: 11.576_124),
      try Coordinate(latitude: 49.452_102, longitude: 11.076_665),
      try Coordinate(latitude: 50.110_924, longitude: 8.682_127),
      try Coordinate(latitude: 50.984_768, longitude: 11.029_88),
      try Coordinate(latitude: 51.339_695, longitude: 12.373_075),
      try Coordinate(latitude: 52.520_008, longitude: 13.404_954),
    ]

    XCTAssertNoThrow(try RoutePolyline(coordinates: coordinates))
  }
}
