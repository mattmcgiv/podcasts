export interface AudioEngine extends EventTarget {
  src: string;
  currentTime: number;
  duration: number;
  playbackRate: number;
  paused: boolean;
  preload: string;
  play(): Promise<void>;
  pause(): void;
  load(): void;
  removeAttribute(name: string): void;
}

type NativeAudioEvent = {
  id?: number;
  type: "play" | "pause" | "timeupdate" | "loadedmetadata" | "ended" | "state";
  position?: number;
  duration?: number;
  playbackRate?: number;
  paused?: boolean;
};

type NativeAudioCommandBody =
  | { command: "load"; src: string; position: number; rate: number }
  | { command: "play" }
  | { command: "pause" }
  | { command: "seek"; seconds: number }
  | { command: "rate"; rate: number }
  | { command: "stop" };

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

  constructor() {
    super();
    nativeEngines.set(this.id, this);
    installNativeBridgeDispatcher();
  }

  get src(): string {
    return this._src;
  }

  set src(value: string) {
    this._src = value;
    this.post({ command: "load", src: value, position: this._currentTime, rate: this._playbackRate });
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
      this.post({ command: "load", src: this._src, position: this._currentTime, rate: this._playbackRate });
    }
  }

  removeAttribute(name: string): void {
    if (name !== "src") return;
    this._src = "";
    this._currentTime = 0;
    this._duration = NaN;
    this._paused = true;
    this.post({ command: "stop" });
  }

  receive(event: NativeAudioEvent): void {
    if (event.id != null && event.id !== this.id) return;
    if (event.position != null && Number.isFinite(event.position)) {
      this._currentTime = Math.max(0, event.position);
    }
    if (event.duration != null && Number.isFinite(event.duration)) {
      this._duration = Math.max(0, event.duration);
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
