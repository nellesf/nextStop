import { fileURLToPath } from "node:url";

import { AccessTokenCodec } from "../api/access-token.js";

export function mintDevelopmentAccessToken(signingKey: string): string {
  const token = new AccessTokenCodec(signingKey).issue({ client: "simulator" });
  return JSON.stringify(token);
}

function requiredEnvironmentValue(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`${name} must be configured.`);
  }
  return value;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.stdout.write(
    `${mintDevelopmentAccessToken(requiredEnvironmentValue("SEARCH_ACCESS_TOKEN_SIGNING_KEY"))}\n`,
  );
}
