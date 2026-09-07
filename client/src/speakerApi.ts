import { backendBase } from "./offline/client";

const STATUS_TIMEOUT_MS = 8_000;
const COMMAND_TIMEOUT_MS = 15_000;

export interface SpeakerStatus {
  available: boolean;
  connected: boolean;
  name?: string | null;
  error?: string | null;
  episode_id?: number | null;
  artifact_hash?: string | null;
  position: number;
  duration: number;
  rate: number;
  paused: boolean;
  ended: boolean;
  session_id?: string | null;
  generation: number;
}

export interface SpeakerIdentity {
  session_id: string;
  generation: number;
}

export interface SpeakerLoadRequest extends SpeakerIdentity {
  episode_id: number;
  artifact_hash: string;
  position: number;
  rate: number;
  playing?: boolean;
}

export interface SpeakerClient {
  status(): Promise<SpeakerStatus>;
  load(body: SpeakerLoadRequest): Promise<SpeakerStatus>;
  play(identity: SpeakerIdentity): Promise<SpeakerStatus>;
  pause(identity: SpeakerIdentity): Promise<SpeakerStatus>;
  seek(identity: SpeakerIdentity, seconds: number): Promise<SpeakerStatus>;
  rate(identity: SpeakerIdentity, value: number): Promise<SpeakerStatus>;
  disconnect(identity: SpeakerIdentity): Promise<SpeakerStatus>;
}

export class SpeakerDisconnectedError extends Error {
  readonly disconnected = true;
  constructor(message = "Mac speaker disconnected.") {
    super(message);
    this.name = "SpeakerDisconnectedError";
  }
}

export class SpeakerStaleError extends Error {
  constructor(message = "Playback session is out of date.") {
    super(message);
    this.name = "SpeakerStaleError";
  }
}

export class SpeakerResyncError extends Error {
  constructor(message = "This episode was updated on the Mac. Synchronize, then play again.") {
    super(message);
    this.name = "SpeakerResyncError";
  }
}

async function speakerRequest(path: string, init: RequestInit = {}, timeoutMs = COMMAND_TIMEOUT_MS): Promise<SpeakerStatus> {
  const headers = new Headers(init.headers);
  if (init.body != null && !headers.has("content-type")) headers.set("content-type", "application/json");
  const target = `${backendBase()}/api/speaker/${path}`;
  let response: Response;
  try {
    response = await fetch(target, {
      ...init,
      headers,
      credentials: "include",
      signal: init.signal ?? AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    throw new SpeakerDisconnectedError(
      error instanceof Error && error.name === "TimeoutError"
        ? "Mac speaker timed out."
        : "Mac speaker disconnected.",
    );
  }
  if (response.status === 401) {
    window.dispatchEvent(new Event("pods-auth-required"));
    throw new SpeakerDisconnectedError("Sign in when the Mac is available.");
  }
  let body: SpeakerStatus & { error?: string } = {
    available: false,
    connected: false,
    position: 0,
    duration: 0,
    rate: 1,
    paused: true,
    ended: false,
    generation: 0,
  };
  try {
    body = (await response.json()) as SpeakerStatus & { error?: string };
  } catch {
    if (!response.ok) throw new SpeakerDisconnectedError("Mac speaker request failed.");
  }
  if (!response.ok) {
    const message = body.error || `Mac speaker request failed (${response.status}).`;
    if (response.status === 409) {
      if (/Synchronize/.test(message)) throw new SpeakerResyncError(message);
      throw new SpeakerStaleError(message);
    }
    if (response.status === 404 || response.status === 422) throw new Error(message);
    throw new SpeakerDisconnectedError(message);
  }
  return body;
}

export function createSpeakerClient(): SpeakerClient {
  return {
    status: () => speakerRequest("status", { method: "GET" }, STATUS_TIMEOUT_MS),
    load: (body) => speakerRequest("load", { method: "POST", body: JSON.stringify({
      episode_id: body.episode_id,
      session_id: body.session_id,
      generation: body.generation,
      artifact_hash: body.artifact_hash,
      position: body.position,
      rate: body.rate,
      playing: body.playing ?? false,
    }) }),
    play: (identity) => speakerRequest("play", { method: "POST", body: JSON.stringify(identity) }),
    pause: (identity) => speakerRequest("pause", { method: "POST", body: JSON.stringify(identity) }),
    seek: (identity, seconds) => speakerRequest("seek", { method: "POST", body: JSON.stringify({ ...identity, seconds }) }),
    rate: (identity, value) => speakerRequest("rate", { method: "POST", body: JSON.stringify({ ...identity, rate: value }) }),
    disconnect: (identity) => speakerRequest("disconnect", { method: "POST", body: JSON.stringify(identity) }),
  };
}
