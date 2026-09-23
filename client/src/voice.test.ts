import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory, IDBKeyRange } from "fake-indexeddb";
import { webcrypto } from "node:crypto";
import { DATABASE, writeRecord } from "./offline/store";
import {
  VOICE_CHANGED,
  VOICE_MAX_BYTES,
  deleteVoiceDraft,
  describeCaptureError,
  flushVoiceDrafts,
  formatVoiceElapsed,
  listVoiceDrafts,
  markVoicePlaced,
  recorderMime,
  saveVoiceDraft,
  startCapture,
  voicePhaseLabel,
} from "./voice";

class FakeRecorder {
  state = "inactive";
  mimeType: string;
  bytes = 40;
  fail = false;
  listeners = new Map<string, Array<(event: Event & { data?: Blob }) => void>>();
  static instance: FakeRecorder | null = null;
  static supported = true;
  static nextBytes = 40;
  static nextFail = false;
  constructor(_stream: MediaStream, options?: { mimeType?: string }) {
    this.mimeType = options?.mimeType ?? "";
    this.bytes = FakeRecorder.nextBytes;
    this.fail = FakeRecorder.nextFail;
    FakeRecorder.instance = this;
    if (FakeRecorder.failConstruct) throw new DOMException("busy", "NotReadableError");
  }
  static failConstruct = false;
  static isTypeSupported(type: string) {
    return FakeRecorder.supported && type.startsWith("audio/webm");
  }
  addEventListener(type: string, fn: (event: Event & { data?: Blob }) => void) {
    const list = this.listeners.get(type) ?? [];
    list.push(fn);
    this.listeners.set(type, list);
  }
  start() { this.state = "recording"; }
  requestData() {}
  stop() {
    this.state = "inactive";
    if (this.fail) {
      this.emit("error");
      return;
    }
    const data = new Blob([new Uint8Array(this.bytes)], { type: this.mimeType || "audio/webm" });
    this.emit("dataavailable", data);
    this.emit("stop");
  }
  emit(type: string, data?: Blob) {
    for (const fn of this.listeners.get(type) ?? []) fn({ data } as Event & { data?: Blob });
  }
}

beforeEach(() => {
  vi.stubGlobal("indexedDB", new IDBFactory());
  vi.stubGlobal("IDBKeyRange", IDBKeyRange);
  vi.stubGlobal("crypto", webcrypto);
  window.PODS_API_BASE = "https://mac.test";
  window.PODS_LOCAL_CLIENT = true;
  FakeRecorder.instance = null;
  FakeRecorder.failConstruct = false;
  FakeRecorder.supported = true;
  FakeRecorder.nextBytes = 40;
  FakeRecorder.nextFail = false;
  vi.stubGlobal("MediaRecorder", FakeRecorder);
  const track = { stop: vi.fn() };
  vi.stubGlobal("navigator", {
    ...navigator,
    mediaDevices: { getUserMedia: vi.fn(async () => ({ getTracks: () => [track] })) },
  });
  vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("offline"); }));
});

afterEach(() => {
  delete window.PODS_API_BASE;
  delete window.PODS_LOCAL_CLIENT;
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("voice labels", () => {
  it("formats the clock and the waiting states", () => {
    expect(formatVoiceElapsed(0)).toBe("0:00");
    expect(formatVoiceElapsed(65_000)).toBe("1:05");
    expect(formatVoiceElapsed(-20)).toBe("0:00");
    expect(voicePhaseLabel("saved")).toMatch(/Saved on this phone/);
    expect(voicePhaseLabel("queued")).toMatch(/Waiting for the Mac/);
    expect(voicePhaseLabel("running")).toMatch(/transcribing/);
    expect(voicePhaseLabel("ready")).toMatch(/Review/);
    expect(voicePhaseLabel("failed")).toMatch(/could not transcribe/);
  });

  it("explains microphone failures", () => {
    expect(describeCaptureError(new DOMException("no", "NotAllowedError"))).toMatch(/blocked/);
    expect(describeCaptureError(new DOMException("no", "PermissionDeniedError"))).toMatch(/blocked/);
    expect(describeCaptureError(new DOMException("no", "NotFoundError"))).toMatch(/no microphone/);
    expect(describeCaptureError(new DOMException("no", "DevicesNotFoundError"))).toMatch(/no microphone/);
    expect(describeCaptureError(new DOMException("no", "NotReadableError"))).toMatch(/in use/);
    expect(describeCaptureError(new DOMException("no", "TrackStartError"))).toMatch(/in use/);
    expect(describeCaptureError(new DOMException("no", "SecurityError"))).toMatch(/secure page/);
    expect(describeCaptureError(new Error("nope"))).toMatch(/Could not start/);
    expect(describeCaptureError("nope")).toMatch(/Could not start/);
  });
});

describe("capture", () => {
  it("picks a supported recording type", () => {
    expect(recorderMime()).toBe("audio/webm;codecs=opus");
    FakeRecorder.supported = false;
    expect(recorderMime()).toBe("");
    vi.stubGlobal("MediaRecorder", undefined);
    expect(recorderMime()).toBe("");
  });

  it("refuses when the browser cannot capture or the user denies the microphone", async () => {
    vi.stubGlobal("MediaRecorder", undefined);
    await expect(startCapture()).rejects.toThrow(/cannot record/);
    vi.stubGlobal("MediaRecorder", FakeRecorder);
    vi.mocked(navigator.mediaDevices.getUserMedia).mockRejectedValue(new DOMException("no", "NotAllowedError"));
    await expect(startCapture()).rejects.toThrow(/blocked/);
    FakeRecorder.failConstruct = true;
    vi.mocked(navigator.mediaDevices.getUserMedia).mockResolvedValue({ getTracks: () => [{ stop: vi.fn() }] } as unknown as MediaStream);
    await expect(startCapture()).rejects.toThrow(/in use/);
  });

  it("returns a clip, a short take, an empty take, or a cancel", async () => {
    const now = vi.spyOn(Date, "now");
    now.mockReturnValue(1_000);
    const short = await startCapture();
    now.mockReturnValue(1_200);
    expect(await short.stop()).toBe("short");

    now.mockReturnValue(5_000);
    const clip = await startCapture();
    expect(clip.elapsedMs()).toBe(0);
    now.mockReturnValue(7_000);
    expect(clip.elapsedMs()).toBe(2_000);
    const saved = await clip.stop();
    expect(saved).toMatchObject({ mime: "audio/webm", elapsedMs: 2_000 });
    if (saved === "short" || saved === "empty") throw new Error("expected a clip");
    expect(saved.blob.size).toBeGreaterThan(32);

    FakeRecorder.nextBytes = 0;
    const empty = await startCapture();
    now.mockReturnValue(9_000);
    expect(await empty.stop()).toBe("empty");
    FakeRecorder.nextBytes = 40;

    const live = await startCapture();
    const track = { stop: vi.fn() };
    vi.mocked(navigator.mediaDevices.getUserMedia).mockResolvedValue({ getTracks: () => [track] } as unknown as MediaStream);
    live.cancel();
    expect(await live.stop()).toBe("empty");

    FakeRecorder.nextFail = true;
    const broken = await startCapture();
    now.mockReturnValue(12_000);
    expect(await broken.stop()).toBe("empty");
    FakeRecorder.nextFail = false;
  });
});

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

describe("durable voice drafts", () => {
  it("opens a voice store on a library database that predates dictation", async () => {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.open(DATABASE, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore("meta");
        request.result.createObjectStore("chunks");
        request.result.createObjectStore("downloads");
      };
      request.onsuccess = () => { request.result.close(); resolve(); };
      request.onerror = () => reject(request.error);
    });
    const draft = await saveVoiceDraft(new Blob([new Uint8Array(40)]), "audio/webm;codecs=opus");
    expect(draft.phase).toBe("saved");
    expect(draft.mime).toBe("audio/webm");
    expect((await listVoiceDrafts()).map(item => item.id)).toEqual([draft.id]);
  });

  it("keeps a recording when the Mac is offline and uploads it when the Mac answers", async () => {
    const draft = await saveVoiceDraft(new Blob([new Uint8Array(48)]), "audio/mp4");
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0].phase).toBe("saved");

    let posted = false;
    vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      if (init?.method === "POST") {
        posted = true;
        return jsonResponse({ id: draft.id, status: "queued" }, 202);
      }
      if (init?.method === "DELETE") return new Response(null, { status: 204 });
      if (!posted) return jsonResponse({ status: "queued" }, 202);
      return jsonResponse({ id: draft.id, status: "running" }, 202);
    }));
    await flushVoiceDrafts();
    const post = vi.mocked(fetch).mock.calls.find(([, init]) => init?.method === "POST");
    expect(post?.[1]?.headers).toMatchObject({ "x-pods-voice-id": draft.id, "content-type": "audio/mp4" });
    expect(post?.[1]?.body).toBeInstanceOf(Blob);
    expect((await listVoiceDrafts())[0].phase).toBe("queued");
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0].phase).toBe("running");

    vi.mocked(fetch).mockImplementation(async (url: RequestInfo | URL, init?: RequestInit) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      if (init?.method === "DELETE") return new Response(null, { status: 204 });
      return jsonResponse({ status: "done", transcript: "  Dark mode please.  " }, 200);
    });
    await flushVoiceDrafts();
    const ready = (await listVoiceDrafts())[0];
    expect(ready.phase).toBe("ready");
    expect(ready.transcript).toBe("Dark mode please.");
    await markVoicePlaced(ready.id);
    expect((await listVoiceDrafts())[0].placed).toBe(true);
    await deleteVoiceDraft(ready.id);
    expect(await listVoiceDrafts()).toEqual([]);
    expect(vi.mocked(fetch).mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(true);
  });

  it("shares one upload when flush overlaps and treats Mac rejections as final", async () => {
    const onVoice = vi.fn();
    window.addEventListener(VOICE_CHANGED, onVoice);
    let posts = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      if (init?.method === "POST") {
        posts += 1;
        await new Promise(resolve => setTimeout(resolve, 20));
        return jsonResponse({ error: "unsupported recording" }, 422);
      }
      if (init?.method === "DELETE") return new Response(null, { status: 204 });
      return jsonResponse({ error: "recording id already used" }, 409);
    }));
    const draft = await saveVoiceDraft(new Blob([new Uint8Array(48)]), "audio/webm");
    const first = flushVoiceDrafts();
    const second = flushVoiceDrafts();
    expect(second).toBe(first);
    await first;
    expect(posts).toBe(1);
    expect((await listVoiceDrafts())[0]).toMatchObject({ id: draft.id, phase: "failed", error: "unsupported recording" });
    await deleteVoiceDraft(draft.id);
    expect(vi.mocked(fetch).mock.calls.some(([, init]) => init?.method === "DELETE")).toBe(true);
    window.removeEventListener(VOICE_CHANGED, onVoice);
  });

  it("requeues a note the Mac forgot, keeps a signed-out note, and rejects silence", async () => {
    vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      if (init?.method === "POST") return jsonResponse({ status: "queued" }, 202);
      return jsonResponse({ error: "not found" }, 404);
    }));
    const draft = await saveVoiceDraft(new Blob([new Uint8Array(48)]), "audio/webm");
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0].phase).toBe("queued");
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0].phase).toBe("saved");

    const auth = vi.fn();
    window.addEventListener("pods-auth-required", auth);
    vi.mocked(fetch).mockImplementation(async (url: RequestInfo | URL) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      return jsonResponse({ error: "sign in required" }, 401);
    });
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0].phase).toBe("saved");
    expect(auth).toHaveBeenCalled();
    window.removeEventListener("pods-auth-required", auth);

    vi.mocked(fetch).mockImplementation(async (url: RequestInfo | URL, init?: RequestInit) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      if (init?.method === "POST") return jsonResponse({ status: "done" }, 200);
      return jsonResponse({ status: "failed" }, 200);
    });
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0]).toMatchObject({
      id: draft.id,
      phase: "failed",
      error: "Could not hear any speech. Try again.",
    });
  });

  it("fails a recording that is too long to upload and ignores a nonsense status", async () => {
    const huge = await saveVoiceDraft(new Blob([new Uint8Array(VOICE_MAX_BYTES + 1)]), "audio/webm");
    expect(huge.phase).toBe("failed");
    expect(huge.error).toMatch(/too long/);
    await deleteVoiceDraft(huge.id);

    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      return jsonResponse({ status: "later" }, 200);
    }));
    const draft = await saveVoiceDraft(new Blob([new Uint8Array(48)]), "audio/webm");
    await flushVoiceDrafts();
    expect((await listVoiceDrafts())[0]).toMatchObject({ id: draft.id, phase: "saved" });
  });

  it("lists the newest recording first and refuses one that is too large to upload", async () => {
    const first = await saveVoiceDraft(new Blob([new Uint8Array(40)]), "audio/webm");
    const second = await saveVoiceDraft(new Blob([new Uint8Array(40)]), "audio/webm");
    expect((await listVoiceDrafts()).map(item => item.id).sort()).toEqual([first.id, second.id].sort());

    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (String(url).endsWith("/api/auth/status")) return new Response("ok");
      throw new Error("should not upload");
    }));
    await writeRecord("voice", "huge", {
      id: "huge", mime: "audio/webm", createdAt: 9,
      bytes: new Uint8Array(VOICE_MAX_BYTES + 1), phase: "saved",
    });
    await flushVoiceDrafts();
    expect((await listVoiceDrafts()).find(item => item.id === "huge")).toMatchObject({
      phase: "failed",
      error: "That recording is too long to send.",
    });
  });

  it("discards a note that never reached the Mac without calling it", async () => {
    const draft = await saveVoiceDraft(new Blob([new Uint8Array(48)]), "audio/webm");
    await flushVoiceDrafts();
    vi.mocked(fetch).mockClear();
    await deleteVoiceDraft(draft.id);
    expect(fetch).not.toHaveBeenCalled();
  });
});
