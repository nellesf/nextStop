import Foundation

enum AppAttestChallengePurpose: String, Encodable, Sendable {
  case attestation
  case assertion
}

struct AppAttestChallenge: Codable, Equatable, Sendable {
  let id: String
  let clientData: Data
  let expiresAt: Date
}

struct AppAttestAccessToken: Equatable, Sendable {
  let value: String
  let expiresAt: Date
}

enum AppAttestAuthenticationClientError: Error, Equatable {
  case invalidRequest
  case invalidResponse
  case keyNotRegistered
  case proofRejected
  case counterConflict
  case unavailable
}

protocol AppAttestAuthenticating: Sendable {
  func challenge(
    keyID: String,
    purpose: AppAttestChallengePurpose
  ) async throws -> AppAttestChallenge
  func attest(
    keyID: String,
    challengeID: String,
    attestationObject: Data
  ) async throws -> AppAttestAccessToken
  func assert(
    keyID: String,
    challengeID: String,
    assertionObject: Data
  ) async throws -> AppAttestAccessToken
}

struct AppAttestAuthenticationClient: AppAttestAuthenticating, Sendable {
  private static let maximumResponseBytes = 64 * 1_024
  private let baseURL: URL
  private let session: URLSession
  private let now: @Sendable () -> Date

  init(
    baseURL: URL,
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.baseURL = baseURL
    self.session = session
    self.now = now
  }

  func challenge(
    keyID: String,
    purpose: AppAttestChallengePurpose
  ) async throws -> AppAttestChallenge {
    guard AppAttestTransportValidation.isValidKeyID(keyID) else {
      throw AppAttestAuthenticationClientError.invalidRequest
    }
    let body = ChallengeRequestDTO(keyId: keyID, purpose: purpose)
    let data = try await post(path: "v1/auth/app-attest/challenge", body: body)
    let dto: ChallengeResponseDTO
    do {
      dto = try JSONDecoder().decode(ChallengeResponseDTO.self, from: data)
    } catch {
      throw AppAttestAuthenticationClientError.invalidResponse
    }
    guard AppAttestTransportValidation.isCanonicalVersion4UUID(dto.challengeId),
      let clientData = Data(strictBase64URL: dto.clientData),
      clientData.count == 32,
      let expiresAt = Self.parseDate(dto.expiresAt),
      expiresAt > now()
    else {
      throw AppAttestAuthenticationClientError.invalidResponse
    }
    return AppAttestChallenge(id: dto.challengeId, clientData: clientData, expiresAt: expiresAt)
  }

  func attest(
    keyID: String,
    challengeID: String,
    attestationObject: Data
  ) async throws -> AppAttestAccessToken {
    guard AppAttestTransportValidation.isValidKeyID(keyID),
      AppAttestTransportValidation.isCanonicalVersion4UUID(challengeID),
      !attestationObject.isEmpty,
      attestationObject.count <= AppAttestTransportValidation.maximumAttestationBytes
    else {
      throw AppAttestAuthenticationClientError.invalidRequest
    }
    return try await exchange(
      path: "v1/auth/app-attest/attest",
      body: AttestationRequestDTO(
        keyId: keyID,
        challengeId: challengeID,
        attestationObject: attestationObject.base64EncodedString()
      )
    )
  }

  func assert(
    keyID: String,
    challengeID: String,
    assertionObject: Data
  ) async throws -> AppAttestAccessToken {
    guard AppAttestTransportValidation.isValidKeyID(keyID),
      AppAttestTransportValidation.isCanonicalVersion4UUID(challengeID),
      !assertionObject.isEmpty,
      assertionObject.count <= AppAttestTransportValidation.maximumAssertionBytes
    else {
      throw AppAttestAuthenticationClientError.invalidRequest
    }
    return try await exchange(
      path: "v1/auth/app-attest/assert",
      body: AssertionRequestDTO(
        keyId: keyID,
        challengeId: challengeID,
        assertionObject: assertionObject.base64EncodedString()
      )
    )
  }

  private func exchange<Body: Encodable & Sendable>(
    path: String,
    body: Body
  ) async throws -> AppAttestAccessToken {
    let data = try await post(path: path, body: body)
    let dto: TokenResponseDTO
    do {
      dto = try JSONDecoder().decode(TokenResponseDTO.self, from: data)
    } catch {
      throw AppAttestAuthenticationClientError.invalidResponse
    }
    guard dto.tokenType == "Bearer",
      (61...900).contains(dto.expiresInSeconds),
      (32...2_048).contains(dto.accessToken.utf8.count),
      !dto.accessToken.contains(where: \.isWhitespace)
    else {
      throw AppAttestAuthenticationClientError.invalidResponse
    }
    return AppAttestAccessToken(
      value: dto.accessToken,
      expiresAt: now().addingTimeInterval(TimeInterval(dto.expiresInSeconds))
    )
  }

  private func post<Body: Encodable & Sendable>(
    path: String,
    body: Body
  ) async throws -> Data {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw AppAttestAuthenticationClientError.invalidRequest
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AppAttestAuthenticationClientError.unavailable
    }
    guard let httpResponse = response as? HTTPURLResponse,
      data.count <= Self.maximumResponseBytes
    else {
      throw AppAttestAuthenticationClientError.invalidResponse
    }
    switch httpResponse.statusCode {
    case 200:
      return data
    case 401:
      throw AppAttestAuthenticationClientError.proofRejected
    case 404:
      throw AppAttestAuthenticationClientError.keyNotRegistered
    case 409:
      throw AppAttestAuthenticationClientError.counterConflict
    case 429:
      throw AppAttestAuthenticationClientError.unavailable
    case 500...599:
      throw AppAttestAuthenticationClientError.unavailable
    default:
      throw AppAttestAuthenticationClientError.invalidResponse
    }
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

enum AppAttestTransportValidation {
  static let maximumAttestationBytes = 131_072
  static let maximumAssertionBytes = 16_384

  static func isValidKeyID(_ value: String) -> Bool {
    guard (40...64).contains(value.utf8.count),
      let decoded = Data(base64Encoded: value),
      decoded.count == 32,
      decoded.base64EncodedString() == value
    else {
      return false
    }
    return true
  }

  static func isCanonicalVersion4UUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value),
      uuid.uuidString.lowercased() == value
    else {
      return false
    }
    let bytes = Array(value.utf8)
    return bytes[14] == 52 && [56, 57, 97, 98].contains(bytes[19])
  }
}

private struct ChallengeRequestDTO: Encodable, Sendable {
  let keyId: String
  let purpose: AppAttestChallengePurpose
}

private struct ChallengeResponseDTO: Decodable {
  let challengeId: String
  let clientData: String
  let expiresAt: String
}

private struct AttestationRequestDTO: Encodable, Sendable {
  let keyId: String
  let challengeId: String
  let attestationObject: String
}

private struct AssertionRequestDTO: Encodable, Sendable {
  let keyId: String
  let challengeId: String
  let assertionObject: String
}

private struct TokenResponseDTO: Decodable {
  let accessToken: String
  let tokenType: String
  let expiresInSeconds: Int
}

extension Data {
  fileprivate init?(strictBase64URL value: String) {
    guard !value.isEmpty,
      value.utf8.allSatisfy({ byte in
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || byte == 45 || byte == 95
      })
    else {
      return nil
    }
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    guard let decoded = Data(base64Encoded: base64),
      decoded.base64URLEncodedString == value
    else {
      return nil
    }
    self = decoded
  }

  fileprivate var base64URLEncodedString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
