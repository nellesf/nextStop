import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { Transform, type TransformCallback } from "node:stream";

import { parse } from "csv-parse";

import type {
  NormalizedChargingConnector,
  NormalizedChargingLocation,
  NormalizedChargingPoint,
  NormalizedLocationObservation,
  QuarantinedProviderRecord,
  SourceReference,
} from "../../domain/normalized-charging.js";
import {
  normalizeOICPEVSEIdentity,
  normalizeProviderEVSEKey,
} from "../../domain/evse-identity.js";
import { stableId } from "../../domain/stable-id.js";
import {
  bundesnetzagenturHeaders,
  type BundesnetzagenturCSVRecord,
  type BundesnetzagenturHeader,
} from "./csv-record.js";
import { bundesnetzagenturDescriptor } from "./descriptor.js";

const headerMarker = Buffer.from("Ladeeinrichtungs-ID;", "utf8");
const maximumPreambleBytes = 64 * 1024;
const maximumRecordBytes = 64 * 1024;
const defaultMaximumFileBytes = 100 * 1024 * 1024;
const maximumChargingPointsPerLocation = 6;

export interface BundesnetzagenturCSVOptions {
  readonly filePath: string;
  readonly observedAt: string;
  readonly fetchedAt: string;
  readonly maximumFileBytes?: number;
}

export type BundesnetzagenturRecordResult =
  | Readonly<{ kind: "observation"; observation: NormalizedLocationObservation }>
  | Readonly<{
      kind: "quarantine";
      quarantine: QuarantinedProviderRecord;
      rawPayload: Readonly<Record<string, string>>;
    }>;

export async function* readBundesnetzagenturCSV(
  options: BundesnetzagenturCSVOptions,
): AsyncGenerator<BundesnetzagenturRecordResult> {
  validateInstant(options.observedAt, "observedAt");
  validateInstant(options.fetchedAt, "fetchedAt");

  const file = await stat(options.filePath);
  const maximumFileBytes = options.maximumFileBytes ?? defaultMaximumFileBytes;
  if (!file.isFile()) {
    throw new Error("Bundesnetzagentur input must be a regular file.");
  }
  if (file.size > maximumFileBytes) {
    throw new Error(`Bundesnetzagentur input exceeds ${maximumFileBytes} bytes.`);
  }

  const headerSeeker = new HeaderSeekingTransform();
  const records = createReadStream(options.filePath)
    .pipe(headerSeeker)
    .pipe(
      parse({
        bom: true,
        columns: validateHeaders,
        delimiter: ";",
        info: true,
        max_record_size: maximumRecordBytes,
        skip_empty_lines: true,
      }),
    );

  for await (const parsed of records) {
    const typed = parsed as Readonly<{
      info: Readonly<{ lines: number }>;
      record: BundesnetzagenturCSVRecord;
    }>;
    yield mapRecord(
      typed.record,
      typed.info.lines + headerSeeker.skippedLineCount,
      options,
    );
  }
}

function mapRecord(
  record: BundesnetzagenturCSVRecord,
  rowNumber: number,
  options: BundesnetzagenturCSVOptions,
): BundesnetzagenturRecordResult {
  const sourceRecordId = record["Ladeeinrichtungs-ID"].trim();
  const issueCodes: string[] = [];
  if (!/^\d+$/u.test(sourceRecordId)) {
    issueCodes.push("invalid_source_record_id");
  }

  const operatorName = record.Betreiber.trim();
  if (operatorName.length === 0) {
    issueCodes.push("missing_operator");
  }

  const active = parseStatus(record.Status, issueCodes);
  const chargingPointCount = parseChargingPointCount(record["Anzahl Ladepunkte"], issueCodes);
  const latitude = parseGermanNumber(record.Breitengrad);
  const longitude = parseGermanNumber(record.Längengrad);
  if (
    latitude === undefined ||
    longitude === undefined ||
    latitude < 47 ||
    latitude > 56 ||
    longitude < 5 ||
    longitude > 16
  ) {
    issueCodes.push("implausible_german_coordinate");
  }

  const contentHash = recordContentHash(record);
  const sourceReference: SourceReference = {
    providerId: bundesnetzagenturDescriptor.id,
    sourceRecordId,
    qualityTier: bundesnetzagenturDescriptor.qualityTier,
    observedAt: options.observedAt,
    fetchedAt: options.fetchedAt,
    contentHash,
  };

  const chargingPoints: NormalizedChargingPoint[] = [];
  if (chargingPointCount !== undefined) {
    for (let slot = 1; slot <= chargingPointCount; slot += 1) {
      const mapped = mapChargingPoint(record, slot, sourceReference);
      if (mapped === undefined) {
        issueCodes.push(`invalid_charging_point_${slot}`);
      } else {
        chargingPoints.push(mapped);
      }
    }
  }

  if (issueCodes.length > 0 || active === undefined || chargingPointCount === undefined) {
    return {
      kind: "quarantine",
      quarantine: {
        rowNumber,
        ...(sourceRecordId.length > 0 ? { sourceRecordId } : {}),
        issueCodes,
      },
      rawPayload: record,
    };
  }

  const location: NormalizedChargingLocation = {
    id: stableId("charging-location", [bundesnetzagenturDescriptor.id, sourceRecordId]),
    name: firstNonEmpty(
      record["Anzeigename (Karte)"],
      record.Standortbezeichnung,
      operatorName,
    ),
    operatorName,
    coordinate: {
      latitude: latitude as number,
      longitude: longitude as number,
    },
    address: compactAddress(record),
    chargingPoints,
    active,
    sourceReference,
  };

  return {
    kind: "observation",
    observation: {
      location,
      rawPayload: record,
    },
  };
}

function mapChargingPoint(
  record: BundesnetzagenturCSVRecord,
  slot: number,
  sourceReference: SourceReference,
): NormalizedChargingPoint | undefined {
  const connectorField = record[`Steckertypen${slot}` as BundesnetzagenturHeader];
  const powerField = record[`Nennleistung Stecker${slot}` as BundesnetzagenturHeader];
  const nativeIdentityValue = record[`EVSE-ID${slot}` as BundesnetzagenturHeader].trim();
  const connectorTypes = splitList(connectorField);
  const powers = splitList(powerField).map(parseGermanNumber);

  if (
    connectorTypes.length === 0 ||
    powers.length === 0 ||
    powers.some((power) => power === undefined || power <= 0)
  ) {
    return undefined;
  }

  const validPowers = powers as number[];
  const maximumPower = Math.max(...validPowers);
  const maximumPowerKW = Math.max(1, Math.floor(maximumPower));
  const connectors = mapConnectors(connectorTypes, validPowers);
  const providerEVSEKey = normalizeProviderEVSEKey(nativeIdentityValue);
  const canonicalEVSEIdentity = normalizeOICPEVSEIdentity(nativeIdentityValue);

  return {
    id: stableId("charging-point", [
      bundesnetzagenturDescriptor.id,
      sourceReference.sourceRecordId,
      String(slot),
    ]),
    ...(nativeIdentityValue.length > 0 ? { nativeIdentity: nativeIdentityValue } : {}),
    ...(providerEVSEKey === undefined ? {} : { providerEVSEKey }),
    ...(canonicalEVSEIdentity === undefined ? {} : { canonicalEVSEIdentity }),
    identityDecision: canonicalEVSEIdentity === undefined ? "unresolved" : "exact",
    connectors,
    maximumPowerKW,
    availability: {
      state: "unknown",
      isLive: false,
    },
    sourceReference,
  };
}

function mapConnectors(
  connectorTypes: readonly string[],
  powers: readonly number[],
): readonly NormalizedChargingConnector[] {
  const sharedPower = powers.length === 1 ? powers[0] : undefined;
  return connectorTypes.map((sourceValue, index) => {
    const power = powers[index] ?? sharedPower;
    return {
      sourceValue,
      ...(power === undefined ? {} : { maximumPowerKW: Math.max(1, Math.floor(power)) }),
    };
  });
}

function parseStatus(value: string, issues: string[]): boolean | undefined {
  switch (value.trim()) {
    case "In Betrieb":
      return true;
    case "In Wartung":
      return false;
    default:
      issues.push("unknown_status");
      return undefined;
  }
}

function parseChargingPointCount(value: string, issues: string[]): number | undefined {
  const parsed = Number(value);
  if (
    !Number.isInteger(parsed) ||
    parsed < 1 ||
    parsed > maximumChargingPointsPerLocation
  ) {
    issues.push("invalid_charging_point_count");
    return undefined;
  }
  return parsed;
}

function parseGermanNumber(value: string): number | undefined {
  const normalized = value.trim().replace(",", ".");
  if (normalized.length === 0) {
    return undefined;
  }
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function splitList(value: string): readonly string[] {
  return value
    .split(";")
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
}

function compactAddress(
  record: BundesnetzagenturCSVRecord,
): NormalizedChargingLocation["address"] {
  const values = {
    street: record.Straße.trim(),
    houseNumber: record.Hausnummer.trim(),
    postalCode: record.Postleitzahl.trim(),
    city: record.Ort.trim(),
    state: record.Bundesland.trim(),
  };
  return Object.fromEntries(Object.entries(values).filter(([, value]) => value.length > 0));
}

function firstNonEmpty(...values: readonly string[]): string {
  return values.map((value) => value.trim()).find((value) => value.length > 0) ?? "Ladepark";
}

function recordContentHash(record: BundesnetzagenturCSVRecord): string {
  const canonical = bundesnetzagenturHeaders.map((header) => record[header]);
  return createHash("sha256").update(JSON.stringify(canonical)).digest("hex");
}

function validateHeaders(headers: string[]): string[] {
  if (
    headers.length !== bundesnetzagenturHeaders.length ||
    !headers.every((header, index) => header === bundesnetzagenturHeaders[index])
  ) {
    throw new Error("Unexpected Bundesnetzagentur CSV schema.");
  }
  return headers;
}

function validateInstant(value: string, field: string): void {
  if (!Number.isFinite(Date.parse(value))) {
    throw new Error(`${field} must be an ISO-8601 instant.`);
  }
}

class HeaderSeekingTransform extends Transform {
  private buffered = Buffer.alloc(0);
  private foundHeader = false;
  skippedLineCount = 0;

  override _transform(
    chunk: Buffer,
    _encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    if (this.foundHeader) {
      this.push(chunk);
      callback();
      return;
    }

    this.buffered = Buffer.concat([this.buffered, chunk]);
    const index = this.buffered.indexOf(headerMarker);
    if (index >= 0) {
      this.skippedLineCount = countLineBreaks(this.buffered.subarray(0, index));
      this.foundHeader = true;
      this.push(this.buffered.subarray(index));
      this.buffered = Buffer.alloc(0);
      callback();
      return;
    }

    if (this.buffered.length > maximumPreambleBytes) {
      callback(new Error("Bundesnetzagentur CSV header was not found."));
      return;
    }
    callback();
  }

  override _flush(callback: TransformCallback): void {
    callback(this.foundHeader ? undefined : new Error("Bundesnetzagentur CSV header was not found."));
  }
}

function countLineBreaks(value: Buffer): number {
  let count = 0;
  for (const byte of value) {
    if (byte === 0x0a) {
      count += 1;
    }
  }
  return count;
}
