import type { AudioEngine, AudioMetadata, CastInfo } from "../audioEngine";

export type FakeEngineCommand = Record<string, unknown>;

/**
 * Engine double for provider-level tests. Mimics the command/event surface the
 * provider consumes: load/setMetadata/rate commands plus play, pause,
 * timeupdate, loadedmetadata, ended, cast, adSkip, and adSkipUndone events.
 */
export class FakeEngine extends EventTarget implements AudioEngine {
  static instances: FakeEngine[] = [];

  id = 1;
  preload = "metadata";
  currentTime = 0;
  duration = NaN;
  playbackRate = 1;
  paused = true;
  cast: CastInfo = { available: false, connected: false, output: "local" };
  commands: FakeEngineCommand[] = [];

  private episodeId: number | undefined;
  private _src = "";

  constructor() {
    super();
    FakeEngine.instances.push(this);
  }

  static reset(): void {
    FakeEngine.instances = [];
  }

  static last(): FakeEngine {
    const engine = FakeEngine.instances.at(-1);
    if (!engine) throw new Error("no FakeEngine instance created");
    return engine;
  }

  get src(): string {
    return this._src;
  }

  set src(value: string) {
    this.loadSource(value, 0);
  }

  loadSource(src: string, position: number, episodeId?: number, artifactHash?: string): void {
    this.commands.push({ command: "load", src, position, episodeId, artifactHash });
    this._src = src;
    this.currentTime = Number.isFinite(position) ? Math.max(0, position) : 0;
    this.duration = NaN;
    this.paused = true;
    this.episodeId = episodeId;
  }

  setMetadata(metadata: AudioMetadata): void {
    this.commands.push({ command: "metadata", ...metadata });
  }

  setPlaybackRate(rate: number, correlationId?: string): void {
    this.playbackRate = rate;
    this.commands.push({ command: "rate", rate, correlationId });
  }

  castConnect(): void {
    this.commands.push({ command: "castConnect" });
  }

  castDisconnect(): void {
    this.commands.push({ command: "castDisconnect" });
  }

  requestCastStatus(): void {
    this.commands.push({ command: "castStatus" });
  }

  undoAdSkip(): void {
    this.commands.push({ command: "undoAdSkip" });
  }

  play(): Promise<void> {
    this.paused = false;
    this.commands.push({ command: "play", id: this.id });
    this.dispatchEvent(new Event("play"));
    return Promise.resolve();
  }

  pause(): void {
    this.paused = true;
    this.commands.push({ command: "pause", id: this.id });
    this.dispatchEvent(new Event("pause"));
  }

  load(): void {
    if (this._src) {
      this.commands.push({ command: "load", src: this._src, position: this.currentTime, rate: this.playbackRate, episodeId: this.episodeId, id: this.id });
    }
  }

  removeAttribute(name: string): void {
    if (name !== "src") return;
    this._src = "";
    this.currentTime = 0;
    this.duration = NaN;
    this.paused = true;
    this.episodeId = undefined;
    this.commands.push({ command: "stop", id: this.id });
  }

  emit(event: { type: string; [key: string]: unknown }): void {
    if (event.type === "cast") {
      this.cast = {
        available: !!event.available,
        connected: !!event.connected,
        name: event.name as string | undefined,
        error: event.error as string | undefined,
        output: (event.output as CastInfo["output"]) ?? this.cast.output,
      };
      this.dispatchEvent(new CustomEvent("cast", { detail: this.cast }));
      return;
    }
    if (event.type === "adSkip") {
      this.dispatchEvent(new CustomEvent("adSkip", {
        detail: {
          rangeId: event.rangeId,
          rangeStart: event.rangeStart,
          rangeEnd: event.rangeEnd,
          skippedDuration: event.skippedDuration,
        },
      }));
      return;
    }
    if (event.type === "adSkipUndone") {
      this.dispatchEvent(new Event("adSkipUndone"));
      return;
    }
    if (event.position != null && Number.isFinite(event.position as number)) {
      this.currentTime = Math.max(0, event.position as number);
    }
    if (event.duration != null && Number.isFinite(event.duration as number) && (event.duration as number) > 0) {
      this.duration = event.duration as number;
    }
    if (event.playbackRate != null && Number.isFinite(event.playbackRate as number)) {
      this.playbackRate = event.playbackRate as number;
    }
    if (event.paused != null) this.paused = event.paused as boolean;
    if (event.type === "play") this.paused = false;
    if (event.type === "pause" || event.type === "ended") this.paused = true;
    if (event.type !== "state") this.dispatchEvent(new Event(event.type));
  }
}