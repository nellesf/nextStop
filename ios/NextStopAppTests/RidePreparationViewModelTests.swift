import Foundation
import NextStopCore
import XCTest

@testable import NextStopApp

@MainActor
final class RidePreparationViewModelTests: XCTestCase {
  func testAppleChargingLookupScopeIncludesSameOperatorAtExactSameAddress() throws {
    let sharedAddress = ChargingLocationAddress(
      street: "Am Fuchsenacker",
      houseNumber: "2",
      postalCode: "97877",
      city: "Wertheim"
    )
    let primary = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "HomE of Mobility GmbH",
      coordinate: Coordinate(latitude: 49.772275, longitude: 9.587747),
      address: sharedAddress
    )
    let related = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "HomE of Mobility GmbH",
      coordinate: Coordinate(latitude: 49.772468, longitude: 9.585005),
      address: sharedAddress
    )
    let differentAddress = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "HomE of Mobility GmbH",
      coordinate: Coordinate(latitude: 49.8, longitude: 9.6),
      address: ChargingLocationAddress(
        street: "Other Street",
        houseNumber: "1",
        postalCode: "97877",
        city: "Wertheim"
      )
    )
    let otherOperator = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "Other operator",
      coordinate: Coordinate(latitude: 49.772468, longitude: 9.585005),
      address: sharedAddress
    )

    let locations = AppleChargingPlaceLookupScope.relatedLocations(
      primaryLocations: [primary],
      candidateLocations: [primary, related, differentAddress, otherOperator],
      operatorName: "HomE of Mobility GmbH"
    )

    XCTAssertEqual(Set(locations.map(\.id)), Set([primary.id, related.id]))
  }

  func testAppleChargingLookupScopeNormalizesEquivalentAddresses() {
    let first = ChargingLocationAddress(
      street: "Am Fuchsenacker",
      houseNumber: "2",
      postalCode: "97877",
      city: "Wertheim"
    )
    let second = ChargingLocationAddress(
      street: "am-fuchsenacker",
      houseNumber: " 2 ",
      postalCode: "97877",
      city: "WERTHEIM"
    )

    XCTAssertEqual(
      AppleChargingPlaceLookupScope.addressKey(first),
      AppleChargingPlaceLookupScope.addressKey(second)
    )
  }

  func testAppleChargingCacheAddressSignatureIncludesPartialLocalityEvidence() {
    let first = ChargingLocationAddress(
      street: nil,
      houseNumber: nil,
      postalCode: " 97877 ",
      city: "WERTHEIM"
    )
    let equivalent = ChargingLocationAddress(
      street: nil,
      houseNumber: nil,
      postalCode: "97877",
      city: "Wertheim"
    )
    let changedPostalCode = ChargingLocationAddress(
      street: nil,
      houseNumber: nil,
      postalCode: "97878",
      city: "Wertheim"
    )
    let missingPostalCode = ChargingLocationAddress(
      street: nil,
      houseNumber: nil,
      postalCode: nil,
      city: "Wertheim"
    )

    XCTAssertEqual(
      AppleChargingPlaceLookupScope.addressEvidenceSignature(first),
      AppleChargingPlaceLookupScope.addressEvidenceSignature(equivalent)
    )
    XCTAssertNotEqual(
      AppleChargingPlaceLookupScope.addressEvidenceSignature(first),
      AppleChargingPlaceLookupScope.addressEvidenceSignature(changedPostalCode)
    )
    XCTAssertNotEqual(
      AppleChargingPlaceLookupScope.addressEvidenceSignature(first),
      AppleChargingPlaceLookupScope.addressEvidenceSignature(missingPostalCode)
    )
  }

  func testRestaurantGroupLookupScopeIncludesEveryExactOperatorLocation() throws {
    let first = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "IONITY",
      coordinate: Coordinate(latitude: 50.001, longitude: 8),
      address: ChargingLocationAddress(
        street: "First Street",
        houseNumber: "1",
        postalCode: "10000",
        city: "First City"
      )
    )
    let second = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "IONITY",
      coordinate: Coordinate(latitude: 50.01, longitude: 8.01),
      address: ChargingLocationAddress(
        street: "Second Street",
        houseNumber: "2",
        postalCode: "20000",
        city: "Second City"
      )
    )
    let differentlyNamedOperator = try ChargingLocationLookup(
      id: UUID(),
      operatorName: "Ionity GmbH",
      coordinate: Coordinate(latitude: 50.02, longitude: 8.02),
      address: ChargingLocationAddress()
    )

    let locations = AppleChargingPlaceLookupScope.restaurantGroupLocations(
      candidateLocations: [first, second, first, differentlyNamedOperator],
      operatorName: "IONITY"
    )

    XCTAssertEqual(locations.map(\.id), [first.id, second.id])
  }

  func testZuchwilRestaurantGroupSuppliesOnlyAutosenseOperatorEvidence() throws {
    let firstAutosense = try ChargingLocationLookup(
      id: UUID(uuidString: "048cca5e-9d48-8221-a72e-14a4f5dba8e9")!,
      operatorName: "Autosense",
      coordinate: Coordinate(latitude: 47.202427, longitude: 7.571513),
      address: ChargingLocationAddress(
        street: "Langenfeldstrasse",
        houseNumber: nil,
        postalCode: "4528",
        city: "Zuchwil"
      )
    )
    let secondAutosense = try ChargingLocationLookup(
      id: UUID(uuidString: "7a9b25a9-3a18-8f5c-a991-7a1722a960ec")!,
      operatorName: "Autosense",
      coordinate: Coordinate(latitude: 47.202427, longitude: 7.571513),
      address: firstAutosense.address
    )
    let goFast = try ChargingLocationLookup(
      id: UUID(uuidString: "2cfe6e20-b831-8dd0-90a0-4c427c00dc57")!,
      operatorName: "GoFast",
      coordinate: Coordinate(latitude: 47.20167023, longitude: 7.57141471),
      address: ChargingLocationAddress(
        street: "Schützenweg",
        houseNumber: "2",
        postalCode: "4528",
        city: "Zuchwil"
      )
    )

    let locations = AppleChargingPlaceLookupScope.restaurantGroupLocations(
      candidateLocations: [firstAutosense, goFast, firstAutosense, secondAutosense],
      operatorName: "Autosense"
    )

    XCTAssertEqual(locations.map(\.id), [firstAutosense.id, secondAutosense.id])
    XCTAssertTrue(locations.allSatisfy { $0.operatorName == "Autosense" })
  }

  func testChargingSearchCentersIncludeGroupNavigationsAndDeduplicateNearbyCoordinates()
    throws
  {
    let park = try Coordinate(latitude: 50, longitude: 8)
    let operatorNearPark = try Coordinate(latitude: 50.0001, longitude: 8)
    let operatorCenter = try Coordinate(latitude: 50.001, longitude: 8)
    let groupNearOperator = try Coordinate(latitude: 50.0011, longitude: 8)
    let groupCenter = try Coordinate(latitude: 50.002, longitude: 8)

    let centers = AppleChargingPlaceSearchCenterPolicy.centers(
      parkNavigationCoordinate: park,
      operatorCoordinates: [operatorNearPark, operatorCenter],
      resultGroupCoordinates: [park, groupNearOperator, groupCenter]
    )

    XCTAssertEqual(centers, [park, operatorCenter, groupCenter])
  }

  func testResultGroupFallbackRequiresEverySearchCenterInEachUsedPass() {
    XCTAssertTrue(
      AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
        categoryPassComplete: true
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
        categoryPassComplete: false
      )
    )
    XCTAssertTrue(
      AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
        categoryPassComplete: true,
        naturalLanguagePassComplete: false
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceSearchCompletionPolicy.allowsResultGroupFallback(
        categoryPassComplete: false,
        naturalLanguagePassComplete: true
      )
    )
  }

  func testPrimaryChargingPlaceMatchKeepsDirectAndExactAddressBounds() {
    XCTAssertTrue(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 60,
        hasExactAddressMatch: false
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 61,
        hasExactAddressMatch: false
      )
    )
    XCTAssertTrue(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 300,
        hasExactAddressMatch: true
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.accepts(
        distanceMeters: 301,
        hasExactAddressMatch: true
      )
    )
  }

  func testResultGroupFallbackCanonicalOperatorKeyMustBeNonempty() {
    XCTAssertTrue(
      AppleChargingPlaceMatchPolicy.canonicalOperatorKeysMatch("tesla", "tesla")
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.canonicalOperatorKeysMatch("", "")
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.canonicalOperatorKeysMatch("tesla", "")
    )
    XCTAssertFalse(
      AppleChargingPlaceMatchPolicy.canonicalOperatorKeysMatch("tesla", "ionity")
    )
  }

  func testKnownChargingCatalogAliasIsExactAndDoesNotMatchBroadAMAGNames() {
    XCTAssertTrue(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: "AMAG Energy Charging",
        requestedOperatorName: "Autosense"
      )
    )
    XCTAssertTrue(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: " amag energy charging ",
        requestedOperatorName: "AUTOSENSE"
      )
    )
    XCTAssertFalse(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: "AMAG",
        requestedOperatorName: "Autosense"
      )
    )
    XCTAssertFalse(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: "AMAG Charging Station",
        requestedOperatorName: "Autosense"
      )
    )
    XCTAssertFalse(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: "AMAG Energy Charging Zürich",
        requestedOperatorName: "Autosense"
      )
    )
    XCTAssertFalse(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: "Autosense",
        requestedOperatorName: "Autosense"
      )
    )
    XCTAssertFalse(
      AppleChargingOperatorCatalog.isKnownAlias(
        applePlaceName: "AMAG Energy Charging",
        requestedOperatorName: "AMAG Energy Charging"
      )
    )
  }

  func testKnownCatalogAliasMatchAcceptsZuchwilShapeAtOneHundredMeters() {
    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(
          operatorDistanceMeters: 78,
          restaurantDistanceMeters: 51
        ),
        resultGroupKind: .restaurant
      ),
      .knownCatalogAlias(
        distanceMeters: 78,
        stablePlaceIdentifier: "IE82B5E47B23E56E7"
      )
    )
    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(
          operatorDistanceMeters: 100,
          restaurantDistanceMeters: 500
        ),
        resultGroupKind: .restaurant
      ),
      .knownCatalogAlias(
        distanceMeters: 100,
        stablePlaceIdentifier: "IE82B5E47B23E56E7"
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(
          operatorDistanceMeters: 101,
          restaurantDistanceMeters: 51
        ),
        resultGroupKind: .restaurant
      )
    )
  }

  func testKnownCatalogAliasMatchKeepsCategoryLocalityIdentityAndRestaurantBounds() {
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(operatorNamesAreKnownAliases: false),
        resultGroupKind: .restaurant
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(isEVCharger: false),
        resultGroupKind: .restaurant
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(hasOperatorLocalityMatch: false),
        resultGroupKind: .restaurant
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(stablePlaceIdentifier: nil),
        resultGroupKind: .restaurant
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(restaurantDistanceMeters: nil),
        resultGroupKind: .restaurant
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(restaurantDistanceMeters: 501),
        resultGroupKind: .restaurant
      )
    )
  }

  func testRestaurantResultGroupAcceptsWertheimShapedGeometryEvidence() {
    let match = AppleChargingPlaceMatchPolicy.match(
      evidence: resultGroupEvidence(
        resultGroupDistanceMeters: 57.2,
        restaurantDistanceMeters: 257.2
      ),
      resultGroupKind: .restaurant
    )

    XCTAssertEqual(
      match,
      .resultGroup(distanceMeters: 57.2, stablePlaceIdentifier: "I19TESLA")
    )
  }

  func testRestaurantResultGroupFallbackKeepsFiveHundredMeterBoundary() {
    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(restaurantDistanceMeters: 500),
        resultGroupKind: .restaurant
      ),
      .resultGroup(distanceMeters: 44, stablePlaceIdentifier: "I19TESLA")
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(restaurantDistanceMeters: 501),
        resultGroupKind: .restaurant
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(restaurantDistanceMeters: nil),
        resultGroupKind: .restaurant
      )
    )
  }

  func testResultGroupFallbackRejectsMissingGeometryEvidence() {
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(resultGroupDistanceMeters: nil),
        resultGroupKind: .noFoodCampus
      )
    )
  }

  func testResultGroupMatchPrefersOperatorScopedEvidence() {
    let evidence = AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: true,
      operatorScopedDistanceMeters: 60,
      hasExactOperatorAddressMatch: false,
      isEVCharger: true,
      resultGroupDistanceMeters: 20,
      hasOperatorLocalityMatch: true,
      restaurantDistanceMeters: nil,
      stablePlaceIdentifier: "I19TESLA"
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: evidence,
        resultGroupKind: .restaurant
      ),
      .operatorScoped(distanceMeters: 60)
    )
  }

  func testResultGroupMatchRejectsWrongCategoryLocalityAndCanonicalOperator() {
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(isEVCharger: false),
        resultGroupKind: .noFoodCampus
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(hasOperatorLocalityMatch: false),
        resultGroupKind: .noFoodCampus
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(canonicalOperatorNameMatches: false),
        resultGroupKind: .noFoodCampus
      )
    )
  }

  func testResultGroupMatchKeepsSixtyMeterBoundaryAndRequiresStableIdentity() {
    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(resultGroupDistanceMeters: 60),
        resultGroupKind: .noFoodCampus
      ),
      .resultGroup(distanceMeters: 60, stablePlaceIdentifier: "I19TESLA")
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(resultGroupDistanceMeters: 61),
        resultGroupKind: .noFoodCampus
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(stablePlaceIdentifier: nil),
        resultGroupKind: .noFoodCampus
      )
    )
  }

  func testResultGroupMatchRequiresOneStableApplePlaceIdentity() throws {
    let first = try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(stablePlaceIdentifier: "FIRST"),
        resultGroupKind: .noFoodCampus
      )
    )
    let duplicate = try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(stablePlaceIdentifier: "FIRST"),
        resultGroupKind: .noFoodCampus
      )
    )
    let second = try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(stablePlaceIdentifier: "SECOND"),
        resultGroupKind: .noFoodCampus
      )
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.unambiguousResultGroupPlaceIdentifier(
        in: [first, duplicate]
      ),
      "FIRST"
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.unambiguousResultGroupPlaceIdentifier(
        in: [first, second]
      )
    )
  }

  func testNaturalLanguageFallbackCorroboratesOneAmbiguousCategoryIdentity() throws {
    let first = try resultGroupMatch(stablePlaceIdentifier: "I5TESLA")
    let second = try resultGroupMatch(stablePlaceIdentifier: "I19TESLA")

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.naturalLanguageFallbackPlaceIdentifier(
        categoryMatches: [first, second],
        naturalLanguageMatches: [second],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      ),
      "I19TESLA"
    )
  }

  func testNaturalLanguageFallbackRejectsDisjointPassIdentities() throws {
    let category = try resultGroupMatch(stablePlaceIdentifier: "I5TESLA")
    let naturalLanguage = try resultGroupMatch(stablePlaceIdentifier: "I19TESLA")

    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.naturalLanguageFallbackPlaceIdentifier(
        categoryMatches: [category],
        naturalLanguageMatches: [naturalLanguage],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
  }

  func testNaturalLanguageFallbackRejectsMultipleSharedIdentities() throws {
    let first = try resultGroupMatch(stablePlaceIdentifier: "I5TESLA")
    let second = try resultGroupMatch(stablePlaceIdentifier: "I19TESLA")

    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.naturalLanguageFallbackPlaceIdentifier(
        categoryMatches: [first, second],
        naturalLanguageMatches: [first, second],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
  }

  func testNaturalLanguageFallbackRequiresCompletePasses() throws {
    let firstCategory = try resultGroupMatch(stablePlaceIdentifier: "I5TESLA")
    let secondCategory = try resultGroupMatch(stablePlaceIdentifier: "I19TESLA")
    let naturalLanguage = try resultGroupMatch(stablePlaceIdentifier: "I19TESLA")

    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.naturalLanguageFallbackPlaceIdentifier(
        categoryMatches: [firstCategory, secondCategory],
        naturalLanguageMatches: [naturalLanguage],
        categoryPassComplete: false,
        naturalLanguagePassComplete: true
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.naturalLanguageFallbackPlaceIdentifier(
        categoryMatches: [],
        naturalLanguageMatches: [naturalLanguage],
        categoryPassComplete: true,
        naturalLanguagePassComplete: false
      )
    )
  }

  func testNaturalLanguageFallbackAcceptsOneIdentityAfterEmptyCategoryPass() throws {
    let naturalLanguage = try resultGroupMatch(stablePlaceIdentifier: "I19TESLA")

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.naturalLanguageFallbackPlaceIdentifier(
        categoryMatches: [],
        naturalLanguageMatches: [naturalLanguage],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      ),
      "I19TESLA"
    )
  }

  func testKnownCatalogAliasRequiresSameUniqueIdentityAcrossBothCompletePasses() throws {
    let zuchwil = try knownCatalogAliasMatch(
      stablePlaceIdentifier: "IE82B5E47B23E56E7"
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil],
        naturalLanguageMatches: [zuchwil],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      ),
      "IE82B5E47B23E56E7"
    )
  }

  func testKnownCatalogAliasRejectsMissingOrDifferentCrossPassIdentity() throws {
    let zuchwil = try knownCatalogAliasMatch(
      stablePlaceIdentifier: "IE82B5E47B23E56E7"
    )
    let other = try knownCatalogAliasMatch(stablePlaceIdentifier: "OTHER")

    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [],
        naturalLanguageMatches: [zuchwil],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil],
        naturalLanguageMatches: [],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil],
        naturalLanguageMatches: [other],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
  }

  func testKnownCatalogAliasRejectsAmbiguousCrossPassIdentity() throws {
    let zuchwil = try knownCatalogAliasMatch(
      stablePlaceIdentifier: "IE82B5E47B23E56E7"
    )
    let other = try knownCatalogAliasMatch(stablePlaceIdentifier: "OTHER")

    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil, other],
        naturalLanguageMatches: [zuchwil],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil],
        naturalLanguageMatches: [zuchwil, other],
        categoryPassComplete: true,
        naturalLanguagePassComplete: true
      )
    )
  }

  func testKnownCatalogAliasRejectsIncompleteCrossPassSearches() throws {
    let zuchwil = try knownCatalogAliasMatch(
      stablePlaceIdentifier: "IE82B5E47B23E56E7"
    )

    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil],
        naturalLanguageMatches: [zuchwil],
        categoryPassComplete: false,
        naturalLanguagePassComplete: true
      )
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.corroboratedKnownCatalogAliasPlaceIdentifier(
        categoryMatches: [zuchwil],
        naturalLanguageMatches: [zuchwil],
        categoryPassComplete: true,
        naturalLanguagePassComplete: false
      )
    )
  }

  func testOperatorScopedMatchPreservesExistingBroaderNameRule() {
    let evidence = AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: false,
      operatorScopedDistanceMeters: 60,
      hasExactOperatorAddressMatch: false,
      isEVCharger: true,
      resultGroupDistanceMeters: nil,
      hasOperatorLocalityMatch: false,
      restaurantDistanceMeters: nil,
      stablePlaceIdentifier: nil
    )
    let wrongCategoryEvidence = AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: false,
      operatorScopedDistanceMeters: 60,
      hasExactOperatorAddressMatch: false,
      isEVCharger: false,
      resultGroupDistanceMeters: nil,
      hasOperatorLocalityMatch: false,
      restaurantDistanceMeters: nil,
      stablePlaceIdentifier: nil
    )

    XCTAssertEqual(
      AppleChargingPlaceMatchPolicy.match(
        evidence: evidence,
        resultGroupKind: .restaurant
      ),
      .operatorScoped(distanceMeters: 60)
    )
    XCTAssertNil(
      AppleChargingPlaceMatchPolicy.match(
        evidence: wrongCategoryEvidence,
        resultGroupKind: .restaurant
      )
    )
  }

  func testOperatorLocalityAcceptsCityOrPostalCode() {
    let operatorAddress = ChargingLocationAddress(
      street: "Am Fuchsenacker",
      houseNumber: "2",
      postalCode: "97877",
      city: "Wertheim"
    )

    XCTAssertTrue(
      AppleChargingPlaceLookupScope.localityMatches(
        "Almosenberg 12, Bettingen, 97877 Wertheim, Deutschland",
        referenceAddresses: [operatorAddress]
      )
    )
    XCTAssertTrue(
      AppleChargingPlaceLookupScope.localityMatches(
        "Andere Straße 1, Wertheim, Deutschland",
        referenceAddresses: [operatorAddress]
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceLookupScope.localityMatches(
        "Andere Straße 1, 97070 Würzburg, Deutschland",
        referenceAddresses: [operatorAddress]
      )
    )
    XCTAssertFalse(
      AppleChargingPlaceLookupScope.localityMatches(
        "Andere Straße 1, Hessen, Deutschland",
        referenceAddresses: [
          ChargingLocationAddress(
            street: nil,
            houseNumber: nil,
            postalCode: nil,
            city: "Essen"
          )
        ]
      )
    )
  }

  func testRestaurantResultFallbackQueryKeepsExactSelectedOperatorName() {
    XCTAssertEqual(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "  Tesla Germany GmbH  ",
        hasSecureCategoryMatch: false
      ),
      "Tesla Germany GmbH"
    )
    XCTAssertEqual(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "IONITY",
        hasSecureCategoryMatch: false
      ),
      "IONITY"
    )
  }

  func testChargingPlaceFallbackQueryRequiresCategoryMiss() {
    XCTAssertNil(
      AppleChargingPlaceSearchQuery.naturalLanguageQuery(
        for: "Tesla Germany GmbH",
        hasSecureCategoryMatch: true
      )
    )
  }

  private func resultGroupEvidence(
    canonicalOperatorNameMatches: Bool = true,
    isEVCharger: Bool = true,
    resultGroupDistanceMeters: Double? = 44,
    hasOperatorLocalityMatch: Bool = true,
    restaurantDistanceMeters: Double? = nil,
    stablePlaceIdentifier: String? = "I19TESLA"
  ) -> AppleChargingPlaceMatchPolicy.Evidence {
    AppleChargingPlaceMatchPolicy.Evidence(
      operatorNameMatches: true,
      canonicalOperatorNameMatches: canonicalOperatorNameMatches,
      operatorScopedDistanceMeters: nil,
      hasExactOperatorAddressMatch: false,
      isEVCharger: isEVCharger,
      resultGroupDistanceMeters: resultGroupDistanceMeters,
      hasOperatorLocalityMatch: hasOperatorLocalityMatch,
      restaurantDistanceMeters: restaurantDistanceMeters,
      stablePlaceIdentifier: stablePlaceIdentifier
    )
  }

  private func resultGroupMatch(
    stablePlaceIdentifier: String
  ) throws -> AppleChargingPlaceMatchPolicy.Match {
    try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.match(
        evidence: resultGroupEvidence(
          stablePlaceIdentifier: stablePlaceIdentifier
        ),
        resultGroupKind: .noFoodCampus
      )
    )
  }

  private func knownCatalogAliasEvidence(
    operatorNamesAreKnownAliases: Bool = true,
    operatorDistanceMeters: Double? = 78,
    isEVCharger: Bool = true,
    hasOperatorLocalityMatch: Bool = true,
    restaurantDistanceMeters: Double? = 51,
    stablePlaceIdentifier: String? = "IE82B5E47B23E56E7"
  ) -> AppleChargingPlaceMatchPolicy.KnownCatalogAliasEvidence {
    AppleChargingPlaceMatchPolicy.KnownCatalogAliasEvidence(
      operatorNamesAreKnownAliases: operatorNamesAreKnownAliases,
      operatorDistanceMeters: operatorDistanceMeters,
      isEVCharger: isEVCharger,
      hasOperatorLocalityMatch: hasOperatorLocalityMatch,
      restaurantDistanceMeters: restaurantDistanceMeters,
      stablePlaceIdentifier: stablePlaceIdentifier
    )
  }

  private func knownCatalogAliasMatch(
    stablePlaceIdentifier: String
  ) throws -> AppleChargingPlaceMatchPolicy.Match {
    try XCTUnwrap(
      AppleChargingPlaceMatchPolicy.knownCatalogAliasMatch(
        evidence: knownCatalogAliasEvidence(
          stablePlaceIdentifier: stablePlaceIdentifier
        ),
        resultGroupKind: .restaurant
      )
    )
  }

  func testNativeApplePlaceURLUsesOnlyTheStablePlaceIdentifier() throws {
    let url = try XCTUnwrap(
      AppleMapsLauncher.placeURL(placeIdentifier: "I1234567890ABCDEF")
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "maps.apple.com")
    XCTAssertEqual(components.path, "/place")
    XCTAssertEqual(
      components.queryItems,
      [
        URLQueryItem(name: "place-id", value: "I1234567890ABCDEF")
      ])
  }

  func testAppleMapsURLKeepsDestinationAndAddsRestaurantWaypoint() throws {
    let destination = try SavedDestination(
      displayName: "Berlin Hauptbahnhof",
      coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694),
      applePlaceIdentifier: "destination-place"
    )
    let restaurant = try FoodPOI(
      id: "restaurant",
      applePlaceIdentifier: "restaurant-place",
      chain: .mcdonalds,
      name: "McDonald's",
      coordinate: Coordinate(latitude: 52.1, longitude: 10.2),
      distanceFromPark: Meters(120),
      openingStatus: .unknown
    )

    let url = try XCTUnwrap(
      AppleMapsLauncher.multistopDirectionsURL(
        waypoint: restaurant,
        finalDestination: destination
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let values = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "maps.apple.com")
    XCTAssertEqual(components.path, "/directions")
    XCTAssertEqual(values["destination"], "52.5251,13.3694")
    XCTAssertEqual(values["destination-place-id"], "destination-place")
    XCTAssertEqual(values["waypoint"], "52.1,10.2")
    XCTAssertEqual(values["waypoint-place-id"], "restaurant-place")
    XCTAssertEqual(values["mode"], "driving")
  }

  func testPreparationUsesCurrentLocationAndCreatesPrivacyScopedRequest() async throws {
    let origin = try Coordinate(latitude: 48.1372, longitude: 11.5756)
    let destination = try SavedDestination(
      displayName: "Berlin Hauptbahnhof",
      coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694),
      displayAddress: "Europaplatz 1, Berlin"
    )
    let profile = try makeProfile(name: "Private profile name", destination: destination)
    let route = try PlannedRoute(
      polyline: RoutePolyline(coordinates: [origin, destination.coordinate]),
      actualDrivingDistance: Meters(585_000),
      expectedTravelTimeSeconds: 20_400
    )
    let locationProvider = LocationProviderStub(result: .success(origin))
    let routePlanner = RoutePlannerStub(result: .success(route))
    let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(profile: profile),
      locationProvider: locationProvider,
      routePlanner: routePlanner,
      makeRequestID: { requestID }
    )

    await viewModel.prepareRoute()

    XCTAssertEqual(routePlanner.receivedOrigin, origin)
    XCTAssertEqual(routePlanner.receivedDestination, destination.coordinate)
    guard case .ready(let preparedSearch) = viewModel.state else {
      return XCTFail("Expected a prepared ride search")
    }
    XCTAssertEqual(preparedSearch.origin, origin)
    XCTAssertEqual(preparedSearch.route, route)
    XCTAssertEqual(preparedSearch.request.requestID, requestID)
    XCTAssertEqual(preparedSearch.request.route, route.polyline)
    XCTAssertEqual(preparedSearch.request.criteria, profile.criteria)
    XCTAssertNil(preparedSearch.request.snapshotToken)
    XCTAssertNil(preparedSearch.request.cursor)

    await viewModel.prepareRoute()
    XCTAssertEqual(locationProvider.requestCount, 1)
    XCTAssertEqual(routePlanner.requestCount, 1)
  }

  func testPreparationAndCandidateSearchRunAsOneFlowExactlyOnce() async throws {
    let origin = try Coordinate(latitude: 50.1109, longitude: 8.6821)
    let destination = try SavedDestination(
      displayName: "Rostock",
      coordinate: Coordinate(latitude: 54.0924, longitude: 12.0991)
    )
    let route = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination.coordinate]),
      actualDrivingDistance: Meters(666_000),
      expectedTravelTimeSeconds: 22_000
    )
    let coverage = CandidateSearchCoverage(
      status: .complete,
      activeSourceIDs: ["bundesnetzagentur_ladesaeulenregister"],
      unavailableSourceIDs: [],
      projectionUpdatedAt: Date(timeIntervalSince1970: 0)
    )
    let locationProvider = LocationProviderStub(result: .success(origin))
    let routePlanner = RoutePlannerStub(result: .success(route))
    let candidateSearcher = CandidateSearcherStub(
      result: .success(RideCandidateSearchOutcome(results: [], coverage: coverage))
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: locationProvider,
      routePlanner: routePlanner,
      candidateSearcher: candidateSearcher
    )

    await viewModel.prepareRouteAndSearch()

    guard case .ready(let preparedRide) = viewModel.state else {
      return XCTFail("Expected the route to be ready")
    }
    XCTAssertEqual(candidateSearcher.preparedRides, [preparedRide])
    XCTAssertEqual(
      viewModel.candidateSearchState,
      .noResults(RideCandidateSearchOutcome(results: [], coverage: coverage))
    )

    await viewModel.prepareRouteAndSearch()

    XCTAssertEqual(locationProvider.requestCount, 1)
    XCTAssertEqual(routePlanner.requestCount, 1)
    XCTAssertEqual(candidateSearcher.preparedRides.count, 1)
  }

  func testPreparationFailureDoesNotStartCandidateSearch() async throws {
    let destination = try SavedDestination(
      displayName: "Rostock",
      coordinate: Coordinate(latitude: 54.0924, longitude: 12.0991)
    )
    let candidateSearcher = CandidateSearcherStub(
      result: .failure(RideCandidateSearchError.candidateServiceUnavailable)
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: LocationProviderStub(
        result: .failure(CurrentLocationError.authorizationDenied)
      ),
      routePlanner: RoutePlannerStub(result: .failure(RoutePlanningError.noRoute)),
      candidateSearcher: candidateSearcher
    )

    await viewModel.prepareRouteAndSearch()

    XCTAssertEqual(viewModel.state, .failed(.locationPermissionDenied))
    XCTAssertEqual(viewModel.candidateSearchState, .idle)
    XCTAssertTrue(candidateSearcher.preparedRides.isEmpty)
  }

  func testDeniedLocationMapsToActionableFailureWithoutCallingRoutePlanner() async throws {
    let destination = try SavedDestination(
      displayName: "Hamburg",
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
    let locationProvider = LocationProviderStub(
      result: .failure(CurrentLocationError.authorizationDenied)
    )
    let routePlanner = RoutePlannerStub(
      result: .failure(RoutePlanningError.noRoute)
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: locationProvider,
      routePlanner: routePlanner
    )

    await viewModel.prepareRoute()

    XCTAssertEqual(viewModel.state, .failed(.locationPermissionDenied))
    XCTAssertNil(routePlanner.receivedOrigin)
  }

  func testReducedAccuracyMapsToPreciseLocationFailure() async throws {
    let destination = try SavedDestination(
      displayName: "Hamburg",
      coordinate: Coordinate(latitude: 53.5511, longitude: 9.9937)
    )
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: LocationProviderStub(
        result: .failure(CurrentLocationError.reducedAccuracy)
      ),
      routePlanner: RoutePlannerStub(result: .failure(RoutePlanningError.noRoute))
    )

    await viewModel.prepareRoute()

    XCTAssertEqual(viewModel.state, .failed(.preciseLocationRequired))
  }

  func testRouteErrorKeepsDraftAndCanBeRetried() async throws {
    let origin = try Coordinate(latitude: 53.5511, longitude: 9.9937)
    let destination = try SavedDestination(
      displayName: "Bremen",
      coordinate: Coordinate(latitude: 53.0793, longitude: 8.8017)
    )
    let routePlanner = RoutePlannerStub(result: .failure(RoutePlanningError.noRoute))
    let viewModel = RidePreparationViewModel(
      draft: RideSearchDraft(destination: destination),
      locationProvider: LocationProviderStub(result: .success(origin)),
      routePlanner: routePlanner
    )

    await viewModel.prepareRoute()
    XCTAssertEqual(viewModel.state, .failed(.routeUnavailable))
    XCTAssertEqual(viewModel.draft.destination, destination)

    routePlanner.result = .success(
      PlannedRoute(
        polyline: try RoutePolyline(coordinates: [origin, destination.coordinate]),
        actualDrivingDistance: Meters(120_000),
        expectedTravelTimeSeconds: 5_400
      )
    )
    await viewModel.prepareRoute()

    guard case .ready = viewModel.state else {
      return XCTFail("Expected retry to prepare the route")
    }
  }

  func testRetryingRoutePlannerRecoversFromOneTransientFailure() async throws {
    let origin = try Coordinate(latitude: 53.5511, longitude: 9.9937)
    let destination = try Coordinate(latitude: 53.0793, longitude: 8.8017)
    let expected = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination]),
      actualDrivingDistance: Meters(120_000),
      expectedTravelTimeSeconds: 5_400
    )
    let base = SequencedRoutePlannerStub(responses: [
      .failure(RoutePlanningError.noRoute),
      .success(expected),
    ])
    let planner = RetryingRoutePlanner(
      base: base,
      retryDelay: .zero
    )

    let route = try await planner.automobileRoute(from: origin, to: destination)

    XCTAssertEqual(route, expected)
    XCTAssertEqual(base.requestCount, 2)
  }

  func testDirectionsRequestGateWaitsBeforeExceedingTheRollingLimit() async throws {
    let origin = try Coordinate(latitude: 53.5511, longitude: 9.9937)
    let destination = try Coordinate(latitude: 53.0793, longitude: 8.8017)
    let route = PlannedRoute(
      polyline: try RoutePolyline(coordinates: [origin, destination]),
      actualDrivingDistance: Meters(120_000),
      expectedTravelTimeSeconds: 5_400
    )
    let clock = DirectionsRequestGateClock()
    let gate = DirectionsRequestGate(
      maximumRequests: 2,
      windowSeconds: 60,
      now: { clock.now },
      sleep: { seconds in clock.advance(by: seconds) }
    )
    let base = RoutePlannerStub(result: .success(route))
    let planner = RateLimitedRoutePlanner(base: base, gate: gate)

    _ = try await planner.automobileRoute(from: origin, to: destination)
    _ = try await planner.automobileRoute(from: origin, to: destination)
    _ = try await planner.automobileRoute(from: origin, to: destination)

    XCTAssertEqual(base.requestCount, 3)
    XCTAssertEqual(clock.sleepDurations, [60])
  }

  private func makeProfile(name: String, destination: SavedDestination) throws -> UserProfile {
    try UserProfile(
      name: name,
      destination: destination,
      criteria: RideCriteria(
        distanceRange: .kilometers100To150,
        minimumChargingPoints: .eight,
        minimumPower: .oneHundredFifty,
        foodChain: .mcdonalds
      ),
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
  }
}

@MainActor
private final class LocationProviderStub: CurrentLocationProviding {
  let result: Result<Coordinate, any Error>
  private(set) var requestCount = 0

  init(result: Result<Coordinate, any Error>) {
    self.result = result
  }

  func currentLocation() async throws -> Coordinate {
    requestCount += 1
    return try result.get()
  }
}

@MainActor
private final class RoutePlannerStub: RoutePlanning {
  var result: Result<PlannedRoute, any Error>
  private(set) var receivedOrigin: Coordinate?
  private(set) var receivedDestination: Coordinate?
  private(set) var requestCount = 0

  init(result: Result<PlannedRoute, any Error>) {
    self.result = result
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    requestCount += 1
    receivedOrigin = origin
    receivedDestination = destination
    return try result.get()
  }
}

@MainActor
private final class CandidateSearcherStub: RideCandidateSearching {
  let result: Result<RideCandidateSearchOutcome, any Error>
  private(set) var preparedRides: [PreparedRideSearch] = []

  init(result: Result<RideCandidateSearchOutcome, any Error>) {
    self.result = result
  }

  func search(preparedRide: PreparedRideSearch) async throws -> RideCandidateSearchOutcome {
    preparedRides.append(preparedRide)
    return try result.get()
  }
}

@MainActor
private final class SequencedRoutePlannerStub: RoutePlanning {
  private var responses: [Result<PlannedRoute, any Error>]
  private(set) var requestCount = 0

  init(responses: [Result<PlannedRoute, any Error>]) {
    self.responses = responses
  }

  func automobileRoute(from origin: Coordinate, to destination: Coordinate) async throws
    -> PlannedRoute
  {
    _ = origin
    _ = destination
    requestCount += 1
    guard !responses.isEmpty else {
      throw RoutePlanningError.noRoute
    }
    return try responses.removeFirst().get()
  }
}

@MainActor
private final class DirectionsRequestGateClock {
  private(set) var now = Date(timeIntervalSince1970: 0)
  private(set) var sleepDurations: [TimeInterval] = []

  func advance(by seconds: TimeInterval) {
    sleepDurations.append(seconds)
    now = now.addingTimeInterval(seconds)
  }
}
