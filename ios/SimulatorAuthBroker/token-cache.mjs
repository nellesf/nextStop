export const refreshMarginSeconds = 60;

export function expiryFromMintStart(mintStartedAt, expiresInSeconds) {
  if (
    !Number.isFinite(mintStartedAt) ||
    !Number.isSafeInteger(expiresInSeconds) ||
    expiresInSeconds < 1
  ) {
    throw new Error("Invalid Simulator token lifetime.");
  }
  return mintStartedAt + expiresInSeconds * 1_000;
}

export function responseWithRemainingLifetime(cachedToken, now) {
  if (!Number.isFinite(now)) {
    return undefined;
  }
  const remainingSeconds = Math.floor((cachedToken.expiresAt - now) / 1_000);
  if (remainingSeconds <= refreshMarginSeconds) {
    return undefined;
  }
  return {
    ...cachedToken.response,
    expiresInSeconds: Math.min(
      cachedToken.response.expiresInSeconds,
      remainingSeconds,
    ),
  };
}
