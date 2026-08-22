import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

import cbor from "cbor";

import { HardenedAppAttestVerifier } from "../../src/api/app-attest-verifier.js";
import {
  StaleAppAttestAssertionCounterError,
  type AttestedKey,
} from "../../src/application/app-attest-authentication.js";

const appId = "ABCDEFGHIJ.de.nextstop.app";
const clientData = Buffer.alloc(32, 5);
const appAttestAssertionFlags = 0x40;

void test("verifies the pinned library's development attestation with strict chain checks", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../node_modules/node-app-attest/test/fixtures/attestation-development.json",
        import.meta.url,
      ),
      "utf8",
    ),
  ) as { readonly attestation: string; readonly challenge: string; readonly keyId: string };
  const verifier = new HardenedAppAttestVerifier(
    "V8H6LQ9448.io.uebelacker.AppAttestExample",
    {
      allowDevelopmentEnvironment: true,
      now: () => new Date("2024-03-01T00:00:00.000Z"),
    },
  );
  const [decodedFixture] = cbor.decodeAllSync(
    Buffer.from(fixture.attestation, "base64"),
  ) as [{ readonly authData: Buffer }];
  assert.equal(
    decodedFixture.authData.subarray(37, 53).toString("ascii"),
    "appattestdevelop",
  );

  const result = verifier.verifyAttestation({
    attestationObject: Buffer.from(fixture.attestation, "base64"),
    clientData: Buffer.from(fixture.challenge, "base64"),
    keyId: fixture.keyId,
  });

  assert.equal(result.environment, "development");
  assert.match(result.publicKeyPEM, /BEGIN PUBLIC KEY/u);
  assert.ok(result.receipt.length > 0);
});

void test("development attestations are not accepted without an explicit allowlist", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../node_modules/node-app-attest/test/fixtures/attestation-development.json",
        import.meta.url,
      ),
      "utf8",
    ),
  ) as { readonly attestation: string; readonly challenge: string; readonly keyId: string };
  const verifier = new HardenedAppAttestVerifier(
    "V8H6LQ9448.io.uebelacker.AppAttestExample",
    { now: () => new Date("2024-03-01T00:00:00.000Z") },
  );

  assert.throws(
    () =>
      verifier.verifyAttestation({
        attestationObject: Buffer.from(fixture.attestation, "base64"),
        clientData: Buffer.from(fixture.challenge, "base64"),
        keyId: fixture.keyId,
      }),
    /environment is not allowed/u,
  );
});

void test("accepts Apple's current extension encoding without relying on the ED flag", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../node_modules/node-app-attest/test/fixtures/attestation-development.json",
        import.meta.url,
      ),
      "utf8",
    ),
  ) as { readonly attestation: string; readonly challenge: string; readonly keyId: string };
  const originalAttestation = Buffer.from(fixture.attestation, "base64");
  const [decoded] = cbor.decodeAllSync(originalAttestation) as [{
    readonly attStmt: unknown;
    readonly authData: Buffer;
    readonly fmt: string;
  }];
  const baseline = new HardenedAppAttestVerifier(
    "V8H6LQ9448.io.uebelacker.AppAttestExample",
    {
      allowDevelopmentEnvironment: true,
      now: () => new Date("2024-03-01T00:00:00.000Z"),
    },
  ).verifyAttestation({
    attestationObject: originalAttestation,
    clientData: Buffer.from(fixture.challenge, "base64"),
    keyId: fixture.keyId,
  });
  const extensions = cbor.encode(
    new Map<string, unknown>([
      ["apple_bundle_version_01", "1"],
      ["apple_validation_category_01", validationCategory(3)],
    ]),
  );
  const authData = Buffer.concat([decoded.authData, extensions]);
  assert.equal(authData[32], 0x40);

  const result = new HardenedAppAttestVerifier(
    "V8H6LQ9448.io.uebelacker.AppAttestExample",
    {
      allowDevelopmentEnvironment: true,
      supportedBundleVersions: ["1"],
      now: () => new Date("2024-03-01T00:00:00.000Z"),
      pinnedNodeAttestationVerifier: () => ({
        publicKey: baseline.publicKeyPEM,
        receipt: baseline.receipt,
        environment: baseline.environment,
      }),
    },
  ).verifyAttestation({
    attestationObject: cbor.encode({ ...decoded, authData }),
    clientData: Buffer.from(fixture.challenge, "base64"),
    keyId: fixture.keyId,
  });

  assert.equal(result.validationCategory, 3);
  assert.equal(result.bundleVersion, "1");

  // Compact regression vector derived from Apple's 2026 validation guide.
  const appleAuthenticatorData = Buffer.from(
    "9EZtaPketsEGIMt+Y8coMkRoXuHWRntUFg51MXIFfwNAAAAAAGFwcGF0dGVzdAAAAAAAAAAAIM4EmPWEg/u02g17LGOlpTj1UtSty5pPqRYZXElhPmVdpQECAyYgASFYIEMyVErPMj23dEQ8qvM59W5+lcck+sLBQlnzZeJEVlCyIlggtfsoW89Um8tgWUQS52gqJCfuran7Ut/tCxqxftCfqb2id2FwcGxlX2J1bmRsZV92ZXJzaW9uXzAxYTF4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAQAAAA==",
    "base64",
  );
  const appleRemainder = cbor.decodeAllSync(appleAuthenticatorData.subarray(87));
  const appleExtensions = appleRemainder[1] as Record<string, unknown>;
  const appleCategory = appleExtensions.apple_validation_category_01;
  assert.equal(appleAuthenticatorData[32], 0x40);
  assert.equal(appleRemainder.length, 2);
  assert.ok(Buffer.isBuffer(appleCategory));
  assert.equal(appleCategory.readUInt32LE(0), 1);
  assert.equal(appleExtensions.apple_bundle_version_01, "1");
});

void test("accepts Apple's current sandbox AAGUID only at the pinned compatibility boundary", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../node_modules/node-app-attest/test/fixtures/attestation-development.json",
        import.meta.url,
      ),
      "utf8",
    ),
  ) as { readonly attestation: string; readonly challenge: string; readonly keyId: string };
  const decodedValues = cbor.decodeAllSync(Buffer.from(fixture.attestation, "base64"));
  assert.equal(decodedValues.length, 1);
  const decoded = decodedValues[0] as {
    readonly attStmt: unknown;
    readonly authData: Buffer;
    readonly fmt: string;
  };
  const authData = Buffer.from(decoded.authData);
  Buffer.from("appattestsandbox", "ascii").copy(authData, 37);
  const sandboxAttestation = cbor.encode({ ...decoded, authData });
  let compatibilityVerifierCalls = 0;
  const verifier = new HardenedAppAttestVerifier(
    "V8H6LQ9448.io.uebelacker.AppAttestExample",
    {
      allowDevelopmentEnvironment: true,
      now: () => new Date("2024-03-01T00:00:00.000Z"),
      pinnedNodeAttestationVerifier: () => {
        compatibilityVerifierCalls += 1;
        throw new Error("aaguid is not valid");
      },
    },
  );

  const result = verifier.verifyAttestation({
    attestationObject: sandboxAttestation,
    clientData: Buffer.from(fixture.challenge, "base64"),
    keyId: fixture.keyId,
  });

  assert.equal(compatibilityVerifierCalls, 1);
  assert.equal(result.environment, "development");
  assert.match(result.publicKeyPEM, /BEGIN PUBLIC KEY/u);
  assert.ok(result.receipt.length > 0);
  assert.throws(
    () =>
      new HardenedAppAttestVerifier(
        "V8H6LQ9448.io.uebelacker.AppAttestExample",
        { now: () => new Date("2024-03-01T00:00:00.000Z") },
      ).verifyAttestation({
        attestationObject: sandboxAttestation,
        clientData: Buffer.from(fixture.challenge, "base64"),
        keyId: fixture.keyId,
      }),
    /environment is not allowed/u,
  );
});

void test("does not swallow other pinned-verifier failures for the current sandbox AAGUID", async () => {
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../node_modules/node-app-attest/test/fixtures/attestation-development.json",
        import.meta.url,
      ),
      "utf8",
    ),
  ) as { readonly attestation: string; readonly challenge: string; readonly keyId: string };
  const [decoded] = cbor.decodeAllSync(Buffer.from(fixture.attestation, "base64")) as [{
    readonly attStmt: unknown;
    readonly authData: Buffer;
    readonly fmt: string;
  }];
  const authData = Buffer.from(decoded.authData);
  Buffer.from("appattestsandbox", "ascii").copy(authData, 37);
  const verifier = new HardenedAppAttestVerifier(
    "V8H6LQ9448.io.uebelacker.AppAttestExample",
    {
      allowDevelopmentEnvironment: true,
      now: () => new Date("2024-03-01T00:00:00.000Z"),
      pinnedNodeAttestationVerifier: () => {
        throw new Error("nonce does not match");
      },
    },
  );

  assert.throws(
    () =>
      verifier.verifyAttestation({
        attestationObject: cbor.encode({ ...decoded, authData }),
        clientData: Buffer.from(fixture.challenge, "base64"),
        keyId: fixture.keyId,
      }),
    /nonce does not match/u,
  );
});

void test("assertion counters are parsed as unsigned 32-bit values", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const verifier = new HardenedAppAttestVerifier(appId);
  const assertionObject = makeAssertion(
    privateKey,
    0x8000_0000,
    appAttestAssertionFlags,
  );

  const counter = verifier.verifyAssertion({
    assertionObject,
    clientData,
    key: makeKey(publicKeyPEM, 0x7fff_ffff),
  });

  assert.equal(counter, 0x8000_0000);
});

void test("verifies the pinned library's real Apple assertion flags", () => {
  const assertionObject = Buffer.from(
    "omlzaWduYXR1cmVYRzBFAiBB8BGAwkmFCg1M5J0mOYEun0SUN1/lse79/7ypG9WiMQIhAIHvqj7eg59B1PMFX1CN4GMGlsgfFtdL30pHCf7G/dNRcWF1dGhlbnRpY2F0b3JEYXRhWCXKPdw7T3iujcFZbHVrHX0mDSMrNms5PzEbrFbQPRA6rEAAAAAB",
    "base64",
  );
  const publicKeyPEM =
    "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEg69t2YzgcPTLUx8Zgu+rbcikeaEL\n8Ppb+HG0QTIulz8YUB9tgv1pDRruWk87nZC3our56pzIWaqXEbaWyamdzA==\n-----END PUBLIC KEY-----\n";
  const assertionClientData = Buffer.from(
    '{"subject":"Lorem ipsum","message":"Lorem ipsum dolor sit amet, consectetur adipiscing elit."}',
    "utf8",
  );
  const [decoded] = cbor.decodeAllSync(assertionObject) as [{
    readonly authenticatorData: Buffer;
  }];

  assert.equal(decoded.authenticatorData.length, 37);
  assert.equal(decoded.authenticatorData[32], appAttestAssertionFlags);
  assert.equal(
    new HardenedAppAttestVerifier(
      "V8H6LQ9448.io.uebelacker.AppAttestExample",
    ).verifyAssertion({
      assertionObject,
      clientData: assertionClientData,
      key: makeKey(publicKeyPEM, 0),
    }),
    1,
  );
});

void test("assertions reject missing or unknown authenticator flags", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const verifier = new HardenedAppAttestVerifier(appId);

  for (const flags of [0, 0x20, appAttestAssertionFlags | 0x20]) {
    assert.throws(
      () =>
        verifier.verifyAssertion({
          assertionObject: makeAssertion(privateKey, 1, flags),
          clientData,
          key: makeKey(publicKeyPEM, 0),
        }),
      /Invalid assertion authenticator flags/u,
    );
  }
});

void test("disabling development rejects existing development keys but keeps production keys valid", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const assertionObject = makeAssertion(privateKey, 1, appAttestAssertionFlags);
  const developmentKey: AttestedKey = {
    ...makeKey(publicKeyPEM, 0),
    environment: "development",
  };

  assert.throws(
    () =>
      new HardenedAppAttestVerifier(appId).verifyAssertion({
        assertionObject,
        clientData,
        key: developmentKey,
      }),
    /environment is not allowed/u,
  );
  assert.equal(
    new HardenedAppAttestVerifier(appId, {
      allowDevelopmentEnvironment: true,
    }).verifyAssertion({
      assertionObject,
      clientData,
      key: developmentKey,
    }),
    1,
  );
  assert.equal(
    new HardenedAppAttestVerifier(appId).verifyAssertion({
      assertionObject,
      clientData,
      key: makeKey(publicKeyPEM, 0),
    }),
    1,
  );
});

void test("all iOS 27 assertion extensions and extra CBOR objects fail closed", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const verifier = new HardenedAppAttestVerifier(appId);
  const unknownExtension = cbor.encode(new Map([["future_ios_extension", 1]]));
  const assertion = makeAssertion(
    privateKey,
    1,
    appAttestAssertionFlags,
    unknownExtension,
  );

  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: assertion,
        clientData,
        key: makeKey(publicKeyPEM, 0),
      }),
    /incomplete or unknown/u,
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: Buffer.concat([
          makeAssertion(privateKey, 1, appAttestAssertionFlags),
          cbor.encode({}),
        ]),
        clientData,
        key: makeKey(publicKeyPEM, 0),
      }),
    /CBOR sequence/u,
  );
  const incorrectlyTypedKnownExtension = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", 3],
      ["apple_bundle_version_01", "1"],
    ]),
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          privateKey,
          1,
          appAttestAssertionFlags,
          incorrectlyTypedKnownExtension,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 0),
      }),
    /Invalid App Attest extension values/u,
  );
  const incompletePair = cbor.encode(
    new Map([["apple_validation_category_01", validationCategory(4)]]),
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          privateKey,
          1,
          appAttestAssertionFlags,
          incompletePair,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 0),
      }),
    /extension pair is incomplete/u,
  );
});

void test("iOS 27 extension pairs require the official category and bundle allowlist", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const verifier = new HardenedAppAttestVerifier(appId, {
    supportedBundleVersions: ["1"],
  });
  const allowedExtensions = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", validationCategory(4)],
      ["apple_bundle_version_01", "1"],
    ]),
  );
  const keyWithOlderAuditMetadata = {
    ...makeKey(publicKeyPEM, 0),
    validationCategory: 2,
    bundleVersion: "0",
  };

  assert.equal(
    verifier.verifyAssertion({
      assertionObject: makeAssertion(
        privateKey,
        1,
        appAttestAssertionFlags,
        allowedExtensions,
      ),
      clientData,
      key: keyWithOlderAuditMetadata,
    }),
    1,
  );

  const testFlightExtensions = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", validationCategory(2)],
      ["apple_bundle_version_01", "1"],
    ]),
  );
  assert.equal(
    verifier.verifyAssertion({
      assertionObject: makeAssertion(
        privateKey,
        2,
        appAttestAssertionFlags,
        testFlightExtensions,
      ),
      clientData,
      key: makeKey(publicKeyPEM, 1),
    }),
    2,
  );

  const developmentCategory = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", validationCategory(3)],
      ["apple_bundle_version_01", "1"],
    ]),
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          privateKey,
          2,
          appAttestAssertionFlags,
          developmentCategory,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 1),
      }),
    /Unsupported App Attest extension values/u,
  );

  const unsupportedBuild = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", validationCategory(4)],
      ["apple_bundle_version_01", "2"],
    ]),
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          privateKey,
          2,
          appAttestAssertionFlags,
          unsupportedBuild,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 1),
      }),
    /Unsupported App Attest extension values/u,
  );

  const wrongEndianCategory = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", Buffer.from([0, 0, 0, 4])],
      ["apple_bundle_version_01", "1"],
    ]),
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          privateKey,
          2,
          appAttestAssertionFlags,
          wrongEndianCategory,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 1),
      }),
    /Unsupported App Attest extension values/u,
  );

  const wrongLengthCategory = cbor.encode(
    new Map<string, unknown>([
      ["apple_validation_category_01", Buffer.from([4])],
      ["apple_bundle_version_01", "1"],
    ]),
  );
  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          privateKey,
          2,
          appAttestAssertionFlags,
          wrongLengthCategory,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 1),
      }),
    /Invalid App Attest extension values/u,
  );
});

void test("an assertion counter that has already been observed has a typed conflict", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const verifier = new HardenedAppAttestVerifier(appId);

  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(privateKey, 7, appAttestAssertionFlags),
        clientData,
        key: makeKey(publicKeyPEM, 7),
      }),
    StaleAppAttestAssertionCounterError,
  );
});

void test("an invalid signature is rejected before a stale counter is classified", () => {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const { privateKey: attackerPrivateKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const publicKeyPEM = publicKey.export({ type: "spki", format: "pem" }).toString();
  const verifier = new HardenedAppAttestVerifier(appId);

  assert.throws(
    () =>
      verifier.verifyAssertion({
        assertionObject: makeAssertion(
          attackerPrivateKey,
          7,
          appAttestAssertionFlags,
        ),
        clientData,
        key: makeKey(publicKeyPEM, 7),
      }),
    (error: unknown) =>
      error instanceof Error &&
      !(error instanceof StaleAppAttestAssertionCounterError) &&
      error.message === "Invalid App Attest assertion signature.",
  );
});

function makeAssertion(
  privateKey: Parameters<typeof sign>[2],
  counter: number,
  flags: number,
  extensions: Uint8Array = Buffer.alloc(0),
): Buffer {
  const authenticatorData = Buffer.alloc(37);
  createHash("sha256").update(appId, "utf8").digest().copy(authenticatorData, 0);
  authenticatorData[32] = flags;
  authenticatorData.writeUInt32BE(counter, 33);
  const completeAuthenticatorData = Buffer.concat([authenticatorData, Buffer.from(extensions)]);
  const clientDataHash = createHash("sha256").update(clientData).digest();
  const nonce = createHash("sha256")
    .update(Buffer.concat([completeAuthenticatorData, clientDataHash]))
    .digest();
  const signature = sign("sha256", nonce, privateKey);
  return cbor.encode({ signature, authenticatorData: completeAuthenticatorData });
}

function validationCategory(value: number): Buffer {
  const encoded = Buffer.alloc(4);
  encoded.writeUInt32LE(value);
  return encoded;
}

function makeKey(publicKeyPEM: string, signCount: number): AttestedKey {
  return {
    keyIdHash: Buffer.alloc(32),
    publicKeyPEM,
    receipt: Buffer.from("receipt"),
    environment: "production",
    signCount,
    revoked: false,
  };
}
