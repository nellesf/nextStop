import CryptoKit
import Foundation
import Security
import XCTest

@testable import NextStopApp

@MainActor
final class AppAttestAuthenticationTests: XCTestCase {
  func testFirstUseGeneratesAttestsAndPersistsKeyWithoutPersistingToken() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      generatedKeyIDs: [TestAppAttestKeyID.generated],
      attestationResults: [.success(Data("attestation".utf8))]
    )
    let store = InMemoryAppAttestKeyStore()
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["attested-" + String(repeating: "a", count: 32)]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    let token = try await provider.accessToken(forceRefresh: false)

    XCTAssertTrue(token.hasPrefix("attested-"))
    XCTAssertEqual(service.generatedKeyCount, 1)
    XCTAssertEqual(service.attestedKeyIDs, [TestAppAttestKeyID.generated])
    XCTAssertEqual(service.assertedKeyIDs, [])
    XCTAssertEqual(
      try store.load(),
      AppAttestKeyRecord(keyID: TestAppAttestKeyID.generated, lifecycle: .attested)
    )
    XCTAssertFalse(store.persistedData.localizedCaseInsensitiveContains("attested-"))
    let challengeData = client.challengeData
    let expectedHash = Data(SHA256.hash(data: challengeData))
    XCTAssertEqual(service.attestationHashes, [expectedHash])
  }

  func testExistingAttestedKeyUsesAssertionAndCachesToken() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      assertionResults: [.success(Data("assertion".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(keyID: TestAppAttestKeyID.existing, lifecycle: .attested)
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["asserted-" + String(repeating: "b", count: 32)]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    let first = try await provider.accessToken(forceRefresh: false)
    let second = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(first, second)
    XCTAssertEqual(service.generatedKeyCount, 0)
    XCTAssertEqual(service.assertedKeyIDs, [TestAppAttestKeyID.existing])
    let challengePurposes = await client.challengePurposes
    XCTAssertEqual(challengePurposes, [.assertion])
  }

  func testRefreshesAtSixtySecondLeeway() async throws {
    let clock = TestDateBox(Date(timeIntervalSince1970: 1_800_000_000))
    let service = AppAttestServiceStub(
      assertionResults: [
        .success(Data("assertion-1".utf8)),
        .success(Data("assertion-2".utf8)),
      ]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(keyID: TestAppAttestKeyID.existing, lifecycle: .attested)
    )
    let client = AppAttestAuthenticationStub(
      nowProvider: { clock.value },
      tokens: [
        "first-" + String(repeating: "c", count: 32),
        "second-" + String(repeating: "d", count: 32),
      ],
      expiresIn: 120
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { clock.value }
    )

    let first = try await provider.accessToken(forceRefresh: false)
    clock.value = clock.value.addingTimeInterval(61)
    let second = try await provider.accessToken(forceRefresh: false)

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(service.assertedKeyIDs.count, 2)
  }

  func testConcurrentRequestsCoalesceOneAssertionExchange() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      assertionResults: [.success(Data("assertion".utf8))],
      assertionDelayNanoseconds: 50_000_000
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(keyID: TestAppAttestKeyID.existing, lifecycle: .attested)
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["coalesced-" + String(repeating: "e", count: 32)]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    async let first = provider.accessToken(forceRefresh: false)
    async let second = provider.accessToken(forceRefresh: false)
    let values = try await [first, second]

    XCTAssertEqual(Set(values).count, 1)
    XCTAssertEqual(service.assertedKeyIDs.count, 1)
    let assertionExchangeCount = await client.assertionExchangeCount
    XCTAssertEqual(assertionExchangeCount, 1)
  }

  func testConfirmationUnknownReattestsSameKeyWhenServerRegistrationIsMissing() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      attestationResults: [.success(Data("reattestation".utf8))],
      assertionResults: [.success(Data("assertion".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(
        keyID: TestAppAttestKeyID.existing,
        lifecycle: .serverConfirmationUnknown
      )
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["recovered-" + String(repeating: "r", count: 32)],
      assertionErrors: [.keyNotRegistered]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.generatedKeyCount, 0)
    XCTAssertEqual(service.assertedKeyIDs, [TestAppAttestKeyID.existing])
    XCTAssertEqual(service.attestedKeyIDs, [TestAppAttestKeyID.existing])
    XCTAssertEqual(store.removeCount, 0)
    XCTAssertEqual(
      try store.load(),
      AppAttestKeyRecord(keyID: TestAppAttestKeyID.existing, lifecycle: .attested)
    )
    let purposes = await client.challengePurposes
    XCTAssertEqual(purposes, [.assertion, .attestation])
  }

  func testAttestedKeyReattestsSameKeyWhenServerRegistrationIsMissing() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      attestationResults: [.success(Data("reattestation".utf8))],
      assertionResults: [.success(Data("assertion".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(keyID: TestAppAttestKeyID.existing, lifecycle: .attested)
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["recovered-" + String(repeating: "s", count: 32)],
      assertionErrors: [.keyNotRegistered]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.generatedKeyCount, 0)
    XCTAssertEqual(service.attestedKeyIDs, [TestAppAttestKeyID.existing])
    XCTAssertEqual(store.removeCount, 0)
  }

  func testLostReattestationResponseRetainsSameKeyForNextRecoveryAttempt() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let record = AppAttestKeyRecord(
      keyID: TestAppAttestKeyID.existing,
      lifecycle: .serverConfirmationUnknown
    )
    let service = AppAttestServiceStub(
      attestationResults: [.success(Data("reattestation".utf8))],
      assertionResults: [.success(Data("assertion".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(record: record)
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: [],
      attestationErrors: [.unavailable],
      assertionErrors: [.keyNotRegistered]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    do {
      _ = try await provider.accessToken(forceRefresh: false)
      XCTFail("Expected unavailable")
    } catch {
      XCTAssertEqual(error as? SearchAccessTokenProviderError, .unavailable)
    }
    XCTAssertEqual(service.generatedKeyCount, 0)
    XCTAssertEqual(service.attestedKeyIDs, [TestAppAttestKeyID.existing])
    XCTAssertEqual(store.removeCount, 0)
    XCTAssertEqual(try? store.load(), record)
  }

  func testRejectedSameKeyReattestationRotatesOnlyOnce() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      generatedKeyIDs: [TestAppAttestKeyID.replacement],
      attestationResults: [
        .success(Data("rejected-reattestation".utf8)),
        .success(Data("replacement-attestation".utf8)),
      ],
      assertionResults: [.success(Data("assertion".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(
        keyID: TestAppAttestKeyID.existing,
        lifecycle: .attested
      )
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["replacement-" + String(repeating: "t", count: 32)],
      attestationErrors: [.proofRejected],
      assertionErrors: [.keyNotRegistered]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.generatedKeyCount, 1)
    XCTAssertEqual(
      service.attestedKeyIDs,
      [TestAppAttestKeyID.existing, TestAppAttestKeyID.replacement]
    )
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertEqual(try store.load()?.keyID, TestAppAttestKeyID.replacement)
  }

  func testCounterConflictRetriesOneFreshAssertionWithoutReattestation() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      assertionResults: [
        .success(Data("assertion-1".utf8)),
        .success(Data("assertion-2".utf8)),
      ]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(
        keyID: TestAppAttestKeyID.existing,
        lifecycle: .attested
      )
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["counter-recovered-" + String(repeating: "u", count: 32)],
      assertionErrors: [.counterConflict]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(
      service.assertedKeyIDs,
      [TestAppAttestKeyID.existing, TestAppAttestKeyID.existing]
    )
    XCTAssertEqual(service.attestedKeyIDs, [])
    XCTAssertEqual(service.generatedKeyCount, 0)
    XCTAssertEqual(store.removeCount, 0)
    let purposes = await client.challengePurposes
    XCTAssertEqual(purposes, [.assertion, .assertion])
  }

  func testInvalidKeyRotatesAtMostOnce() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      generatedKeyIDs: [TestAppAttestKeyID.replacement],
      attestationResults: [.success(Data("attestation".utf8))],
      assertionResults: [.failure(.invalidKey)]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(keyID: TestAppAttestKeyID.stale, lifecycle: .attested)
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["replacement-" + String(repeating: "f", count: 32)]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.generatedKeyCount, 1)
    XCTAssertEqual(service.attestedKeyIDs, [TestAppAttestKeyID.replacement])
    XCTAssertEqual(try store.load()?.keyID, TestAppAttestKeyID.replacement)
    XCTAssertEqual(store.removeCount, 1)
  }

  func testRejectedAssertionDoesNotRotateOrReattestKey() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let record = AppAttestKeyRecord(
      keyID: TestAppAttestKeyID.existing,
      lifecycle: .attested
    )
    let service = AppAttestServiceStub(
      assertionResults: [.success(Data("assertion".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(record: record)
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: [],
      assertionErrors: [.proofRejected]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    do {
      _ = try await provider.accessToken(forceRefresh: false)
      XCTFail("Expected rejected proof")
    } catch {
      XCTAssertEqual(error as? SearchAccessTokenProviderError, .invalidResponse)
    }
    XCTAssertEqual(service.generatedKeyCount, 0)
    XCTAssertEqual(service.attestedKeyIDs, [])
    XCTAssertEqual(store.removeCount, 0)
    XCTAssertEqual(try? store.load(), record)
  }

  func testServerUnavailableReusesPersistedChallengeAndClientDataHash() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = AppAttestServiceStub(
      attestationResults: [
        .failure(.serverUnavailable),
        .success(Data("attestation".utf8)),
      ]
    )
    let record = AppAttestKeyRecord(
      keyID: TestAppAttestKeyID.pending,
      lifecycle: .pendingAttestation
    )
    let store = InMemoryAppAttestKeyStore(record: record)
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["recovered-" + String(repeating: "v", count: 32)]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    do {
      _ = try await provider.accessToken(forceRefresh: false)
      XCTFail("Expected unavailable")
    } catch {
      XCTAssertEqual(error as? SearchAccessTokenProviderError, .unavailable)
    }
    let pendingRecord = try XCTUnwrap(store.load())
    XCTAssertEqual(pendingRecord.keyID, record.keyID)
    XCTAssertEqual(pendingRecord.lifecycle, .pendingAttestation)
    XCTAssertNotNil(pendingRecord.pendingAttestationChallenge)
    XCTAssertEqual(store.removeCount, 0)

    let recoveredProvider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )
    _ = try await recoveredProvider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.attestationHashes.count, 2)
    XCTAssertEqual(service.attestationHashes.first, service.attestationHashes.last)
    let purposes = await client.challengePurposes
    XCTAssertEqual(purposes, [.attestation])
    XCTAssertEqual(
      try store.load(),
      AppAttestKeyRecord(keyID: TestAppAttestKeyID.pending, lifecycle: .attested)
    )
  }

  func testNonServerUnavailableAttestationFailureRotatesPendingKeyOnce() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let record = AppAttestKeyRecord(
      keyID: TestAppAttestKeyID.pending,
      lifecycle: .pendingAttestation
    )
    let service = AppAttestServiceStub(
      generatedKeyIDs: [TestAppAttestKeyID.replacement],
      attestationResults: [
        .failure(.other),
        .success(Data("replacement-attestation".utf8)),
      ]
    )
    let store = InMemoryAppAttestKeyStore(record: record)
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: AppAttestAuthenticationStub(
        now: now,
        tokens: ["replacement-" + String(repeating: "w", count: 32)]
      ),
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.generatedKeyCount, 1)
    XCTAssertEqual(
      service.attestedKeyIDs,
      [TestAppAttestKeyID.pending, TestAppAttestKeyID.replacement]
    )
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertEqual(
      try store.load(),
      AppAttestKeyRecord(keyID: TestAppAttestKeyID.replacement, lifecycle: .attested)
    )
  }

  func testExpiredPersistedAttestationChallengeRotatesInsteadOfChangingHashForKey() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expiredChallenge = AppAttestChallenge(
      id: "00000000-0000-4000-8000-000000000001",
      clientData: Data("0123456789abcdef0123456789abcdef".utf8),
      expiresAt: now.addingTimeInterval(-1)
    )
    let service = AppAttestServiceStub(
      generatedKeyIDs: [TestAppAttestKeyID.replacement],
      attestationResults: [.success(Data("replacement-attestation".utf8))]
    )
    let store = InMemoryAppAttestKeyStore(
      record: AppAttestKeyRecord(
        keyID: TestAppAttestKeyID.pending,
        lifecycle: .pendingAttestation,
        pendingAttestationChallenge: expiredChallenge
      )
    )
    let client = AppAttestAuthenticationStub(
      now: now,
      tokens: ["replacement-" + String(repeating: "x", count: 32)]
    )
    let provider = AppAttestSearchAccessTokenProvider(
      service: service,
      keyStore: store,
      client: client,
      now: { now }
    )

    _ = try await provider.accessToken(forceRefresh: false)

    XCTAssertEqual(service.generatedKeyCount, 1)
    XCTAssertEqual(service.attestedKeyIDs, [TestAppAttestKeyID.replacement])
    XCTAssertEqual(store.removeCount, 1)
    let purposes = await client.challengePurposes
    XCTAssertEqual(purposes, [.attestation])
  }

  #if DEBUG && targetEnvironment(simulator)
    func testUnsupportedAppAttestUsesOnlyLoopbackFallback() async throws {
      let service = AppAttestServiceStub(isSupported: false)
      let fallback = SearchAccessTokenStub(
        result: .success("broker-" + String(repeating: "1", count: 32))
      )
      let provider = AppAttestSearchAccessTokenProvider(
        service: service,
        keyStore: InMemoryAppAttestKeyStore(),
        client: AppAttestAuthenticationStub(now: Date(), tokens: []),
        unsupportedFallback: fallback
      )

      let token = try await provider.accessToken(forceRefresh: false)

      XCTAssertTrue(token.hasPrefix("broker-"))
      let calls = await fallback.calls
      XCTAssertEqual(calls, [false])
    }

    func testSimulatorBrokerAcceptsOnlyLiteralLoopbackTokenURL() {
      XCTAssertNotNil(
        SimulatorSearchAccessTokenProvider.validatedLoopbackURL(
          URL(string: "http://127.0.0.1:9482/token")
        )
      )
      XCTAssertNotNil(
        SimulatorSearchAccessTokenProvider.validatedLoopbackURL(
          URL(string: "http://[::1]:9482/token")
        )
      )
      XCTAssertNil(
        SimulatorSearchAccessTokenProvider.validatedLoopbackURL(
          URL(string: "http://localhost:9482/token")
        )
      )
      XCTAssertNil(
        SimulatorSearchAccessTokenProvider.validatedLoopbackURL(
          URL(string: "https://api.nextstop.tech/token")
        )
      )
      XCTAssertNil(
        SimulatorSearchAccessTokenProvider.validatedLoopbackURL(
          URL(string: "http://127.0.0.1:9482/other")
        )
      )
    }
  #endif

  func testKeychainPolicyIsDeviceOnlyNonSynchronizingAndEnvironmentScoped() {
    let development = KeychainAppAttestKeyStore(
      bundleIdentifier: "de.nextstop.app",
      environment: .development,
      baseURL: URL(string: "https://api.nextstop.tech")!
    )
    let production = KeychainAppAttestKeyStore(
      bundleIdentifier: "de.nextstop.app",
      environment: .production,
      baseURL: URL(string: "https://api.nextstop.tech")!
    )
    let alternatePort = KeychainAppAttestKeyStore(
      bundleIdentifier: "de.nextstop.app",
      environment: .development,
      baseURL: URL(string: "https://api.nextstop.tech:8443/v1")!
    )
    let explicitDefaultPort = KeychainAppAttestKeyStore(
      bundleIdentifier: "de.nextstop.app",
      environment: .development,
      baseURL: URL(string: "https://API.NextStop.Tech:443/other-path")!
    )

    XCTAssertEqual(
      development.policyAttributes[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    XCTAssertEqual(
      development.policyAttributes[kSecAttrSynchronizable as String] as? Bool,
      false
    )
    XCTAssertNotEqual(development.service, production.service)
    XCTAssertNotEqual(development.service, alternatePort.service)
    XCTAssertEqual(development.service, explicitDefaultPort.service)
    XCTAssertTrue(development.service.hasSuffix("https://api.nextstop.tech:443"))
  }

  func testKeychainDecoderRejectsPersistedNoncanonicalKeyIdentifier() throws {
    let invalidRecord = AppAttestKeyRecord(
      keyID: "not-a-canonical-app-attest-key",
      lifecycle: .attested
    )
    let data = try JSONEncoder().encode(invalidRecord)

    XCTAssertThrowsError(try KeychainAppAttestKeyStore.decodeRecord(data)) { error in
      XCTAssertEqual(error as? AppAttestKeyStoreError, .invalidRecord)
    }
  }

  func testKeychainDecoderRoundTripsPendingAttestationChallenge() throws {
    let record = AppAttestKeyRecord(
      keyID: TestAppAttestKeyID.pending,
      lifecycle: .pendingAttestation,
      pendingAttestationChallenge: AppAttestChallenge(
        id: "00000000-0000-4000-8000-000000000001",
        clientData: Data("0123456789abcdef0123456789abcdef".utf8),
        expiresAt: Date(timeIntervalSince1970: 1_800_000_300)
      )
    )

    let decoded = try KeychainAppAttestKeyStore.decodeRecord(JSONEncoder().encode(record))

    XCTAssertEqual(decoded, record)
  }

  func testKeychainDecoderRejectsPendingChallengeOnAttestedRecord() throws {
    let record = AppAttestKeyRecord(
      keyID: TestAppAttestKeyID.existing,
      lifecycle: .attested,
      pendingAttestationChallenge: AppAttestChallenge(
        id: "00000000-0000-4000-8000-000000000001",
        clientData: Data("0123456789abcdef0123456789abcdef".utf8),
        expiresAt: Date(timeIntervalSince1970: 1_800_000_300)
      )
    )

    XCTAssertThrowsError(
      try KeychainAppAttestKeyStore.decodeRecord(JSONEncoder().encode(record))
    ) { error in
      XCTAssertEqual(error as? AppAttestKeyStoreError, .invalidRecord)
    }
  }
}

private enum TestAppAttestKeyID {
  static let existing = Data(repeating: 0x11, count: 32).base64EncodedString()
  static let generated = Data(repeating: 0x22, count: 32).base64EncodedString()
  static let pending = Data(repeating: 0x33, count: 32).base64EncodedString()
  static let replacement = Data(repeating: 0x44, count: 32).base64EncodedString()
  static let stale = Data(repeating: 0x55, count: 32).base64EncodedString()
}

@MainActor
private final class AppAttestServiceStub: AppAttestServicing {
  let isSupported: Bool
  private var generatedKeyIDs: [String]
  private var attestationResults: [Result<Data, AppAttestServiceError>]
  private var assertionResults: [Result<Data, AppAttestServiceError>]
  private let assertionDelayNanoseconds: UInt64

  private(set) var generatedKeyCount = 0
  private(set) var attestedKeyIDs: [String] = []
  private(set) var assertedKeyIDs: [String] = []
  private(set) var attestationHashes: [Data] = []

  init(
    isSupported: Bool = true,
    generatedKeyIDs: [String] = [],
    attestationResults: [Result<Data, AppAttestServiceError>] = [],
    assertionResults: [Result<Data, AppAttestServiceError>] = [],
    assertionDelayNanoseconds: UInt64 = 0
  ) {
    self.isSupported = isSupported
    self.generatedKeyIDs = generatedKeyIDs
    self.attestationResults = attestationResults
    self.assertionResults = assertionResults
    self.assertionDelayNanoseconds = assertionDelayNanoseconds
  }

  func generateKey() async throws -> String {
    generatedKeyCount += 1
    guard !generatedKeyIDs.isEmpty else {
      throw AppAttestServiceError.other
    }
    return generatedKeyIDs.removeFirst()
  }

  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    attestedKeyIDs.append(keyID)
    attestationHashes.append(clientDataHash)
    guard !attestationResults.isEmpty else {
      throw AppAttestServiceError.other
    }
    return try attestationResults.removeFirst().get()
  }

  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    assertedKeyIDs.append(keyID)
    if assertionDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: assertionDelayNanoseconds)
    }
    guard !assertionResults.isEmpty else {
      throw AppAttestServiceError.other
    }
    return try assertionResults.removeFirst().get()
  }
}

private final class InMemoryAppAttestKeyStore: AppAttestKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var record: AppAttestKeyRecord?
  private(set) var removeCount = 0

  init(record: AppAttestKeyRecord? = nil) {
    self.record = record
  }

  func load() throws -> AppAttestKeyRecord? {
    lock.lock()
    defer { lock.unlock() }
    return record
  }

  func save(_ record: AppAttestKeyRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    self.record = record
  }

  func remove() throws {
    lock.lock()
    defer { lock.unlock() }
    record = nil
    removeCount += 1
  }

  var persistedData: String {
    lock.lock()
    defer { lock.unlock() }
    guard let record,
      let data = try? JSONEncoder().encode(record)
    else {
      return ""
    }
    return String(data: data, encoding: .utf8) ?? ""
  }
}

private actor AppAttestAuthenticationStub: AppAttestAuthenticating {
  let challengeData = Data("0123456789abcdef0123456789abcdef".utf8)
  private let nowProvider: @Sendable () -> Date
  private var tokens: [String]
  private let expiresIn: TimeInterval
  private var attestationErrors: [AppAttestAuthenticationClientError]
  private var assertionErrors: [AppAttestAuthenticationClientError]
  private(set) var challengePurposes: [AppAttestChallengePurpose] = []
  private(set) var assertionExchangeCount = 0

  init(
    now: Date,
    tokens: [String],
    expiresIn: TimeInterval = 900,
    attestationErrors: [AppAttestAuthenticationClientError] = [],
    assertionErrors: [AppAttestAuthenticationClientError] = []
  ) {
    nowProvider = { now }
    self.tokens = tokens
    self.expiresIn = expiresIn
    self.attestationErrors = attestationErrors
    self.assertionErrors = assertionErrors
  }

  init(
    nowProvider: @escaping @Sendable () -> Date,
    tokens: [String],
    expiresIn: TimeInterval = 900,
    attestationErrors: [AppAttestAuthenticationClientError] = [],
    assertionErrors: [AppAttestAuthenticationClientError] = []
  ) {
    self.nowProvider = nowProvider
    self.tokens = tokens
    self.expiresIn = expiresIn
    self.attestationErrors = attestationErrors
    self.assertionErrors = assertionErrors
  }

  func challenge(
    keyID: String,
    purpose: AppAttestChallengePurpose
  ) async throws -> AppAttestChallenge {
    challengePurposes.append(purpose)
    return AppAttestChallenge(
      id: "00000000-0000-4000-8000-000000000001",
      clientData: challengeData,
      expiresAt: nowProvider().addingTimeInterval(300)
    )
  }

  func attest(
    keyID: String,
    challengeID: String,
    attestationObject: Data
  ) async throws -> AppAttestAccessToken {
    if !attestationErrors.isEmpty {
      throw attestationErrors.removeFirst()
    }
    return try nextToken()
  }

  func assert(
    keyID: String,
    challengeID: String,
    assertionObject: Data
  ) async throws -> AppAttestAccessToken {
    assertionExchangeCount += 1
    if !assertionErrors.isEmpty {
      throw assertionErrors.removeFirst()
    }
    return try nextToken()
  }

  private func nextToken() throws -> AppAttestAccessToken {
    guard !tokens.isEmpty else {
      throw AppAttestAuthenticationClientError.unavailable
    }
    return AppAttestAccessToken(
      value: tokens.removeFirst(),
      expiresAt: nowProvider().addingTimeInterval(expiresIn)
    )
  }
}

private actor SearchAccessTokenStub: SearchAccessTokenProviding {
  let result: Result<String, SearchAccessTokenProviderError>
  private(set) var calls: [Bool] = []

  init(result: Result<String, SearchAccessTokenProviderError>) {
    self.result = result
  }

  func accessToken(forceRefresh: Bool) async throws -> String {
    calls.append(forceRefresh)
    return try result.get()
  }
}

private final class TestDateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Date

  init(_ value: Date) {
    storedValue = value
  }

  var value: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedValue = newValue
    }
  }
}
