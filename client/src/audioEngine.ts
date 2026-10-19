import { BrowserSpeakerEngine } from "./speakerEngine";

export function createVideoEngine(video: HTMLVideoElement): AudioEngine {
  return {
    get src() { return video.src; },
    set src(value: string) { video.src = value; },
    get currentTime() { return video.currentTime; },
    set currentTime(value: number) { video.currentTime = value; },
    get duration() { return video.duration; },
    get playbackRate() { return video.playbackRate; },
    set playbackRate(value: number) { video.playbackRate = value; },
    get paused() { return video.paused; },
    get preload() { return video.preload; },
    set preload(value: string) { video.preload = value as HTMLMediaElement["preload"]; },
    play: () => Promise.resolve(video.play()),
    pause: () => video.pause(),
    load: () => video.load(),
    removeAttribute: (name: string) => video.removeAttribute(name),
    addEventListener: (type, listener, options) => video.addEventListener(type, listener as EventListener, options),
    removeEventListener: (type, listener, options) => video.removeEventListener(type, listener as EventListener, options),
    dispatchEvent: (event: Event) => video.dispatchEvent(event),
  } as AudioEngine;
}

export interface AudioEngine extends EventTarget {
  src: string;
  currentTime: number;
  duration: number;
  playbackRate: number;
  setPlaybackRate?(rate: number, correlationId: string): void;
  paused: boolean;
  preload: string;
  loadSource?(src: string, position: number, episodeId?: number, artifactHash?: string): void;
  setMetadata?(metadata: AudioMetadata): void;
  castConnect?(): void;
  castDisconnect?(): void;
  requestCastStatus?(): void;
  undoAdSkip?(): void;
  dispose?(): void;
  play(): Promise<void>;
  pause(): void;
  load(): void;
  removeAttribute(name: string): void;
}

export interface AdSkipNotice {
  rangeId: string;
  rangeStart: number;
  rangeEnd: number;
  skippedDuration: number;
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

export function createAudioEngine(): AudioEngine {
  return new BrowserSpeakerEngine();
}