export interface AudioEngine extends EventTarget {
  src: string;
  currentTime: number;
  duration: number;
  playbackRate: number;
  paused: boolean;
  preload: string;
  loadSource?(src: string, position: number, episodeId?: number): void;
  setMetadata?(metadata: AudioMetadata): void;
  castConnect?(): void;
  castDisconnect?(): void;
  requestCastStatus?(): void;
  play(): Promise<void>;
  pause(): void;
  load(): void;
  removeAttribute(name: string): void;
}

export interface AudioMetadata {
  title: string;
  artist: string;
  artwork?: string;
  duration?: number;
}

export interface CastInfo {
  available: boolean;
  connected: boolean;
  name?: string;
  error?: string;
  output?: "local" | "mac";
}

type NativeAudioEvent = {
  id?: number;
  type: "play" | "pause" | "timeupdate" | "loadedmetadata" | "ended" | "state" | "cast";
  position?: number;
  duration?: number;
  playbackRate?: number;
  paused?: boolean;
  /** Episode identity from native/Mac transport. Untagged browser events omit this. */
  episodeId?: number;
  available?: boolean;
  connected?: boolean;
  name?: string;
  error?: string;
  output?: "local" | "mac";
  cast?: CastInfo;
};

type NativeAudioCommandBody =
  | { command: "load"; src: string; position: number; rate: number; episodeId?: number }
  | { command: "metadata"; title: string; artist: string; artwork?: string; duration?: number }
  | { command: "play" }
  | { command: "pause" }
  | { command: "seek"; seconds: number }
  | { command: "rate"; rate: number }
  | { command: "stop" }
  | { command: "castConnect" }
  | { command: "castDisconnect" }
  | { command: "castStatus" };

type NativeAudioCommand = NativeAudioCommandBody & { id: number };

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        podsAudio?: {
          postMessage(message: NativeAudioCommand): void;
        };
      };
    };
    PodsAudioBridge?: {
      emit(event: NativeAudioEvent): void;
    };
  }
}

let nextNativeId = 1;
const nativeEngines = new Map<number, NativeAudioEngine>();

export function hasNativeAudioBridge(): boolean {
  return typeof window !== "undefined" && !!window.webkit?.messageHandlers?.podsAudio;
}

export function createAudioEngine(): AudioEngine {
  if (hasNativeAudioBridge()) return new NativeAudioEngine();
  return new Audio() as AudioEngine;
}

class NativeAudioEngine extends EventTarget implements AudioEngine {
  readonly id = nextNativeId++;
  preload = "metadata";
  private _src = "";
  private _currentTime = 0;
  private _duration = NaN;
  private _playbackRate = 1;
  private _paused = true;
  /** Last episode id passed to loadSource; used to drop stale tagged transport/ended. */
  private _episodeId: number | undefined;
  private _cast: CastInfo = { available: false, connected: false, output: "local" };

  constructor() {
    super();
    nativeEngines.set(this.id, this);
    installNativeBridgeDispatcher();
    this.post({ command: "castStatus" });
  }

  get src(): string {
    return this._src;
  }

  set src(value: string) {
    this.loadSource(value, 0);
  }

  loadSource(src: string, position: number, episodeId?: number): void {
    const initialPosition = Number.isFinite(position) ? Math.max(0, position) : 0;
    this._src = src;
    this._currentTime = initialPosition;
    this._duration = NaN;
    this._paused = true;
    this._episodeId = episodeId;
    this.post({ command: "load", src, position: initialPosition, rate: this._playbackRate, episodeId });
  }

  get currentTime(): number {
    return this._currentTime;
  }

  set currentTime(value: number) {
    const seconds = Number.isFinite(value) ? Math.max(0, value) : 0;
    this._currentTime = seconds;
    this.post({ command: "seek", seconds });
  }

  get duration(): number {
    return this._duration;
  }

  get playbackRate(): number {
    return this._playbackRate;
  }

  set playbackRate(value: number) {
    const rate = Number.isFinite(value) && value > 0 ? value : 1;
    this._playbackRate = rate;
    this.post({ command: "rate", rate });
  }

  get paused(): boolean {
    return this._paused;
  }

  get cast(): CastInfo {
    return this._cast;
  }

  play(): Promise<void> {
    this._paused = false;
    this.post({ command: "play" });
    this.dispatchEvent(new Event("play"));
    return Promise.resolve();
  }

  pause(): void {
    this._paused = true;
    this.post({ command: "pause" });
    this.dispatchEvent(new Event("pause"));
  }

  load(): void {
    if (this._src) {
      this.post({
        command: "load",
        src: this._src,
        position: this._currentTime,
        rate: this._playbackRate,
        episodeId: this._episodeId,
      });
    }
  }

  removeAttribute(name: string): void {
    if (name !== "src") return;
    this._src = "";
    this._currentTime = 0;
    this._duration = NaN;
    this._paused = true;
    this._episodeId = undefined;
    this.post({ command: "stop" });
  }

  setMetadata(metadata: AudioMetadata): void {
    this.post({ command: "metadata", ...metadata });
  }

  castConnect(): void {
    this.post({ command: "castConnect" });
  }

  castDisconnect(): void {
    this.post({ command: "castDisconnect" });
  }

  requestCastStatus(): void {
    this.post({ command: "castStatus" });
  }

  receive(event: NativeAudioEvent): void {
    if (event.type === "cast") {
      const cast = event.cast ?? {
        available: !!event.available,
        connected: !!event.connected,
        name: event.name,
        error: event.error,
        output: event.output,
      };
      this._cast = {
        available: !!cast.available,
        connected: !!cast.connected,
        name: cast.name,
        error: cast.error,
        output: cast.output ?? event.output ?? this._cast.output,
      };
      this.dispatchEvent(new CustomEvent("cast", { detail: this._cast }));
      return;
    }
    if (event.id != null && event.id !== this.id) return;
    // Drop transport/ended tagged for a different episode. Untagged events (browser
    // HTMLAudioElement path, or native events without identity) still apply.
    if (
      event.episodeId != null &&
      this._episodeId != null &&
      event.episodeId !== this._episodeId
    ) {
      return;
    }
    if (event.position != null && Number.isFinite(event.position)) {
      this._currentTime = Math.max(0, event.position);
    }
    // Only adopt a positive duration; early native/Mac events often send 0 while unknown.
    if (event.duration != null && Number.isFinite(event.duration) && event.duration > 0) {
      this._duration = event.duration;
    }
    if (event.playbackRate != null && Number.isFinite(event.playbackRate)) {
      this._playbackRate = event.playbackRate;
    }
    if (event.paused != null) {
      this._paused = event.paused;
    }
    if (event.type === "play") this._paused = false;
    if (event.type === "pause" || event.type === "ended") this._paused = true;
    if (event.type !== "state") {
      this.dispatchEvent(new Event(event.type));
    }
  }

  private post(command: NativeAudioCommandBody): void {
    window.webkit?.messageHandlers?.podsAudio?.postMessage({ id: this.id, ...command } as NativeAudioCommand);
  }
}

function installNativeBridgeDispatcher(): void {
  window.PodsAudioBridge = {
    emit(event: NativeAudioEvent) {
      for (const engine of nativeEngines.values()) engine.receive(event);
    },
  };
}
