import assert from "node:assert/strict";
import test from "node:test";
import { mintCloudRunToken } from "./cloud-run.mjs";

const endpoints = [
  ["staging", "nextstop-tech-testing", "353471052580"],
  ["production", "nextstop-tech-staging", "1022346259037"],
];
for (const [name, project, number] of endpoints) {
  const config = { name, project, region: "europe-west1", service: "nextstop-broker" };
  test(`cloud broker sends developer IAM only to the fixed private ${name} endpoint`, async () => {
    const result = await mintCloudRunToken(config, {
      execute: async (binary, args) => {
        assert.equal(binary, "gcloud");
        assert.deepEqual(args, ["auth", "print-identity-token"]);
        return { stdout: "synthetic-identity\n" };
      },
      fetch: async (url, options) => {
        assert.equal(url, `https://nextstop-broker-${number}.europe-west1.run.app/token`);
        assert.equal(options.redirect, "error");
        assert.deepEqual(options.headers, { Authorization: "Bearer synthetic-identity" });
        return new Response('{"accessToken":"synthetic"}');
      },
    });
    assert.equal(result, '{"accessToken":"synthetic"}');
  });
  test(`cloud broker rejects crossed ${name} resources before acquiring a credential`, async () => {
    for (const changes of [{ project: "another-project" }, { region: "other" }, { service: "another-service" }]) {
      await assert.rejects(mintCloudRunToken({ ...config, ...changes }, {
        execute: assert.fail, fetch: assert.fail,
      }), /restricted/u);
    }
    await assert.rejects(mintCloudRunToken(config, {
      execute: () => { throw new Error("private material"); },
    }), error => !error.message.includes("private material"));
  });
}
