export function normalizeProviderEVSEKey(value: string): string | undefined {
  const normalized = value.toUpperCase().replaceAll(/[^A-Z0-9]/gu, "");
  return normalized.length >= 4 && normalized.length <= 64 ? normalized : undefined;
}

export function normalizeOICPEVSEIdentity(value: string): string | undefined {
  const normalized = normalizeProviderEVSEKey(value);
  return normalized !== undefined && /^[A-Z]{2}[A-Z0-9]{3}E[A-Z0-9]{1,48}$/u.test(normalized)
    ? normalized
    : undefined;
}
