import CryptoKit
import Foundation

actor AppAttestSearchAccessTokenProvider: SearchAccessTokenProviding {
  private static let refreshLeeway: TimeInterval = 60

  private let service: any AppAttestServicing
  private let keyStore: any AppAttestKeyStoring
  private let client: any AppAttestAuthenticating
  private let unsupportedFallback: (any SearchAccessTokenProviding)?
  private let now: @Sendable () -> Date

  private var cachedToken: AppAttestAccessToken?
  private var refreshTask: Task<AppAttestAccessToken, any Error>?

  init(
    service: any AppAttestServicing,
    keyStore: any AppAttestKeyStoring,
    client: any AppAttestAuthenticating,
    unsupportedFallback: (any SearchAccessTokenProviding)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.service = service
    self.keyStore = keyStore
    self.client = client
    self.unsupportedFallback = unsupportedFallback
    self.now = now
  }

  func accessToken(forceRefresh: Bool) async throws -> String {
    guard await service.isSupported else {
      guard let unsupportedFallback else {
        throw SearchAccessTokenProviderError.unsupported
      }
      return try await unsupportedFallback.accessToken(forceRefresh: forceRefresh)
    }

    if forceRefresh {
      cachedToken = nil
    } else if let cachedToken,
      cachedToken.expiresAt.timeIntervalSince(now()) > Self.refreshLeeway
    {
      return cachedToken.value
    }

    if let refreshTask {
      do {
        let token = try await refreshTask.value
        try Task.checkCancellation()
        return token.value
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw Self.map(error)
      }
    }

    let task = Task { try await self.refreshToken(recoveryBudget: 1) }
    refreshTask = task
    do {
      let token = try await task.value
      cachedToken = token
      refreshTask = nil
      try Task.checkCancellation()
      return token.value
    } catch {
      refreshTask = nil
      if error is CancellationError {
        throw CancellationError()
      }
      throw Self.map(error)
    }
  }

  private func refreshToken(recoveryBudget: Int) async throws -> AppAttestAccessToken {
    let record: AppAttestKeyRecord
    do {
      if let stored = try keyStore.load() {
        record = stored
      } else {
        record = try await generatePendingKey()
      }
    } catch AppAttestKeyStoreError.invalidRecord {
      try keyStore.remove()
      record = try await generatePendingKey()
    }

    do {
      switch record.lifecycle {
      case .pendingAttestation:
        return try await attest(record, recoveryBudget: recoveryBudget)
      case .serverConfirmationUnknown, .attested:
        do {
          return try await assertToken(record, retryBudget: 1)
        } catch AppAttestAuthenticationClientError.keyNotRegistered {
          // The server may have lost its confirmation response or registration
          // state. Re-attest the same Secure Enclave key before considering
          // rotation; generating keys on transport failures exhausts Apple's
          // per-install key allowance without improving recovery.
          return try await attest(record, recoveryBudget: recoveryBudget)
        }
      }
    } catch AppAttestServiceError.invalidKey {
      return try await replaceKeyAndRetry(
        recoveryBudget: recoveryBudget,
        terminalError: .unavailable
      )
    } catch AppAttestServiceError.serverUnavailable {
      throw SearchAccessTokenProviderError.unavailable
    } catch AppAttestServiceError.unsupported {
      throw SearchAccessTokenProviderError.unsupported
    } catch AppAttestServiceError.other {
      throw SearchAccessTokenProviderError.unavailable
    }
  }

  private func generatePendingKey() async throws -> AppAttestKeyRecord {
    let keyID = try await service.generateKey()
    guard AppAttestTransportValidation.isValidKeyID(keyID) else {
      throw SearchAccessTokenProviderError.invalidResponse
    }
    let record = AppAttestKeyRecord(keyID: keyID, lifecycle: .pendingAttestation)
    try keyStore.save(record)
    return record
  }

  private func attest(
    _ record: AppAttestKeyRecord,
    recoveryBudget: Int
  ) async throws -> AppAttestAccessToken {
    let challenge: AppAttestChallenge
    if let pendingChallenge = record.pendingAttestationChallenge {
      guard pendingChallenge.expiresAt > now() else {
        return try await replaceKeyAndRetry(
          recoveryBudget: recoveryBudget,
          terminalError: .unavailable
        )
      }
      challenge = pendingChallenge
    } else {
      challenge = try await client.challenge(
        keyID: record.keyID,
        purpose: .attestation
      )
      try keyStore.save(
        AppAttestKeyRecord(
          keyID: record.keyID,
          lifecycle: .pendingAttestation,
          pendingAttestationChallenge: challenge
        )
      )
    }

    let hash = Data(SHA256.hash(data: challenge.clientData))
    let object: Data
    do {
      object = try await service.attestKey(record.keyID, clientDataHash: hash)
    } catch is CancellationError {
      throw CancellationError()
    } catch AppAttestServiceError.serverUnavailable {
      // Apple requires transient attestation retries to use the same key and
      // clientDataHash. Keep the challenge in the device-only Keychain so a
      // later provider instance can repeat the exact operation.
      throw AppAttestServiceError.serverUnavailable
    } catch let error as AppAttestServiceError {
      return try await replaceKeyAndRetry(
        recoveryBudget: recoveryBudget,
        terminalError: Self.mapAttestationFailure(error)
      )
    } catch {
      return try await replaceKeyAndRetry(
        recoveryBudget: recoveryBudget,
        terminalError: .unavailable
      )
    }
    guard !object.isEmpty,
      object.count <= AppAttestTransportValidation.maximumAttestationBytes
    else {
      return try await replaceKeyAndRetry(
        recoveryBudget: recoveryBudget,
        terminalError: .invalidResponse
      )
    }
    try keyStore.save(
      AppAttestKeyRecord(
        keyID: record.keyID,
        lifecycle: .serverConfirmationUnknown
      )
    )
    let token: AppAttestAccessToken
    do {
      token = try await client.attest(
        keyID: record.keyID,
        challengeID: challenge.id,
        attestationObject: object
      )
    } catch AppAttestAuthenticationClientError.proofRejected {
      return try await replaceKeyAndRetry(
        recoveryBudget: recoveryBudget,
        terminalError: .invalidResponse
      )
    }
    try keyStore.save(AppAttestKeyRecord(keyID: record.keyID, lifecycle: .attested))
    return token
  }

  private func assertToken(
    _ record: AppAttestKeyRecord,
    retryBudget: Int
  ) async throws -> AppAttestAccessToken {
    let challenge = try await client.challenge(
      keyID: record.keyID,
      purpose: .assertion
    )
    let hash = Data(SHA256.hash(data: challenge.clientData))
    let object = try await service.generateAssertion(record.keyID, clientDataHash: hash)
    guard !object.isEmpty,
      object.count <= AppAttestTransportValidation.maximumAssertionBytes
    else {
      throw SearchAccessTokenProviderError.invalidResponse
    }
    do {
      let token = try await client.assert(
        keyID: record.keyID,
        challengeID: challenge.id,
        assertionObject: object
      )
      if record.lifecycle != .attested {
        try keyStore.save(AppAttestKeyRecord(keyID: record.keyID, lifecycle: .attested))
      }
      return token
    } catch AppAttestAuthenticationClientError.counterConflict where retryBudget > 0 {
      return try await assertToken(record, retryBudget: retryBudget - 1)
    }
  }

  private func replaceKeyAndRetry(
    recoveryBudget: Int,
    terminalError: SearchAccessTokenProviderError
  ) async throws -> AppAttestAccessToken {
    try keyStore.remove()
    guard recoveryBudget > 0 else {
      throw terminalError
    }
    let replacement = try await generatePendingKey()
    return try await attest(
      replacement,
      recoveryBudget: recoveryBudget - 1
    )
  }

  private static func mapAttestationFailure(
    _ error: AppAttestServiceError
  ) -> SearchAccessTokenProviderError {
    switch error {
    case .unsupported:
      return .unsupported
    case .invalidKey, .serverUnavailable, .other:
      return .unavailable
    }
  }

  private static func map(_ error: any Error) -> SearchAccessTokenProviderError {
    if let error = error as? SearchAccessTokenProviderError {
      return error
    }
    if let error = error as? AppAttestAuthenticationClientError {
      switch error {
      case .invalidRequest:
        return .invalidConfiguration
      case .invalidResponse, .keyNotRegistered, .proofRejected, .counterConflict:
        return .invalidResponse
      case .unavailable:
        return .unavailable
      }
    }
    if error is AppAttestKeyStoreError {
      return .unavailable
    }
    return .unavailable
  }
}
