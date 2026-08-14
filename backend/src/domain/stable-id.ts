import { createHash } from "node:crypto";

export function stableId(scope: string, parts: readonly string[]): string {
  const digest = createHash("sha256")
    .update(scope)
    .update("\u0000")
    .update(parts.join("\u0000"))
    .digest();

  const versionByte = digest[6];
  const variantByte = digest[8];
  if (versionByte === undefined || variantByte === undefined) {
    throw new Error("SHA-256 digest was unexpectedly short.");
  }
  digest[6] = (versionByte & 0x0f) | 0x80;
  digest[8] = (variantByte & 0x3f) | 0x80;

  const hex = digest.subarray(0, 16).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
