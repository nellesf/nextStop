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
}
