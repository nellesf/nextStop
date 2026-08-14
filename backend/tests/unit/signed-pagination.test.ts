import assert from "node:assert/strict";
import test from "node:test";

import {
  InvalidPaginationTokenError,
  SignedPaginationCodec,
} from "../../src/application/signed-pagination.js";

const codec = new SignedPaginationCodec("unit-test-signing-key-with-at-least-32-bytes");
const snapshot = {
  kind: "snapshot",
  version: 1,
  projectionId: "11111111-1111-4111-8111-111111111111",
  requestFingerprint: "a".repeat(64),
} as const;

void test("round-trips a signed snapshot", () => {
  assert.deepEqual(codec.decodeSnapshot(codec.encode(snapshot)), snapshot);
});

void test("rejects a modified signature", () => {
  const token = codec.encode(snapshot);
  const modified = `${token.slice(0, -1)}${token.endsWith("a") ? "b" : "a"}`;
  assert.throws(() => codec.decodeSnapshot(modified), InvalidPaginationTokenError);
});

void test("does not accept one token kind as another", () => {
  assert.throws(() => codec.decodeCursor(codec.encode(snapshot)), InvalidPaginationTokenError);
});
