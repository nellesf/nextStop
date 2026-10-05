import assert from "node:assert/strict";
import test from "node:test";

import {
  InvalidPaginationTokenError,
  SignedPaginationCodec,
} from "../../src/application/signed-pagination.js";

const codec = new SignedPaginationCodec("unit-test-signing-key-with-at-least-32-bytes");
const snapshot = {
  kind: "snapshot",
  version: 3,
  projectionId: "11111111-1111-4111-8111-111111111111",
  foodProjectionId: null,
  availabilitySnapshotIds: ["22222222-2222-4222-8222-222222222222"],
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

void test("demand snapshot mode requires an immutable positive expiry and no pinned live IDs", () => {
  const demand = { ...snapshot, availabilitySnapshotIds: [], availabilityExpiresAt: 1_791_115_200_000 };
  assert.deepEqual(codec.decodeSnapshot(codec.encode(demand)), demand);
  for (const expiry of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => codec.decodeSnapshot(codec.encode({ ...demand, availabilityExpiresAt: expiry })), InvalidPaginationTokenError);
  }
  assert.throws(() => codec.decodeSnapshot(codec.encode({ ...snapshot, availabilityExpiresAt: demand.availabilityExpiresAt })), InvalidPaginationTokenError);
});
