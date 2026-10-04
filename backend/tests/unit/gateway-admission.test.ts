import assert from "node:assert/strict";
import test from "node:test";
import { GatewayAdmission, gatewayAdmissionLimits } from "../../src/api/gateway-admission.js";

void test("distributed IPs share each global ceiling and its exact refill", () => {
  for (const group of ["api", "auth", "reports", "invalid"] as const) {
    let now = 0;
    const admission = new GatewayAdmission(() => now);
    const limit = gatewayAdmissionLimits[group].global;
    for (let i = 0; i < limit.burst; i++) assert.equal(admission.allows(`192.0.2.${i}`, group), true);
    assert.equal(admission.allows("198.51.100.1", group), false);
    now = 60_000 / limit.perMinute - 1;
    assert.equal(admission.allows("198.51.100.1", group), false);
    now += 1;
    assert.equal(admission.allows("198.51.100.1", group), true);
    assert.equal(admission.allows("198.51.100.2", group), false);
  }
});

void test("rejected requests cannot poison refill or consume another client's global budget", () => {
  let now = 0;
  const admission = new GatewayAdmission(() => now);
  for (let i = 0; i < 5; i++) assert.equal(admission.allows("192.0.2.1", "api"), true);
  for (let i = 0; i < 100; i++) assert.equal(admission.allows("192.0.2.1", "api"), false);
  for (let i = 0; i < 15; i++) assert.equal(admission.allows(`198.51.100.${i}`, "api"), true);
  for (now = 1; now < 1_000; now++) assert.equal(admission.allows("192.0.2.1", "api"), false);
  assert.equal(admission.allows("192.0.2.1", "api"), true);
  assert.equal(admission.allows("192.0.2.1", "api"), false);
});

void test("clock rollback or invalid clocks never grant tokens and recovery remains possible", () => {
  let now = 1_000;
  const admission = new GatewayAdmission(() => now);
  for (let i = 0; i < 5; i++) assert.equal(admission.allows("192.0.2.1", "api"), true);
  for (const time of [0, Number.NaN, Number.POSITIVE_INFINITY, 1_000, 1_999]) {
    now = time; assert.equal(admission.allows("192.0.2.1", "api"), false);
  }
  now = 2_000; assert.equal(admission.allows("192.0.2.1", "api"), true);
});

void test("bounded IP storage reclaims inactive clients instead of permanently blocking new ones", () => {
  let now = 0;
  const admission = new GatewayAdmission(() => now);
  // Each new source spends one global token. Enough legitimate elapsed time
  // accumulates for old entries to expire before the 10,000-entry ceiling.
  for (let i = 0; i < 10_050; i++) {
    now = i * 500;
    assert.equal(admission.allows(`client-${i}`, "api"), true);
  }
  assert.equal(admission.allows("new-client", "invalid"), true);
});
