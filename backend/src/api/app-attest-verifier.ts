import {
  createHash,
  createPublicKey,
  verify as verifySignature,
  X509Certificate,
} from "node:crypto";

import cbor from "cbor";
import {
  verifyAssertion as nodeVerifyAssertionUntyped,
  verifyAttestation as nodeVerifyAttestationUntyped,
} from "node-app-attest";

import {
  StaleAppAttestAssertionCounterError,
  type AppAttestCryptographicallyVerifying,
  type AttestedKey,
  type VerifiedAttestation,
} from "../application/app-attest-authentication.js";

const appleAppAttestationRoot = new X509Certificate(
  "-----BEGIN CERTIFICATE-----\nMIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD\n-----END CERTIFICATE-----",
);

const legacyDevelopmentAAGUID = Buffer.from("appattestdevelop", "ascii");
const sandboxAAGUID = Buffer.from("appattestsandbox", "ascii");
const productionAAGUID = Buffer.concat([
  Buffer.from("appattest", "ascii"),
  Buffer.alloc(7),
]);
const attestedCredentialDataFlag = 0x40;
const extensionDataFlag = 0x80;
const developmentValidationCategories = new Set([3]);
const productionValidationCategories = new Set([2, 4]);

export interface PinnedNodeAppAttestResult {
  readonly publicKey: string | Buffer;
  readonly receipt: Buffer;
  readonly environment: string;
}

export type PinnedNodeAppAttestVerifier = (input: {
  readonly attestation: Buffer;
  readonly challenge: Buffer;
  readonly keyId: string;
  readonly bundleIdentifier: string;
  readonly teamIdentifier: string;
  readonly allowDevelopmentEnvironment: boolean;
}) => PinnedNodeAppAttestResult;

const nodeVerifyAttestation = nodeVerifyAttestationUntyped as PinnedNodeAppAttestVerifier;

const nodeVerifyAssertion = nodeVerifyAssertionUntyped as (input: {
  readonly assertion: Buffer;
  readonly payload: Buffer;
  readonly publicKey: string;
  readonly bundleIdentifier: string;
  readonly teamIdentifier: string;
  readonly signCount: number;
}) => { readonly signCount: number };

export interface HardenedAppAttestVerifierOptions {
  readonly allowDevelopmentEnvironment?: boolean;
  readonly supportedBundleVersions?: readonly string[];
  readonly now?: () => Date;
  /** Test seam for the exact, pinned node-app-attest compatibility boundary. */
  readonly pinnedNodeAttestationVerifier?: PinnedNodeAppAttestVerifier;
}

export class HardenedAppAttestVerifier implements AppAttestCryptographicallyVerifying {
  private readonly teamIdentifier: string;
  private readonly bundleIdentifier: string;
  private readonly appIdHash: Buffer;
  private readonly allowDevelopmentEnvironment: boolean;
  private readonly supportedBundleVersions: ReadonlySet<string>;
  private readonly now: () => Date;
  private readonly pinnedNodeAttestationVerifier: PinnedNodeAppAttestVerifier;

  constructor(appId: string, options: HardenedAppAttestVerifierOptions = {}) {
    const separator = appId.indexOf(".");
    const teamIdentifier = appId.slice(0, separator);
    const bundleIdentifier = appId.slice(separator + 1);
    if (
      separator < 1 ||
      !/^[A-Z0-9]{10}$/u.test(teamIdentifier) ||
      !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(bundleIdentifier) ||
      appId.length > 255
    ) {
      throw new Error("APP_ATTEST_APP_ID must contain the App ID prefix and bundle identifier.");
    }
    this.teamIdentifier = teamIdentifier;
    this.bundleIdentifier = bundleIdentifier;
    this.appIdHash = createHash("sha256").update(appId, "utf8").digest();
    this.allowDevelopmentEnvironment = options.allowDevelopmentEnvironment ?? false;
    this.supportedBundleVersions = validatedBundleVersionAllowlist(
      options.supportedBundleVersions ?? [],
    );
    this.now = options.now ?? (() => new Date());
    this.pinnedNodeAttestationVerifier =
      options.pinnedNodeAttestationVerifier ?? nodeVerifyAttestation;
  }

  verifyAttestation(input: {
    readonly attestationObject: Buffer;
    readonly clientData: Buffer;
    readonly keyId: string;
  }): VerifiedAttestation {
    if (input.attestationObject.length < 256 || input.attestationObject.length > 131_072) {
      throw new Error("Invalid attestation size.");
    }
    const decodedValues = decodeCBORSequence(input.attestationObject);
    if (decodedValues.length !== 1) {
      throw new Error("Invalid attestation CBOR sequence.");
    }
    const decoded = requireRecord(decodedValues[0], ["attStmt", "authData", "fmt"]);
    if (decoded.fmt !== "apple-appattest") {
      throw new Error("Invalid attestation format.");
    }
    const statement = requireRecord(decoded.attStmt, ["receipt", "x5c"]);
    if (!Array.isArray(statement.x5c) || statement.x5c.length !== 2) {
      throw new Error("Invalid attestation certificate chain.");
    }
    const leafData = requireSizedBuffer(statement.x5c[0], 128, 8_192);
    const intermediateData = requireSizedBuffer(statement.x5c[1], 128, 8_192);
    const receipt = requireSizedBuffer(statement.receipt, 1, 131_072);
    const authData = requireSizedBuffer(decoded.authData, 164, 4_096);
    const attestationEnvironment = this.validateAttestationAuthenticatorData(
      authData,
      input.keyId,
    );
    const { environment } = attestationEnvironment;
    const extensions = parseAttestationRemainder(
      authData,
      validationCategoriesFor(environment),
      this.supportedBundleVersions,
    );
    const leaf = this.validateCertificateChain(leafData, intermediateData);

    let result: PinnedNodeAppAttestResult | undefined;
    try {
      result = this.pinnedNodeAttestationVerifier({
        attestation: input.attestationObject,
        challenge: input.clientData,
        keyId: input.keyId,
        bundleIdentifier: this.bundleIdentifier,
        teamIdentifier: this.teamIdentifier,
        allowDevelopmentEnvironment: this.allowDevelopmentEnvironment,
      });
    } catch (error) {
      // node-app-attest 1.0.1 predates Apple's current sandbox AAGUID. Its
      // `aaguid is not valid` branch runs only after it has verified the Apple
      // chain, nonce, leaf-public-key hash, App ID, and zero counter. The
      // hardened wrapper has already validated the credential ID and chain as
      // well. Accept only that exact final incompatibility for the exact current
      // sandbox AAGUID; every other library rejection still fails closed.
      if (
        !attestationEnvironment.usesCurrentSandboxAAGUID ||
        !isPinnedSandboxAAGUIDCompatibilityError(error)
      ) {
        throw error;
      }
    }
    const publicKeyPEM =
      result === undefined
        ? leaf.publicKey.export({ type: "spki", format: "pem" }).toString()
        : Buffer.isBuffer(result.publicKey)
          ? result.publicKey.toString("utf8")
          : result.publicKey;
    if (
      result !== undefined &&
      (result.environment !== environment ||
        !Buffer.isBuffer(result.receipt) ||
        !result.receipt.equals(receipt))
    ) {
      throw new Error("App Attest verifier result mismatch.");
    }
    validatePublicKey(publicKeyPEM);
    return {
      publicKeyPEM,
      receipt: Buffer.from(receipt),
      environment,
      ...(extensions.validationCategory === undefined
        ? {}
        : { validationCategory: extensions.validationCategory }),
      ...(extensions.bundleVersion === undefined
        ? {}
        : { bundleVersion: extensions.bundleVersion }),
    };
  }

  verifyAssertion(input: {
    readonly assertionObject: Buffer;
    readonly clientData: Buffer;
    readonly key: AttestedKey;
  }): number {
    if (input.key.environment === "development" && !this.allowDevelopmentEnvironment) {
      throw new Error("Attestation environment is not allowed.");
    }
    if (input.assertionObject.length < 64 || input.assertionObject.length > 16_384) {
      throw new Error("Invalid assertion size.");
    }
    const decodedValues = decodeCBORSequence(input.assertionObject);
    if (decodedValues.length !== 1) {
      throw new Error("Invalid assertion CBOR sequence.");
    }
    const decoded = requireRecord(decodedValues[0], ["authenticatorData", "signature"]);
    const authenticatorData = requireSizedBuffer(decoded.authenticatorData, 37, 4_096);
    const signature = requireSizedBuffer(decoded.signature, 64, 80);
    if (!authenticatorData.subarray(0, 32).equals(this.appIdHash)) {
      throw new Error("Assertion App ID mismatch.");
    }
    const flags = authenticatorData[32];
    if (flags === undefined || (flags & ~extensionDataFlag) !== 0) {
      throw new Error("Invalid assertion authenticator flags.");
    }
    parseAssertionRemainder(
      authenticatorData,
      validationCategoriesFor(input.key.environment),
      this.supportedBundleVersions,
    );
    const nextSignCount = authenticatorData.readUInt32BE(33);
    validatePublicKey(input.key.publicKeyPEM);
    const clientDataHash = createHash("sha256").update(input.clientData).digest();
    const nonce = createHash("sha256")
      .update(Buffer.concat([authenticatorData, clientDataHash]))
      .digest();
    if (!verifySignature("sha256", nonce, input.key.publicKeyPEM, signature)) {
      throw new Error("Invalid App Attest assertion signature.");
    }
    if (nextSignCount <= input.key.signCount) {
      throw new StaleAppAttestAssertionCounterError();
    }

    // node-app-attest currently reads this field as signed. Keep it as a
    // defense-in-depth verifier while the unsigned value is representable.
    if (nextSignCount <= 0x7fff_ffff) {
      const libraryResult = nodeVerifyAssertion({
        assertion: input.assertionObject,
        payload: input.clientData,
        publicKey: input.key.publicKeyPEM,
        bundleIdentifier: this.bundleIdentifier,
        teamIdentifier: this.teamIdentifier,
        signCount: input.key.signCount,
      });
      if (libraryResult.signCount !== nextSignCount) {
        throw new Error("App Attest assertion verifier result mismatch.");
      }
    }
    return nextSignCount;
  }

  private validateAttestationAuthenticatorData(
    authData: Buffer,
    keyId: string,
  ): {
    readonly environment: "production" | "development";
    readonly usesCurrentSandboxAAGUID: boolean;
  } {
    if (!authData.subarray(0, 32).equals(this.appIdHash)) {
      throw new Error("Attestation App ID mismatch.");
    }
    const flags = authData[32];
    if (
      flags === undefined ||
      (flags & attestedCredentialDataFlag) === 0 ||
      (flags & ~(attestedCredentialDataFlag | extensionDataFlag)) !== 0
    ) {
      throw new Error("Invalid attestation authenticator flags.");
    }
    if (authData.readUInt32BE(33) !== 0) {
      throw new Error("Invalid attestation counter.");
    }
    const aaguid = authData.subarray(37, 53);
    let environment: "production" | "development";
    let usesCurrentSandboxAAGUID = false;
    if (aaguid.equals(productionAAGUID)) {
      environment = "production";
    } else if (
      (aaguid.equals(legacyDevelopmentAAGUID) || aaguid.equals(sandboxAAGUID)) &&
      this.allowDevelopmentEnvironment
    ) {
      environment = "development";
      usesCurrentSandboxAAGUID = aaguid.equals(sandboxAAGUID);
    } else {
      throw new Error("Attestation environment is not allowed.");
    }
    const credentialLength = authData.readUInt16BE(53);
    const keyIdData = strictBase64(inputKeyId(keyId));
    if (
      credentialLength !== 32 ||
      keyIdData.length !== 32 ||
      !authData.subarray(55, 87).equals(keyIdData)
    ) {
      throw new Error("Attestation credential ID mismatch.");
    }
    return { environment, usesCurrentSandboxAAGUID };
  }

  private validateCertificateChain(
    leafData: Buffer,
    intermediateData: Buffer,
  ): X509Certificate {
    const leaf = new X509Certificate(leafData);
    const intermediate = new X509Certificate(intermediateData);
    const now = this.now();
    if (!Number.isFinite(now.getTime())) {
      throw new Error("App Attest verifier clock returned an invalid date.");
    }
    if (
      leaf.ca ||
      !intermediate.ca ||
      leaf.issuer !== intermediate.subject ||
      intermediate.issuer !== appleAppAttestationRoot.subject ||
      !leaf.verify(intermediate.publicKey) ||
      !intermediate.verify(appleAppAttestationRoot.publicKey) ||
      !certificateIsValidAt(leaf, now) ||
      !certificateIsValidAt(intermediate, now) ||
      !certificateIsValidAt(appleAppAttestationRoot, now)
    ) {
      throw new Error("Invalid Apple App Attest certificate chain.");
    }
    validatePublicKey(leaf.publicKey.export({ type: "spki", format: "pem" }).toString());
    return leaf;
  }
}

function isPinnedSandboxAAGUIDCompatibilityError(error: unknown): boolean {
  return error instanceof Error && error.message === "aaguid is not valid";
}

interface ParsedExtensions {
  readonly validationCategory?: number;
  readonly bundleVersion?: string;
}

function parseAttestationRemainder(
  authData: Buffer,
  allowedValidationCategories: ReadonlySet<number>,
  supportedBundleVersions: ReadonlySet<string>,
): ParsedExtensions {
  const values = decodeCBORSequence(authData.subarray(87));
  if (values.length < 1 || values.length > 2) {
    throw new Error("Invalid attestation authenticator data.");
  }
  validateCOSEKey(values[0]);
  const hasExtensions = (authData[32] ?? 0) & extensionDataFlag;
  if (hasExtensions === 0 && values.length !== 1) {
    throw new Error("Unexpected attestation extension data.");
  }
  if (hasExtensions !== 0 && values.length !== 2) {
    throw new Error("Missing attestation extension data.");
  }
  if (hasExtensions !== 0) {
    return parseKnownExtensions(
      values[1],
      allowedValidationCategories,
      supportedBundleVersions,
    );
  }
  return {};
}

function parseAssertionRemainder(
  authData: Buffer,
  allowedValidationCategories: ReadonlySet<number>,
  supportedBundleVersions: ReadonlySet<string>,
): ParsedExtensions {
  const hasExtensions = ((authData[32] ?? 0) & extensionDataFlag) !== 0;
  if (!hasExtensions) {
    if (authData.length !== 37) {
      throw new Error("Unexpected assertion authenticator data.");
    }
    return {};
  }
  const values = decodeCBORSequence(authData.subarray(37));
  if (values.length !== 1) {
    throw new Error("Invalid assertion extension data.");
  }
  return parseKnownExtensions(
    values[0],
    allowedValidationCategories,
    supportedBundleVersions,
  );
}

function parseKnownExtensions(
  value: unknown,
  allowedValidationCategories: ReadonlySet<number>,
  supportedBundleVersions: ReadonlySet<string>,
): ParsedExtensions {
  let entries: readonly (readonly [string, unknown])[];
  if (value instanceof Map) {
    entries = [...value.entries()].map(([key, entryValue]) => {
      if (typeof key !== "string") {
        throw new Error("Unknown App Attest extension.");
      }
      return [key, entryValue] as const;
    });
  } else if (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  ) {
    entries = Object.entries(value as Record<string, unknown>);
  } else {
    throw new Error("Invalid App Attest extensions.");
  }
  const extensions = new Map(entries);
  if (
    extensions.size !== 2 ||
    !extensions.has("apple_validation_category_01") ||
    !extensions.has("apple_bundle_version_01")
  ) {
    throw new Error("App Attest extension pair is incomplete or unknown.");
  }
  const validationCategory = extensions.get("apple_validation_category_01");
  const bundleVersion = extensions.get("apple_bundle_version_01");
  if (
    !Number.isSafeInteger(validationCategory) ||
    (validationCategory as number) < 0 ||
    (validationCategory as number) > 0xffff_ffff ||
    typeof bundleVersion !== "string" ||
    bundleVersion.length < 1 ||
    bundleVersion.length > 64
  ) {
    throw new Error("Invalid App Attest extension values.");
  }
  if (
    !allowedValidationCategories.has(validationCategory as number) ||
    !supportedBundleVersions.has(bundleVersion)
  ) {
    throw new Error("Unsupported App Attest extension values.");
  }
  return {
    validationCategory: validationCategory as number,
    bundleVersion,
  };
}

function validateCOSEKey(value: unknown): void {
  if (!(value instanceof Map) || value.size !== 5) {
    throw new Error("Invalid App Attest credential public key.");
  }
  const expectedKeys = [-3, -2, -1, 1, 3];
  const actualKeys = [...value.keys()];
  if (
    actualKeys.some((key) => typeof key !== "number") ||
    !expectedKeys.every((key) => value.has(key)) ||
    value.get(1) !== 2 ||
    value.get(3) !== -7 ||
    value.get(-1) !== 1 ||
    !isBufferOfLength(value.get(-2), 32) ||
    !isBufferOfLength(value.get(-3), 32)
  ) {
    throw new Error("Invalid App Attest credential public key.");
  }
}

function decodeCBORSequence(value: Buffer): unknown[] {
  try {
    const decode = cbor.decodeAllSync as unknown as (input: Buffer) => unknown[];
    return decode(value);
  } catch {
    throw new Error("Invalid CBOR data.");
  }
}

function requireRecord(value: unknown, expectedKeys: readonly string[]): Record<string, unknown> {
  if (
    typeof value !== "object" ||
    value === null ||
    Array.isArray(value) ||
    value instanceof Map ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) {
    throw new Error("Invalid CBOR object.");
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).toSorted();
  if (
    keys.length !== expectedKeys.length ||
    !keys.every((key, index) => key === expectedKeys[index])
  ) {
    throw new Error("Unexpected CBOR object fields.");
  }
  return record;
}

function requireSizedBuffer(value: unknown, minimum: number, maximum: number): Buffer {
  if (!Buffer.isBuffer(value) || value.length < minimum || value.length > maximum) {
    throw new Error("Invalid binary field.");
  }
  return value;
}

function isBufferOfLength(value: unknown, length: number): boolean {
  return Buffer.isBuffer(value) && value.length === length;
}

function certificateIsValidAt(certificate: X509Certificate, date: Date): boolean {
  const validFrom = Date.parse(certificate.validFrom);
  const validTo = Date.parse(certificate.validTo);
  const timestamp = date.getTime();
  return Number.isFinite(validFrom) && Number.isFinite(validTo) && timestamp >= validFrom && timestamp <= validTo;
}

function validatePublicKey(publicKeyPEM: string): void {
  if (publicKeyPEM.length < 64 || publicKeyPEM.length > 4_096) {
    throw new Error("Invalid App Attest public key.");
  }
  const key = createPublicKey(publicKeyPEM);
  if (
    key.asymmetricKeyType !== "ec" ||
    key.asymmetricKeyDetails?.namedCurve !== "prime256v1"
  ) {
    throw new Error("App Attest key must use P-256.");
  }
}

function validatedBundleVersionAllowlist(values: readonly string[]): ReadonlySet<string> {
  if (
    values.length > 32 ||
    values.some(
      (value) =>
        value.length < 1 ||
        value.length > 64 ||
        !/^[A-Za-z0-9._-]+$/u.test(value),
    ) ||
    new Set(values).size !== values.length
  ) {
    throw new Error("App Attest bundle-version allowlist is invalid.");
  }
  return new Set(values);
}

function validationCategoriesFor(
  environment: "production" | "development",
): ReadonlySet<number> {
  return environment === "development"
    ? developmentValidationCategories
    : productionValidationCategories;
}

function strictBase64(value: string): Buffer {
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) {
    throw new Error("Invalid App Attest key ID.");
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) {
    throw new Error("Invalid App Attest key ID.");
  }
  return decoded;
}

function inputKeyId(value: string): string {
  return value;
}
