import { Readable } from "node:stream";
import type { CacheObjectInfo, CacheObjectStore } from "../../src/providers/object-download-cache.js";

/** Generation/precondition semantics, with explicit failure injection; no provider or GCS connection. */
export class MemoryObjectStore implements CacheObjectStore {
  readonly objects = new Map<string, { generation: string; bytes: Buffer }>();
  readonly reads: { name: string; generation: string }[] = [];
  readonly deletions: string[] = [];
  beforeManifest?: () => void;
  loseManifestAcknowledgement = false;
  private generation = 0;
  info(name: string, generation?: string): Promise<CacheObjectInfo | undefined> {
    const object = this.objects.get(name);
    return Promise.resolve(object === undefined || (generation !== undefined && object.generation !== generation)
      ? undefined : { generation: object.generation, size: object.bytes.length });
  }
  read(name: string, generation: string): Readable {
    this.reads.push({ name, generation });
    const object = this.objects.get(name);
    if (object === undefined || object.generation !== generation) return Readable.from((function* () {
      yield* []; throw new Error("Missing pinned generation.");
    })());
    return Readable.from([object.bytes]);
  }
  async write(name: string, source: Readable, previousGeneration: string | 0): Promise<CacheObjectInfo> {
    const chunks: Buffer[] = [];
    for await (const value of source as AsyncIterable<Uint8Array>) chunks.push(Buffer.from(value));
    if (name.endsWith("/manifest.json")) this.beforeManifest?.();
    if ((this.objects.get(name)?.generation ?? 0) !== previousGeneration) throw new Error("Precondition failed.");
    const bytes = Buffer.concat(chunks), generation = String(++this.generation);
    this.objects.set(name, { generation, bytes });
    if (name.endsWith("/manifest.json") && this.loseManifestAcknowledgement) throw new Error("Acknowledgement lost.");
    return { generation, size: bytes.length };
  }
  delete(name: string, generation: string): Promise<void> {
    if (this.objects.get(name)?.generation === generation) this.objects.delete(name);
    this.deletions.push(name); return Promise.resolve();
  }
}

export async function streamBytes(stream: Readable): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream as AsyncIterable<Uint8Array>) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}
