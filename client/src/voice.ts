import { backendBase, probeMac, state } from "./offline/client";
import { openDatabase } from "./offline/store";

/** Spoken notes wait here until the Mac can transcribe them. */
export const VOICE_CHANGED = "pods-voice-changed";
export const VOICE_MAX_MS = 120_000;
export const VOICE_MIN_MS = 1_000;
export const VOICE_MAX_BYTES = 4_000_000;

export type VoicePhase = "saved" | "queued" | "running" | "ready" | "failed";

export interface VoiceDraft {
  id: string;
  mime: string;
  createdAt: number;
  /** Raw audio. A byte array survives IndexedDB; a Blob does not in every engine. */
  bytes: Uint8Array;
  phase: VoicePhase;
  transcript?: string;
  error?: string;
  placed?: boolean;
}

export type CaptureStop =
  | { blob: Blob; mime: string; elapsedMs: number }
  | "short"
  | "empty";

export interface CaptureSession {
  elapsedMs(): number;
  stop(): Promise<CaptureStop>;
  cancel(): void;
}

interface RemoteVoice {
  status: "queued" | "running" | "done" | "failed";
  transcript?: string;
  error?: string;
}

class VoiceHttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = "VoiceHttpError";
    this.status = status;
  }
}

export function formatVoiceElapsed(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

export function voicePhaseLabel(phase: VoicePhase): string {
  switch (phase) {
    case "saved":
      return "Saved on this phone. It transcribes when the Mac is connected.";
    case "queued":
      return "Waiting for the Mac to transcribe it.";
    case "running":
      return "The Mac is transcribing it.";
    case "ready":
      return "Review this transcript, then send.";
    case "failed":
      return "The Mac could not transcribe it.";
  }
}

export function describeCaptureError(error: unknown): string {
  const name = error instanceof DOMException || error instanceof Error ? error.name : "";
  switch (name) {
    case "NotAllowedError":
    case "PermissionDeniedError":
      return "The microphone is blocked. Allow it for this site, then try again.";
    case "NotFoundError":
    case "DevicesNotFoundError":
      return "This device has no microphone.";
    case "NotReadableError":
    case "TrackStartError":
      return "The microphone is in use by another app.";
    case "SecurityError":
      return "The microphone is only available on a secure page.";
    default:
      return "Could not start the microphone.";
  }
}

export function recorderMime(): string {
  const types = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"];
  const Recorder = globalThis.MediaRecorder;
  if (!Recorder || typeof Recorder.isTypeSupported !== "function") return "";
  return types.find(type => Recorder.isTypeSupported(type)) ?? "";
}

export async function startCapture(): Promise<CaptureSession> {
  if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
    throw new Error("This browser cannot record audio.");
  }
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (error) {
    throw new Error(describeCaptureError(error));
  }
  const stopTracks = () => stream.getTracks().forEach(track => track.stop());
  const mime = recorderMime();
  let recorder: MediaRecorder;
  try {
    recorder = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream);
  } catch (error) {
    stopTracks();
    throw new Error(describeCaptureError(error));
  }
  const chunks: Blob[] = [];
  const started = Date.now();
  let cancelRequested = false;
  let settled = false;
  recorder.addEventListener("dataavailable", event => {
    if (event.data.size > 0) chunks.push(event.data);
  });
  let resolveStopped!: () => void;
  const stopped = new Promise<void>(resolve => {
    resolveStopped = resolve;
  });
  recorder.addEventListener("stop", () => {
    stopTracks();
    resolveStopped();
  }, { once: true });
  recorder.addEventListener("error", () => {
    stopTracks();
    resolveStopped();
  }, { once: true });
  try {
    recorder.start(250);
  } catch (error) {
    stopTracks();
    throw new Error(describeCaptureError(error));
  }
  return {
    elapsedMs: () => Date.now() - started,
    cancel() {
      cancelRequested = true;
      if (recorder.state !== "inactive") recorder.stop();
      else stopTracks();
    },
    async stop() {
      if (!settled && recorder.state !== "inactive") {
        if (typeof recorder.requestData === "function") recorder.requestData();
        recorder.stop();
      }
      await stopped;
      settled = true;
      if (cancelRequested) return "empty";
      const elapsedMs = Date.now() - started;
      if (elapsedMs < VOICE_MIN_MS) return "short";
      const type = (recorder.mimeType || mime || "audio/webm").split(";")[0] || "audio/webm";
      const blob = new Blob(chunks, { type });
      if (blob.size < 32) return "empty";
      return { blob, mime: type, elapsedMs };
    },
  };
}

function notify(): void {
  window.dispatchEvent(new Event(VOICE_CHANGED));
}

export async function listVoiceDrafts(): Promise<VoiceDraft[]> {
  const db = await openDatabase();
  const items = await new Promise<VoiceDraft[]>((resolve, reject) => {
    const tx = db.transaction("voice", "readonly");
    const request = tx.objectStore("voice").getAll();
    tx.oncomplete = () => { db.close(); resolve((request.result as VoiceDraft[]) ?? []); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Could not read recordings.")); };
  });
  return items
    .filter(item => item && typeof item.id === "string")
    .sort((a, b) => b.createdAt - a.createdAt || b.id.localeCompare(a.id));
}

async function putVoice(draft: VoiceDraft): Promise<void> {
  const db = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction("voice", "readwrite");
    tx.objectStore("voice").put(draft, draft.id);
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Could not save this recording.")); };
  });
}

async function updateVoice(id: string, change: (draft: VoiceDraft) => void): Promise<void> {
  const db = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction("voice", "readwrite");
    const store = tx.objectStore("voice");
    const request = store.get(id);
    request.onsuccess = () => {
      const draft = request.result as VoiceDraft | undefined;
      if (!draft) return;
      change(draft);
      store.put(draft, id);
    };
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Could not update this recording.")); };
  });
}

async function takeVoice(id: string): Promise<VoiceDraft | undefined> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("voice", "readwrite");
    const store = tx.objectStore("voice");
    const request = store.get(id);
    let draft: VoiceDraft | undefined;
    request.onsuccess = () => {
      draft = request.result as VoiceDraft | undefined;
      if (draft) store.delete(id);
    };
    tx.oncomplete = () => { db.close(); resolve(draft); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Could not discard this recording.")); };
  });
}

export async function saveVoiceDraft(blob: Blob, mime: string): Promise<VoiceDraft> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const draft: VoiceDraft = {
    id: crypto.randomUUID(),
    mime: (mime.split(";")[0] || "audio/webm").trim().toLowerCase() || "audio/webm",
    createdAt: Math.floor(Date.now() / 1000),
    bytes,
    phase: bytes.byteLength > VOICE_MAX_BYTES ? "failed" : "saved",
    error: bytes.byteLength > VOICE_MAX_BYTES ? "That recording is too long to send." : undefined,
  };
  await putVoice(draft);
  notify();
  if (draft.phase === "saved") void flushVoiceDrafts().catch(() => {});
  return draft;
}

export async function markVoicePlaced(id: string): Promise<void> {
  await updateVoice(id, draft => { draft.placed = true; });
  notify();
}

export async function deleteVoiceDraft(id: string): Promise<void> {
  const draft = await takeVoice(id);
  notify();
  if (!draft || draft.phase === "saved") return;
  try {
    const clientId = (await state()).client_id;
    await fetch(`${backendBase()}/api/feedback/voice/${encodeURIComponent(id)}`, {
      method: "DELETE",
      credentials: "include",
      headers: { "x-pods-client-id": clientId },
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    /* The phone copy is already gone. A later sync has nothing left to upload. */
  }
}

let flushing: Promise<void> | null = null;

export function flushVoiceDrafts(): Promise<void> {
  if (flushing) return flushing;
  flushing = flushOnce().finally(() => { flushing = null; });
  return flushing;
}

async function flushOnce(): Promise<void> {
  const waiting = (await listVoiceDrafts()).filter(draft =>
    draft.phase === "saved" || draft.phase === "queued" || draft.phase === "running");
  if (!waiting.length) return;
  if (!(await probeMac())) return;
  const clientId = (await state()).client_id;
  let changed = false;
  for (const draft of waiting) {
    try {
      if (draft.phase === "saved" && draft.bytes.byteLength > VOICE_MAX_BYTES) {
        await updateVoice(draft.id, item => {
          item.phase = "failed";
          item.error = "That recording is too long to send.";
        });
        changed = true;
        continue;
      }
      const remote = draft.phase === "saved"
        ? await postVoice(clientId, draft)
        : await getVoice(clientId, draft.id);
      await applyRemote(draft.id, remote);
      changed = true;
    } catch (error) {
      const status = error instanceof VoiceHttpError ? error.status : 0;
      if (status === 404 && draft.phase !== "saved") {
        await updateVoice(draft.id, item => { item.phase = "saved"; item.error = undefined; });
        changed = true;
      } else if (status === 422 || status === 409) {
        await updateVoice(draft.id, item => {
          item.phase = "failed";
          item.error = error instanceof Error ? error.message : "The Mac rejected that recording.";
        });
        changed = true;
      }
    }
  }
  if (changed) notify();
}

async function applyRemote(id: string, remote: RemoteVoice): Promise<void> {
  await updateVoice(id, draft => {
    if (remote.status === "done" && remote.transcript?.trim()) {
      draft.phase = "ready";
      draft.transcript = remote.transcript.trim();
      draft.error = undefined;
    } else if (remote.status === "done") {
      draft.phase = "failed";
      draft.error = "Could not hear any speech. Try again.";
    } else if (remote.status === "failed") {
      draft.phase = "failed";
      draft.error = remote.error || "The Mac could not transcribe that recording.";
    } else if (remote.status === "queued" || remote.status === "running") {
      draft.phase = remote.status;
    }
  });
}

function recordingBody(bytes: Uint8Array, mime: string): Blob {
  const copy = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(copy).set(bytes);
  return new Blob([copy], { type: mime || "audio/webm" });
}

async function postVoice(clientId: string, draft: VoiceDraft): Promise<RemoteVoice> {
  const response = await fetch(`${backendBase()}/api/feedback/voice`, {
    method: "POST",
    credentials: "include",
    headers: {
      "content-type": draft.mime || "audio/webm",
      "x-pods-client-id": clientId,
      "x-pods-voice-id": draft.id,
    },
    body: recordingBody(draft.bytes, draft.mime),
    signal: AbortSignal.timeout(60_000),
  });
  return readVoiceResponse(response);
}

async function getVoice(clientId: string, id: string): Promise<RemoteVoice> {
  const response = await fetch(`${backendBase()}/api/feedback/voice/${encodeURIComponent(id)}`, {
    credentials: "include",
    headers: { "x-pods-client-id": clientId },
    signal: AbortSignal.timeout(15_000),
  });
  return readVoiceResponse(response);
}

async function readVoiceResponse(response: Response): Promise<RemoteVoice> {
  let body: { error?: string; status?: string; transcript?: string } = {};
  try {
    body = await response.json() as typeof body;
  } catch {
    /* A status code is enough when the Mac omits JSON. */
  }
  if (!response.ok) {
    if (response.status === 401) window.dispatchEvent(new Event("pods-auth-required"));
    throw new VoiceHttpError(response.status, body.error || `Mac request failed (${response.status}).`);
  }
  if (body.status !== "queued" && body.status !== "running" && body.status !== "done" && body.status !== "failed") {
    throw new Error("Mac returned an unexpected transcription status.");
  }
  return { status: body.status, transcript: body.transcript, error: body.error };
}
