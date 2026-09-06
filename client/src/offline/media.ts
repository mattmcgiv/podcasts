import { readRecord, writeRecord, type ArtifactManifest, type Download } from "./store";

export function byteRange(header: string | null, length: number): [number, number] | null {
  if (!header) return length > 0 ? [0, length - 1] : null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2])) return null;
  let start: number, end: number;
  if (!match[1]) { const suffix = Number(match[2]); if (suffix <= 0) return null; start = Math.max(0, length - suffix); end = length - 1; }
  else { start = Number(match[1]); end = match[2] ? Math.min(Number(match[2]), length - 1) : length - 1; }
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && start < length && end >= start ? [start, end] : null;
}

export async function localMedia(request: Request): Promise<Response> {
  const hash = new URL(request.url).pathname.match(/^\/_media\/([a-f0-9]{64})\.m4a$/)?.[1];
  if (!hash || !["GET", "HEAD"].includes(request.method)) return new Response(null, { status: 404 });
  const manifest = await readRecord<ArtifactManifest>("meta", `manifest:${hash}`);
  const download = await readRecord<Download>("downloads", hash);
  if (!manifest || !download?.complete) return new Response("Download this episode before playback.", { status: 503 });
  const range = byteRange(request.headers.get("Range"), manifest.bytes);
  if (!range) return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${manifest.bytes}` } });
  const [start, end] = range;
  const first = Math.floor(start / manifest.chunk_size), last = Math.floor(end / manifest.chunk_size);
  // Check requested chunk existence before committing a successful response header.
  for (let index = first; index <= last; index++) {
    if (!await readRecord("chunks", `${hash}:${index}`)) {
      await writeRecord("downloads", hash, { ...download, complete: false });
      return new Response("Browser removed this download. Reconnect to restore it.", { status: 503 });
    }
  }
  let index = first;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (index > last) { controller.close(); return; }
      const chunk = await readRecord<ArrayBuffer>("chunks", `${hash}:${index}`);
      if (!chunk) { controller.error(new Error("Download no longer available")); return; }
      const offset = index * manifest.chunk_size;
      controller.enqueue(new Uint8Array(chunk).slice(Math.max(0, start - offset), Math.min(chunk.byteLength, end - offset + 1)));
      index++;
    },
  });
  const headers: Record<string, string> = { "Content-Type": "audio/mp4", "Content-Length": String(end - start + 1), "Accept-Ranges": "bytes", "ETag": `"${hash}"` };
  if (request.headers.has("Range")) headers["Content-Range"] = `bytes ${start}-${end}/${manifest.bytes}`;
  return new Response(request.method === "HEAD" ? null : body, { status: request.headers.has("Range") ? 206 : 200, headers });
}
