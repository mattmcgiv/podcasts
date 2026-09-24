import { logMediaDiagnostic } from "./diagnostics";
import { readRecord, writeRecord, type ArtifactManifest, type Download } from "./store";

/** Largest body served for one media request. iOS terminates the page when the
 * worker assembles hundreds of megabytes for one open-ended video range, so a
 * range beyond this cap is answered with its first capped prefix and the
 * player follows up with further ranges. Bodies stay complete buffers: iPhone
 * WebKit plays the audio track of a streamed mp4 and leaves the picture black. */
export const MEDIA_RESPONSE_CAP = 8 * 1024 ** 2;

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
  if (!hash || !["GET", "HEAD"].includes(request.method)) {
    void logMediaDiagnostic({ at: Date.now(), kind: "media-rejected", detail: `${request.method} ${new URL(request.url).pathname}` });
    return new Response(null, { status: 404 });
  }
  const manifest = await readRecord<ArtifactManifest>("meta", `manifest:${hash}`);
  const download = await readRecord<Download>("downloads", hash);
  if (!manifest || !download?.complete) {
    void logMediaDiagnostic({ at: Date.now(), kind: "media-incomplete", detail: hash.slice(0, 12) });
    return new Response("Download this episode before playback.", { status: 503 });
  }
  const range = byteRange(request.headers.get("Range"), manifest.bytes);
  if (!range) {
    void logMediaDiagnostic({ at: Date.now(), kind: "media-range-invalid", detail: `${hash.slice(0, 12)} ${request.headers.get("Range") ?? "none"}` });
    return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${manifest.bytes}` } });
  }
  const [start, end] = range;
  const serveEnd = Math.min(end, start + MEDIA_RESPONSE_CAP - 1);
  const capped = serveEnd < end;
  const first = Math.floor(start / manifest.chunk_size), last = Math.floor(serveEnd / manifest.chunk_size);
  const length = serveEnd - start + 1;
  let body: ArrayBuffer | null = null;
  if (request.method !== "HEAD") {
    body = new ArrayBuffer(length);
    const view = new Uint8Array(body);
    let cursor = 0;
    for (let index = first; index <= last; index++) {
      const chunk = await readRecord<ArrayBuffer>("chunks", `${hash}:${index}`);
      if (!chunk) {
        await writeRecord("downloads", hash, { ...download, complete: false });
        void logMediaDiagnostic({ at: Date.now(), kind: "media-evicted", detail: `${hash.slice(0, 12)} chunk ${index}` });
        return new Response("Browser removed this download. Reconnect to restore it.", { status: 503 });
      }
      const offset = index * manifest.chunk_size;
      const slice = new Uint8Array(chunk).subarray(Math.max(0, start - offset), Math.min(chunk.byteLength, serveEnd - offset + 1));
      view.set(slice, cursor);
      cursor += slice.byteLength;
    }
  }
  const headers: Record<string, string> = { "Content-Type": extension === "mp4" ? "video/mp4" : "audio/mp4", "Content-Length": String(length), "Accept-Ranges": "bytes", "ETag": `"${hash}"` };
  // A capped answer to a range-less request is still partial content. Media
  // stacks accept the 206 and follow up; assembling the whole file instead
  // terminates the page on iOS.
  const partial = request.headers.has("Range") || capped;
  if (partial) headers["Content-Range"] = `bytes ${start}-${serveEnd}/${manifest.bytes}`;
  if (capped) void logMediaDiagnostic({ at: Date.now(), kind: "media-capped", detail: `${hash.slice(0, 12)} bytes ${start}-${serveEnd}/${manifest.bytes} requested ${start}-${end}` });
  return new Response(body, { status: partial ? 206 : 200, statusText: partial ? "Partial Content" : "OK", headers });
}
