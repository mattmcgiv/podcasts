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
  const matched = new URL(request.url).pathname.match(/^\/_media\/([a-f0-9]{64})\.(m4a|mp4)$/);
  const hash = matched?.[1];
  const extension = matched?.[2];
  if (!hash || !["GET", "HEAD"].includes(request.method)) return new Response(null, { status: 404 });
  const manifest = await readRecord<ArtifactManifest>("meta", `manifest:${hash}`);
  const download = await readRecord<Download>("downloads", hash);
  if (!manifest || !download?.complete) return new Response("Download this episode before playback.", { status: 503 });
  const range = byteRange(request.headers.get("Range"), manifest.bytes);
  if (!range) return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${manifest.bytes}` } });
  const [start, end] = range;
  const first = Math.floor(start / manifest.chunk_size), last = Math.floor(end / manifest.chunk_size);
  const pieces: Uint8Array[] = [];
  for (let index = first; index <= last; index++) {
    const chunk = await readRecord<ArrayBuffer>("chunks", `${hash}:${index}`);
    if (!chunk) {
      await writeRecord("downloads", hash, { ...download, complete: false });
      return new Response("Browser removed this download. Reconnect to restore it.", { status: 503 });
    }
    if (request.method === "HEAD") continue;
    const offset = index * manifest.chunk_size;
    pieces.push(new Uint8Array(chunk).slice(Math.max(0, start - offset), Math.min(chunk.byteLength, end - offset + 1)));
  }
  const length = end - start + 1;
  let body: Uint8Array | null = null;
  if (request.method !== "HEAD") {
    body = new Uint8Array(length);
    let cursor = 0;
    for (const piece of pieces) {
      body.set(piece, cursor);
      cursor += piece.byteLength;
    }
  }
  const headers: Record<string, string> = { "Content-Type": extension === "mp4" ? "video/mp4" : "audio/mp4", "Content-Length": String(length), "Accept-Ranges": "bytes", "ETag": `"${hash}"` };
  if (request.headers.has("Range")) headers["Content-Range"] = `bytes ${start}-${end}/${manifest.bytes}`;
  // iPhone WebKit plays the audio track of a streamed mp4 and leaves the picture black.
  const ranged = request.headers.has("Range");
  return new Response(body, { status: ranged ? 206 : 200, statusText: ranged ? "Partial Content" : "OK", headers });
}
